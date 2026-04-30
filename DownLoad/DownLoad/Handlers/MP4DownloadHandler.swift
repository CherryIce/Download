//
//  MP4DownloadHandler.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation
import Combine

/// MP4下载处理器
class MP4DownloadHandler: DownloadHandlerProtocol {

    private let networkClient: NetworkClient
    private let storageManager: FileStorageManager

    init(networkClient: NetworkClient, storageManager: FileStorageManager) {
        self.networkClient = networkClient
        self.storageManager = storageManager
    }

    func createTask(
        url: String,
        fileName: String?,
        configuration: DownloadConfiguration
    ) async throws -> any DownloadTask {
        guard let videoURL = URL(string: url) else {
            throw DownloadError.invalidURL(url)
        }

        // 检查存储空间
        try storageManager.checkAvailableSpace(requiredBytes: 100 * 1024 * 1024) // 假设至少需要100MB

        let taskId = UUID()
        let finalFileName = fileName ?? "video_\(taskId.uuidString).mp4"

        let task = MP4DownloadTask(
            id: taskId,
            url: url,
            fileName: finalFileName,
            configuration: configuration,
            networkClient: networkClient,
            storageManager: storageManager
        )

        return task
    }
}

/// MP4下载任务
class MP4DownloadTask: DownloadTask {

    let id: UUID
    let url: String
    let fileName: String
    let configuration: DownloadConfiguration

    let state = CurrentValueSubject<DownloadState, Never>(.pending)
    let progress = CurrentValueSubject<DownloadProgress, Never>(.empty)

    private let networkClient: NetworkClient
    private let storageManager: FileStorageManager
    private var task: Task<Void, Error>?

    init(
        id: UUID,
        url: String,
        fileName: String,
        configuration: DownloadConfiguration,
        networkClient: NetworkClient,
        storageManager: FileStorageManager
    ) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.configuration = configuration
        self.networkClient = networkClient
        self.storageManager = storageManager
    }

    func resume() async throws {
        guard state.value != .downloading else { return }

        state.send(.downloading)

        task = Task {
            do {
                guard let videoURL = URL(string: url) else {
                    throw DownloadError.invalidURL(url)
                }

                let tempDirectory = storageManager.createTaskDirectory(taskId: id)
                let tempFileURL = tempDirectory.appendingPathComponent("download.tmp")

                // 下载文件
                let _ = try await networkClient.downloadFile(
                    from: videoURL,
                    to: tempFileURL
                ) { [weak self] downloaded, total in
                    guard let self = self else { return }

                    let progressInfo = DownloadProgress(
                        taskId: self.id,
                        totalBytes: total,
                        downloadedBytes: downloaded,
                        progress: total > 0 ? Float(downloaded) / Float(total) : 0,
                        speed: 0,
                        remainingTime: nil
                    )

                    self.progress.send(progressInfo)
                }

                // 移动到完成目录
                let destinationURL = storageManager.completedDirectory().appendingPathComponent(fileName)
                try storageManager.moveFile(from: tempFileURL, to: destinationURL)

                // 清理临时目录
                try? storageManager.deleteFile(at: tempDirectory)

                state.send(.completed(destinationURL))

            } catch is CancellationError {
                state.send(.cancelled)
            } catch {
                Logger.error("MP4 download failed: \(error)")
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
        let tempDirectory = storageManager.createTaskDirectory(taskId: id)
        try? storageManager.deleteFile(at: tempDirectory)

        state.send(.cancelled)
    }
}
