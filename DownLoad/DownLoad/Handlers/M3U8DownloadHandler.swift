//
//  M3U8DownloadHandler.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation
import Combine

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
        configuration: DownloadConfiguration
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

    private let networkClient: NetworkClient
    private let storageManager: FileStorageManager
    private var downloadState: M3U8DownloadState
    private var task: Task<Void, Error>?

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
        self.downloadState = M3U8DownloadState(totalSegments: playlist.segments.count)
    }

    func resume() async throws {
        guard state.value != .downloading else { return }

        state.send(.downloading)

        task = Task {
            do {
                // 创建临时目录
                let tempDir = storageManager.createTaskDirectory(taskId: id)
                let segmentsDir = tempDir.appendingPathComponent("segments")
                try FileManager.default.createDirectory(at: segmentsDir, withIntermediateDirectories: true)

                // 并发下载TS片段
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for (index, segment) in playlist.segments.enumerated() {
                        // 跳过已完成的片段
                        if downloadState.completedSegments.contains(index) {
                            continue
                        }

                        group.addTask {
                            try await self.downloadSegment(
                                segment,
                                index: index,
                                to: segmentsDir
                            )

                            // 更新进度
                            await self.updateProgress(index: index)
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

                state.send(.completed(outputURL))

            } catch is CancellationError {
                state.send(.cancelled)
            } catch {
                Logger.error("M3U8 download failed: \(error)")
                state.send(.failed)
                throw DownloadError.taskFailed(error)
            }
        }

        try await task?.value
    }

    func pause() async {
        task?.cancel()
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

    private func downloadSegment(_ segment: M3U8Segment, index: Int, to directory: URL) async throws {
        // 下载数据
        var data = try await networkClient.downloadData(from: segment.url)

        // 解密（如果需要）
        if let encryption = segment.encryption, let key = encryptionKey {
            data = try decryptData(data, key: key, iv: encryption.iv)
        }

        // 保存片段
        let segmentURL = directory.appendingPathComponent("segment_\(String(format: "%05d", index)).ts")
        try data.write(to: segmentURL)
    }

    private func decryptData(_ data: Data, key: Data, iv: Data?) throws -> Data {
        // 使用AES-128-CBC解密
        let cryptor = AESDecryptor(key: key, iv: iv ?? Data(repeating: 0, count: 16))
        return try cryptor.decrypt(data)
    }

    private func updateProgress(index: Int) async {
        downloadState.completedSegments.insert(index)

        let completed = downloadState.completedSegments.count
        let total = downloadState.totalSegments
        let progressValue = Float(completed) / Float(total)

        let progressInfo = DownloadProgress(
            taskId: id,
            totalBytes: Int64(total),
            downloadedBytes: Int64(completed),
            progress: progressValue,
            speed: 0,
            remainingTime: nil
        )

        progress.send(progressInfo)
    }

    private func mergeSegments(in directory: URL, to outputURL: URL) async throws -> URL {
        // 创建输出文件
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)

        defer {
            try? outputHandle.close()
        }

        // 按顺序读取并合并所有TS片段
        for i in 0..<playlist.segments.count {
            let segmentURL = directory.appendingPathComponent("segment_\(String(format: "%05d", i)).ts")

            if FileManager.default.fileExists(atPath: segmentURL.path) {
                let data = try Data(contentsOf: segmentURL)
                try outputHandle.write(contentsOf: data)
            }
        }

        return outputURL
    }
}

// MARK: - AES Decryptor

import CommonCrypto

class AESDecryptor {
    private let key: Data
    private let iv: Data

    init(key: Data, iv: Data) {
        self.key = key
        self.iv = iv
    }

    func decrypt(_ data: Data) throws -> Data {
        var decryptedData = Data(count: data.count + kCCBlockSizeAES128)
        var numBytesDecrypted: size_t = 0

        let cryptStatus = key.withUnsafeBytes { keyBytes in
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
                            decryptedData.count,
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
