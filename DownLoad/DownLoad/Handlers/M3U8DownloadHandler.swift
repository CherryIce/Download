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

        // 问题19：检测直播流，抛出明确错误
        if mediaPlaylist.isLive {
            throw DownloadError.liveStreamNotSupported
        }

        // 问题17：收集所有唯一密钥 URL，支持密钥轮换
        var encryptionKeyCache: [URL: Data] = [:]
        let uniqueKeyURLs = Set(mediaPlaylist.segments.compactMap { $0.encryption?.keyURL })
        for keyURL in uniqueKeyURLs {
            // 检查 FairPlay DRM 等不支持的密钥格式
            if let segment = mediaPlaylist.segments.first(where: { $0.encryption?.keyURL == keyURL }),
               let keyFormat = segment.encryption?.keyFormat,
               keyFormat == "com.apple.streamingkeydelivery" {
                throw DownloadError.keyFormatNotSupported(format: keyFormat)
            }
            encryptionKeyCache[keyURL] = try await networkClient.downloadData(from: keyURL)
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
            encryptionKeyCache: encryptionKeyCache,
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
    private let encryptionKeyCache: [URL: Data]  // 密钥缓存（支持密钥轮换）

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

    /// 暂停原因（用于区分用户手动暂停和网络自动暂停）
    var pauseReason: PauseReason? = nil

    /// 下载优先级
    var priority: DownloadPriority = .normal

    init(
        id: UUID,
        url: String,
        playlist: M3U8MediaPlaylist,
        encryptionKeyCache: [URL: Data],
        fileName: String,
        configuration: DownloadConfiguration,
        networkClient: NetworkClient,
        storageManager: FileStorageManager,
        priority: DownloadPriority = .normal
    ) {
        self.id = id
        self.url = url
        self.playlist = playlist
        self.encryptionKeyCache = encryptionKeyCache
        self.fileName = fileName
        self.configuration = configuration
        self.networkClient = networkClient
        self.storageManager = storageManager
        self.downloadState = M3U8DownloadState(
            totalSegments: playlist.segments.count,
            segmentURLs: playlist.segments.map { $0.url.absoluteString },
            playlistIdentifier: playlist.segments.first?.url.absoluteString ?? url
        )
        self.downloadState.isFMP4 = playlist.isFMP4
        self.maxConcurrentSegments = Constants.M3U8.maxConcurrentSegmentDownloads
        self.priority = priority
    }

    func stateFileURL() throws -> URL {
        let tempDir = try storageManager.createTaskDirectory(taskId: id)
        return tempDir.appendingPathComponent(Constants.M3U8.stateFileName)
    }

    private func saveDownloadState() {
        guard let url = try? stateFileURL() else { return }
        do {
            try storageManager.saveJSON(downloadState, to: url)
        } catch {
            AppLogger.error("Failed to save M3U8 download state: \(error)")
        }
    }

    private func loadDownloadState() -> M3U8DownloadState? {
        guard let url = try? stateFileURL(),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try storageManager.loadJSON(from: url, as: M3U8DownloadState.self)
        } catch {
            AppLogger.error("Failed to load M3U8 download state: \(error)")
            return nil
        }
    }

    func resume() async throws {
        guard state.value != .downloading else { return }

        // 恢复时清除暂停原因
        pauseReason = nil

        // 尝试恢复之前保存的状态
        if let savedState = loadDownloadState(),
           savedState.totalSegments == playlist.segments.count,
           savedState.playlistIdentifier == (playlist.segments.first?.url.absoluteString ?? url) {
            self.downloadState = savedState
            AppLogger.info("Restored M3U8 download state: \(savedState.completedSegments.count)/\(savedState.totalSegments) segments")
        }

        state.send(.downloading)

        task = Task {
            do {
                // 创建临时目录
                let tempDir = try storageManager.createTaskDirectory(taskId: id)
                let segmentsDir = tempDir.appendingPathComponent("segments")
                try FileManager.default.createDirectory(at: segmentsDir, withIntermediateDirectories: true)

                // 预扫描已存在的片段，校准字节大小和 completedSegments
                await calibrateDownloadedBytes(segmentsDir: segmentsDir)

                // 问题18：fMP4 容器需要先下载初始化片段
                if let mapInfo = playlist.map {
                    let initSegmentURL = segmentsDir.appendingPathComponent("init_segment.mp4")
                    if !FileManager.default.fileExists(atPath: initSegmentURL.path) {
                        let initData = try await downloadMapSegment(mapInfo)
                        try initData.write(to: initSegmentURL)
                    }
                    downloadState.initSegmentDownloaded = true
                    saveDownloadState()
                }

                // 并发下载片段（使用信号量限制并发数，防止OOM）
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

                // 合并片段
                let outputURL = try await mergeSegments(
                    in: segmentsDir,
                    to: try storageManager.completedDirectory().appendingPathComponent(fileName)
                )

                // 清理临时文件
                try? storageManager.deleteFile(at: tempDir)

                self.completedURL = outputURL
                self.completedAt = Date()
                state.send(.completed)

            } catch is CancellationError {
                state.send(.paused)
                saveDownloadState()
            } catch let error as DownloadError {
                if case .insufficientStorage = error {
                    AppLogger.error("M3U8 download paused due to insufficient storage: \(id)")
                    // 清理临时文件
                    if let tempDir = try? storageManager.createTaskDirectory(taskId: id) {
                        try? storageManager.deleteFile(at: tempDir)
                    }
                    state.send(.failed)
                } else {
                    AppLogger.error("M3U8 download failed: \(error)")
                    state.send(.failed)
                }
                saveDownloadState()
            } catch {
                AppLogger.error("M3U8 download failed: \(error)")
                state.send(.failed)
                saveDownloadState()
                throw DownloadError.taskFailed(error)
            }
        }

        try await task?.value
    }

    func retry() async throws {
        guard state.value == .failed else {
            AppLogger.warning("M3U8 retry() called but state is not .failed (current: \(state.value.displayText)), task: \(id)")
            return
        }

        AppLogger.info("Retrying M3U8 download task: \(id), preserving \(downloadState.completedSegments.count)/\(downloadState.totalSegments) completed segments")

        // 清除暂停原因
        pauseReason = nil

        // 重置状态为 pending
        // 注意：不清理 downloadState，保留已下载片段的断点进度
        state.send(.pending)

        // 重新启动下载（resume() 会自动 loadDownloadState 并跳过已完成片段）
        try await resume()
    }

    func pause() async {
        // 如果没有外部指定原因，默认为用户手动暂停
        if pauseReason == nil {
            pauseReason = .userInitiated
        }

        task?.cancel()
        saveDownloadState()
        state.send(.paused)
    }

    func cancel() async {
        // 取消时清除暂停原因
        pauseReason = nil

        task?.cancel()

        // 清理临时文件
        if let tempDir = try? storageManager.createTaskDirectory(taskId: id) {
            try? storageManager.deleteFile(at: tempDir)
        }

        state.send(.cancelled)
    }

    /// 带原因的暂停（供网络监控使用）
    func pause(reason: PauseReason) async {
        pauseReason = reason
        AppLogger.info("M3U8 task \(id) paused due to: \(reason.rawValue)")
        await pause()
    }

    // MARK: - Private Methods

    /// 估算还需要下载的字节数
    private func estimateRemainingBytes() -> Int64 {
        let completedCount = downloadState.completedSegments.count
        let remainingCount = playlist.segments.count - completedCount

        if let totalEstimated = downloadState.totalEstimatedBytes,
           totalEstimated > 0,
           playlist.segments.count > 0 {
            let avgSize = totalEstimated / Int64(playlist.segments.count)
            return avgSize * Int64(remainingCount)
        } else {
            // 粗略估算：500KB/片段
            return Int64(remainingCount) * 500_000
        }
    }

    /// 下载初始化片段（fMP4 #EXT-X-MAP）
    private func downloadMapSegment(_ mapInfo: M3U8MapInfo) async throws -> Data {
        if let byteRange = mapInfo.byteRange {
            return try await downloadByteRange(from: mapInfo.uri, byteRange: byteRange)
        } else {
            return try await networkClient.downloadData(from: mapInfo.uri)
        }
    }

    /// 使用 HTTP Range header 下载字节范围
    private func downloadByteRange(from url: URL, byteRange: M3U8ByteRange) async throws -> Data {
        let offset = byteRange.offset ?? 0
        let end = offset + byteRange.length - 1
        let rangeHeader = "bytes=\(offset)-\(end)"

        var request = URLRequest(url: url)
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        request.timeoutInterval = Constants.Network.timeoutInterval

        let (data, response) = try await URLSession.shared.data(for: request)

        // 验证服务器返回了 206 Partial Content
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode != 206 && httpResponse.statusCode != 200 {
            throw DownloadError.byteRangeRequestFailed(url: url.absoluteString)
        }

        return data
    }

    @discardableResult
    private func downloadSegment(_ segment: M3U8Segment, index: Int, to directory: URL) async throws -> Int64 {
        // 下载前检查空间
        let estimatedRemaining = estimateRemainingBytes()
        if estimatedRemaining > 0,
           !storageManager.hasEnoughSpaceForContinue(requiredBytes: estimatedRemaining) {
            AppLogger.warning("Storage space insufficient before downloading segment \(index), pausing M3U8 task: \(id)")
            throw DownloadError.insufficientStorage(
                required: estimatedRemaining,
                available: storageManager.availableStorageSpace()
            )
        }

        var data: Data

        // 问题18：支持字节范围下载
        if let byteRange = segment.byteRange {
            data = try await downloadByteRange(from: segment.url, byteRange: byteRange)
        } else {
            data = try await networkClient.downloadData(from: segment.url)
        }

        // 问题17：使用每片段对应的密钥解密，支持密钥轮换和 SAMPLE-AES
        if let encryption = segment.encryption,
           let key = encryptionKeyCache[encryption.keyURL] {
            data = try decryptData(data, key: key, iv: encryption.iv, method: encryption.method)
        }

        // 问题18：根据容器类型选择文件扩展名
        let fileExtension = playlist.isFMP4 ? "m4s" : "ts"
        let segmentURL = directory.appendingPathComponent("segment_\(String(format: "%05d", index)).\(fileExtension)")
        try data.write(to: segmentURL)

        return Int64(data.count)
    }

    /// 解密数据，支持 AES-128-CBC 和 SAMPLE-AES (AES-128-CTR)
    private func decryptData(_ data: Data, key: Data, iv: Data?, method: M3U8EncryptionMethod) throws -> Data {
        switch method {
        case .aes128:
            // AES-128-CBC + PKCS7 填充
            let cryptor = AESDecryptor(key: key, iv: iv ?? Data(repeating: 0, count: 16))
            return try cryptor.decrypt(data)
        case .sampleAES:
            // AES-128-CTR，无填充
            let ivData = iv ?? Data(repeating: 0, count: 16)
            return try AESCTRDecryptor(key: key, iv: ivData).decrypt(data)
        case .none:
            return data
        }
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
        // 问题18：根据容器类型使用对应扩展名
        let fileExtension = playlist.isFMP4 ? "m4s" : "ts"

        for i in 0..<playlist.segments.count {
            let segmentURL = segmentsDir.appendingPathComponent("segment_\(String(format: "%05d", i)).\(fileExtension)")
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

    /// 合并片段，支持 TS 和 fMP4 容器
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

        if playlist.isFMP4 {
            // fMP4 合并：先写初始化片段，再写所有媒体片段
            let initSegmentURL = directory.appendingPathComponent("init_segment.mp4")
            if FileManager.default.fileExists(atPath: initSegmentURL.path) {
                try appendFile(initSegmentURL, to: outputHandle, bufferSize: bufferSize)
            }

            for i in 0..<playlist.segments.count {
                let segmentURL = directory.appendingPathComponent("segment_\(String(format: "%05d", i)).m4s")
                guard FileManager.default.fileExists(atPath: segmentURL.path) else { continue }
                try appendFile(segmentURL, to: outputHandle, bufferSize: bufferSize)
            }
        } else {
            // TS 合并：保持现有逻辑（向后兼容）
            for i in 0..<playlist.segments.count {
                let segmentURL = directory.appendingPathComponent("segment_\(String(format: "%05d", i)).ts")
                guard FileManager.default.fileExists(atPath: segmentURL.path) else { continue }
                try appendFile(segmentURL, to: outputHandle, bufferSize: bufferSize)
            }
        }

        return outputURL
    }

    /// 流式追加文件内容到输出句柄
    private func appendFile(_ fileURL: URL, to outputHandle: FileHandle, bufferSize: Int) throws {
        guard let inputStream = InputStream(fileAtPath: fileURL.path) else { return }
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

// MARK: - AES Decryptor (CBC)

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

// MARK: - AES CTR Decryptor (SAMPLE-AES)

/// AES-128-CTR 解密器，用于 SAMPLE-AES 加密的 HLS 流
class AESCTRDecryptor {
    private let key: Data
    private let iv: Data

    init(key: Data, iv: Data) {
        self.key = key
        self.iv = iv
    }

    func decrypt(_ data: Data) throws -> Data {
        let outputSize = data.count
        var decryptedData = Data(count: outputSize)
        var numBytesDecrypted: size_t = 0

        let cryptStatus: CCCryptorStatus = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { dataBytes in
                    decryptedData.withUnsafeMutableBytes { decryptedBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCModeOptionCTR_BE),  // CTR 模式，无填充
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
