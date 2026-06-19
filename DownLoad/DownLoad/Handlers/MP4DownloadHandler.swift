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

        // 检查存储空间：先尝试获取远程文件大小，若获取失败则使用配置中的默认值
        let requiredBytes: Int64
        do {
            let remoteSize = try await networkClient.fetchRemoteFileSize(from: videoURL)
            requiredBytes = remoteSize > 0 ? remoteSize : Constants.Storage.defaultMP4SpaceRequirement
        } catch {
            requiredBytes = Constants.Storage.defaultMP4SpaceRequirement
        }
        try storageManager.checkAvailableSpace(requiredBytes: requiredBytes)

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

/// MP4下载任务（支持断点续传）
class MP4DownloadTask: DownloadTask {

    let id: UUID
    let url: String
    let fileName: String
    let configuration: DownloadConfiguration

    let state = CurrentValueSubject<DownloadState, Never>(.pending)
    let progress = CurrentValueSubject<DownloadProgress, Never>(.empty)
    private(set) var completedURL: URL?

    private let networkClient: NetworkClient
    private let storageManager: FileStorageManager
    private let speedCalculator = SpeedCalculator()
    private var task: Task<Void, Error>?
    private var downloadHandle: ResumableDownloadHandle?

    /// 断点续传数据，暂停时保存，恢复时传入
    private(set) var resumeData: Data?

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

                // 使用支持断点续传的可取消下载方法，传入之前保存的 resumeData
                let (downloadedURL, handle) = try await networkClient.downloadFileWithResumeCancellable(
                    from: videoURL,
                    to: tempFileURL,
                    resumeData: resumeData
                ) { [weak self] downloaded, total in
                    guard let self = self else { return }

                    let now = Date().timeIntervalSince1970
                    self.speedCalculator.addSample(bytes: downloaded, timestamp: now)
                    let speed = self.speedCalculator.calculateSpeed()
                    let remaining = self.speedCalculator.calculateRemainingTime(totalBytes: total, downloadedBytes: downloaded)

                    let progressInfo = DownloadProgress(
                        taskId: self.id,
                        totalBytes: total,
                        downloadedBytes: downloaded,
                        progress: total > 0 ? Float(downloaded) / Float(total) : 0,
                        speed: speed,
                        remainingTime: remaining
                    )

                    self.progress.send(progressInfo)
                }

                // 保存句柄，供 pause() 使用
                self.downloadHandle = handle

                // 移动到完成目录
                let destinationURL = storageManager.completedDirectory().appendingPathComponent(fileName)
                try storageManager.moveFile(from: downloadedURL, to: destinationURL)

                // 清理临时目录和 resumeData
                try? storageManager.deleteFile(at: tempDirectory)
                self.resumeData = nil
                self.downloadHandle = nil

                self.completedURL = destinationURL
                state.send(.completed)

            } catch is CancellationError {
                // Task 被取消（来自 cancel() 调用）
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
        // 通过句柄调用 cancel(byProducingResumeData:) 获取 resumeData
        if let handle = downloadHandle {
            let data = await handle.cancelWithResumeData()
            resumeData = data
            Logger.info("MP4 download paused, resumeData saved (\(data?.count ?? 0) bytes)")
        }
        task?.cancel()
        speedCalculator.reset()
        downloadHandle = nil
        state.send(.paused)
    }

    func cancel() async {
        // 取消时清除 resumeData（不保留恢复能力）
        resumeData = nil
        downloadHandle = nil
        task?.cancel()
        speedCalculator.reset()

        // 清理临时文件
        let tempDirectory = storageManager.createTaskDirectory(taskId: id)
        try? storageManager.deleteFile(at: tempDirectory)

        state.send(.cancelled)
    }
}
