//
//  M3U8DownloadHandler.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation
import Combine
import CommonCrypto

/// M3U8下载处理器
class M3U8DownloadHandler: DownloadHandlerProtocol {

    private let networkClient: NetworkClient
    private let storageManager: FileStorageManager
    private let parser: M3U8Parser

    init(networkClient: NetworkClient, storageManager: FileStorageManager) {
        self.networkClient = networkClient
        self.storageManager = storageManager
        self.parser = M3U8Parser()
    }

    func createTask(
        url: String,
        fileName: String?,
        configuration: DownloadConfiguration,
        format: VideoFormat
    ) async throws -> any DownloadTask {
        guard let m3u8URL = URL(string: url) else {
            throw DownloadError.invalidURL(url)
        }

        // 下载并解析M3U8文件
        let m3u8Content = try await networkClient.downloadString(from: m3u8URL)
        let playlist = try parser.parse(content: m3u8Content, baseURL: m3u8URL)

        // 如果是Master Playlist，选择一个变体
        let mediaPlaylist: M3U8MediaPlaylist
        if let masterPlaylist = playlist as? M3U8MasterPlaylist {
            let variant = masterPlaylist.selectBestVariant()
            let variantContent = try await networkClient.downloadString(from: variant.url)
            mediaPlaylist = try parser.parse(content: variantContent, baseURL: variant.url) as! M3U8MediaPlaylist
        } else {
            mediaPlaylist = playlist as! M3U8MediaPlaylist
        }

        // 如果加密，下载密钥
        var encryptionKey: Data?
        if mediaPlaylist.isEncrypted, let encryption = mediaPlaylist.segments.first?.encryption {
            encryptionKey = try await networkClient.downloadData(from: encryption.keyURL)
        }

        // 检查存储空间
        let estimatedSize = Int64(mediaPlaylist.totalDuration * 500000) // 粗略估算：500KB/秒
        try storageManager.checkAvailableSpace(requiredBytes: estimatedSize)

        let taskId = UUID()
        let finalFileName = fileName ?? "video_\(taskId.uuidString).mp4"

        let task = M3U8DownloadTask(
            id: taskId,
            url: url,
            playlist: mediaPlaylist,
            encryptionKey: encryptionKey,
            fileName: finalFileName,
            configuration: configuration,
            networkClient: networkClient,
            storageManager: storageManager
        )

        return task
    }
}

/// M3U8下载任务
class M3U8DownloadTask: DownloadTask {

    let id: UUID
    let url: String
    let fileName: String
    let configuration: DownloadConfiguration
    let playlist: M3U8MediaPlaylist
    let encryptionKey: Data?

    let state = CurrentValueSubject<DownloadState, Never>(.pending)
    let progress = CurrentValueSubject<DownloadProgress, Never>(.empty)
    private(set) var completedURL: URL?

    let format: VideoFormat = .m3u8
    var totalSize: Int64?
    var downloadedSize: Int64 = 0
    let createdAt: Date = Date()
    var completedAt: Date?
    var resumeData: Data?

    private let networkClient: NetworkClient
    private let storageManager: FileStorageManager
    private var downloadState: M3U8DownloadState
    private let speedCalculator = SpeedCalculator()
    private var task: Task<Void, Error>?
    private let maxConcurrentSegments: Int

    init(
        id: UUID,
        url: String,
        playlist: M3U8MediaPlaylist,
        encryptionKey: Data?,
        fileName: String,
        configuration: DownloadConfiguration,
        networkClient: NetworkClient,
        storageManager: FileStorageManager
    ) {
        self.id = id
        self.url = url
        self.playlist = playlist
        self.encryptionKey = encryptionKey
        self.fileName = fileName
        self.configuration = configuration
        self.networkClient = networkClient
        self.storageManager = storageManager
        self.downloadState = M3U8DownloadState(
            totalSegments: playlist.segments.count,
            segmentURLs: playlist.segments.map { $0.url.absoluteString },
            playlistIdentifier: playlist.segments.first?.url.absoluteString ?? url
        )
        self.maxConcurrentSegments = Constants.M3U8.maxConcurrentSegmentDownloads
    }

    var stateFileURL: URL? {
        let tempDir = storageManager.createTaskDirectory(taskId: id)
        return tempDir.appendingPathComponent(Constants.M3U8.stateFileName)
    }

    private func saveDownloadState() {
        guard let url = stateFileURL else { return }
        do {
            try storageManager.saveJSON(downloadState, to: url)
        } catch {
            Logger.error("Failed to save M3U8 download state: \(error)")
        }
    }

    private func loadDownloadState() -> M3U8DownloadState? {
        guard let url = stateFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try storageManager.loadJSON(from: url, as: M3U8DownloadState.self)
        } catch {
            Logger.error("Failed to load M3U8 download state: \(error)")
            return nil
        }
    }

    func resume() async throws {
        guard state.value != .downloading else { return }

        // 尝试恢复之前保存的状态
        if let savedState = loadDownloadState(),
           savedState.totalSegments == playlist.segments.count,
           savedState.playlistIdentifier == (playlist.segments.first?.url.absoluteString ?? url) {
            self.downloadState = savedState
            Logger.info("Restored M3U8 download state: \(savedState.completedSegments.count)/\(savedState.totalSegments) segments")
        }

        state.send(.downloading)

        task = Task {
            do {
                // 创建临时目录
                let tempDir = storageManager.createTaskDirectory(taskId: id)
                let segmentsDir = tempDir.appendingPathComponent("segments")
                try FileManager.default.createDirectory(at: segmentsDir, withIntermediateDirectories: true)

                // 预扫描已存在的片段，校准字节大小和 completedSegments
                await calibrateDownloadedBytes(segmentsDir: segmentsDir)

                // 并发下载TS片段（使用信号量限制并发数，防止OOM）
                let semaphore = AsyncSemaphore(limit: maxConcurrentSegments)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for (index, segment) in playlist.segments.enumerated() {
                        // 跳过已完成的片段
                        if downloadState.completedSegments.contains(index) {
                            continue
                        }

                        await semaphore.wait()
                        group.addTask {
                            defer { Task { await semaphore.signal() } }
                            let segmentSize = try await self.downloadSegment(
                                segment,
                                index: index,
                                to: segmentsDir
                            )

                            // 记录实际字节大小
                            await self.recordSegmentSize(index: index, size: segmentSize)
                            await self.updateProgress()
                            self.saveDownloadState()
                        }
                    }

                    try await group.waitForAll()
                }

                // 合并TS片段
                let outputURL = try await mergeSegments(
                    in: segmentsDir,
                    to: storageManager.completedDirectory().appendingPathComponent(fileName)
                )

                // 清理临时文件
                try? storageManager.deleteFile(at: tempDir)

                self.completedURL = outputURL
                self.completedAt = Date()
                state.send(.completed)

            } catch is CancellationError {
                state.send(.paused)
                saveDownloadState()
            } catch {
                Logger.error("M3U8 download failed: \(error)")
                state.send(.failed)
                saveDownloadState()
                throw DownloadError.taskFailed(error)
            }
        }

        try await task?.value
    }

    func pause() async {
        task?.cancel()
        saveDownloadState()
        state.send(.paused)
    }

    func cancel() async {
        task?.cancel()

        // 清理临时文件
        let tempDir = storageManager.createTaskDirectory(taskId: id)
        try? storageManager.deleteFile(at: tempDir)

        state.send(.cancelled)
    }

    // MARK: - Private Methods

    @discardableResult
    private func downloadSegment(_ segment: M3U8Segment, index: Int, to directory: URL) async throws -> Int64 {
        // 下载数据
        var data = try await networkClient.downloadData(from: segment.url)

        // 解密（如果需要）
        if let encryption = segment.encryption, let key = encryptionKey {
            data = try decryptData(data, key: key, iv: encryption.iv)
        }

        // 保存片段
        let segmentURL = directory.appendingPathComponent("segment_\(String(format: "%05d", index)).ts")
        try data.write(to: segmentURL)

        return Int64(data.count)
    }

    private func decryptData(_ data: Data, key: Data, iv: Data?) throws -> Data {
        // 使用AES-128-CBC解密
        let cryptor = AESDecryptor(key: key, iv: iv ?? Data(repeating: 0, count: 16))
        return try cryptor.decrypt(data)
    }

    private func recordSegmentSize(index: Int, size: Int64) {
        downloadState.segmentByteSizes[index] = size

        // 渐进式估算总大小
        if downloadState.totalEstimatedBytes == nil,
           downloadState.segmentByteSizes.count >= 3 {
            let avgSize = downloadState.downloadedBytes / Int64(downloadState.segmentByteSizes.count)
            downloadState.totalEstimatedBytes = avgSize * Int64(downloadState.totalSegments)
        }
    }

    private func calibrateDownloadedBytes(segmentsDir: URL) async {
        for i in 0..<playlist.segments.count {
            let segmentURL = segmentsDir.appendingPathComponent("segment_\(String(format: "%05d", i)).ts")
            if FileManager.default.fileExists(atPath: segmentURL.path) {
                let size = storageManager.fileSize(at: segmentURL)
                if size > 0 {
                    downloadState.segmentByteSizes[i] = size
                    downloadState.completedSegments.insert(i)
                }
            }
        }

        // 校准总估算大小
        if !downloadState.segmentByteSizes.isEmpty {
            let avgSize = downloadState.downloadedBytes / Int64(downloadState.segmentByteSizes.count)
            downloadState.totalEstimatedBytes = avgSize * Int64(downloadState.totalSegments)
        }
    }

    private func updateProgress() async {
        let completed = downloadState.completedSegments.count
        let total = downloadState.totalSegments
        let progressValue = Float(completed) / Float(total)

        let downloadedBytes = downloadState.downloadedBytes
        let totalBytes = downloadState.totalEstimatedBytes ?? Int64(total) * 1_000_000

        self.totalSize = totalBytes
        self.downloadedSize = downloadedBytes

        let now = Date().timeIntervalSince1970
        speedCalculator.addSample(bytes: downloadedBytes, timestamp: now)
        let speed = speedCalculator.calculateSpeed()
        let remaining = speedCalculator.calculateRemainingTime(totalBytes: totalBytes, downloadedBytes: downloadedBytes)

        let progressInfo = DownloadProgress(
            taskId: id,
            totalBytes: totalBytes,
            downloadedBytes: downloadedBytes,
            progress: progressValue,
            speed: speed,
            remainingTime: remaining
        )

        progress.send(progressInfo)
    }

    private func mergeSegments(in directory: URL, to outputURL: URL) async throws -> URL {
        // 创建输出文件
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: nil)
        guard let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
            throw DownloadError.taskFailed(NSError(domain: "M3U8Merge", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法创建输出文件"]))
        }

        defer {
            outputHandle.closeFile()
        }

        let bufferSize = Constants.M3U8.mergeBufferSize

        // 按顺序流式读取并合并所有TS片段，避免将整个片段加载到内存
        for i in 0..<playlist.segments.count {
            let segmentURL = directory.appendingPathComponent("segment_\(String(format: "%05d", i)).ts")

            guard FileManager.default.fileExists(atPath: segmentURL.path) else { continue }
            guard let inputStream = InputStream(fileAtPath: segmentURL.path) else { continue }
            inputStream.open()
            defer { inputStream.close() }

            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            while inputStream.hasBytesAvailable {
                let bytesRead = inputStream.read(buffer, maxLength: bufferSize)
                if bytesRead <= 0 { break }
                let chunk = Data(bytesNoCopy: buffer, count: bytesRead, deallocator: .none)
                outputHandle.write(chunk)
            }
        }

        return outputURL
    }
}

extension M3U8DownloadTask {
    func toDownloadItem() -> DownloadItem {
        return DownloadItem(
            id: id,
            url: url,
            format: format,
            fileName: fileName,
            totalSize: totalSize,
            downloadedSize: downloadedSize,
            state: state.value,
            createdAt: createdAt,
            completedAt: completedAt,
            resumeData: resumeData
        )
    }
}

// MARK: - AES Decryptor

class AESDecryptor {
    private let key: Data
    private let iv: Data

    init(key: Data, iv: Data) {
        self.key = key
        self.iv = iv
    }

    func decrypt(_ data: Data) throws -> Data {
        let outputSize = data.count + kCCBlockSizeAES128
        var decryptedData = Data(count: outputSize)
        var numBytesDecrypted: size_t = 0

        let cryptStatus: CCCryptorStatus = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { dataBytes in
                    decryptedData.withUnsafeMutableBytes { decryptedBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress,
                            data.count,
                            decryptedBytes.baseAddress,
                            outputSize,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }

        guard cryptStatus == kCCSuccess else {
            throw DownloadError.encryptionNotSupported
        }

        decryptedData.count = numBytesDecrypted
        return decryptedData
    }
}

// MARK: - Async Semaphore

/// 轻量级异步信号量，用于限制并发任务数
private actor AsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.count = limit
    }

    func wait() async {
        if count > 0 {
            count -= 1
        } else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    func signal() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            count += 1
        }
    }
}
