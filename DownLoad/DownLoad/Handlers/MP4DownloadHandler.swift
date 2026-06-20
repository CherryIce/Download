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
        configuration: DownloadConfiguration,
        format: VideoFormat
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
        let finalFileName = fileName ?? "video_\(taskId.uuidString).\(format.fileExtension)"

        let task = MP4DownloadTask(
            id: taskId,
            url: url,
            fileName: finalFileName,
            configuration: configuration,
            networkClient: networkClient,
            storageManager: storageManager,
            format: format
        )

        return task
    }
}

/// MP4下载任务（支持断点续传 + 后台下载）
class MP4DownloadTask: DownloadTask {

    let id: UUID
    let url: String
    let fileName: String
    let configuration: DownloadConfiguration

    let state = CurrentValueSubject<DownloadState, Never>(.pending)
    let progress = CurrentValueSubject<DownloadProgress, Never>(.empty)
    private(set) var completedURL: URL?

    let format: VideoFormat
    var totalSize: Int64?
    var downloadedSize: Int64 = 0
    let createdAt: Date = Date()
    var completedAt: Date?
    var resumeData: Data?

    private let networkClient: NetworkClient
    private let storageManager: FileStorageManager
    private let speedCalculator = SpeedCalculator()
    private var task: Task<Void, Error>?
    private var downloadHandle: ResumableDownloadHandle?

    /// 后台下载任务引用（使用 BackgroundDownloadSession 时）
    private var backgroundDownloadTask: URLSessionDownloadTask?
    /// 是否使用后台下载模式
    private var useBackgroundDownload: Bool {
        return configuration.enableBackgroundDownload
    }

    /// 任务终止原因，用于区分暂停、取消和真正的失败
    private enum TaskTerminationReason {
        case none
        case pauseRequested
        case cancelRequested
    }

    private var terminationReason: TaskTerminationReason = .none

    /// 暂停原因（用于区分用户手动暂停和网络自动暂停）
    var pauseReason: PauseReason? = nil

    /// 下载优先级
    var priority: DownloadPriority = .normal

    /// 标记下载完成（供外部如恢复场景使用）
    func markCompleted(url: URL) {
        self.completedURL = url
        self.completedAt = Date()
        self.resumeData = nil
        self.state.send(.completed)
    }

    init(
        id: UUID,
        url: String,
        fileName: String,
        configuration: DownloadConfiguration,
        networkClient: NetworkClient,
        storageManager: FileStorageManager,
        format: VideoFormat = .mp4,
        priority: DownloadPriority = .normal
    ) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.configuration = configuration
        self.networkClient = networkClient
        self.storageManager = storageManager
        self.format = format
        self.priority = priority
    }

    func resume() async throws {
        guard state.value != .downloading else { return }

        // 恢复时清除暂停原因
        pauseReason = nil

        state.send(.downloading)

        if useBackgroundDownload {
            try await resumeWithBackgroundDownload()
        } else {
            try await resumeWithForegroundDownload()
        }
    }

    func retry() async throws {
        guard state.value == .failed else {
            AppLogger.warning("MP4 retry() called but state is not .failed (current: \(state.value.displayText)), task: \(id)")
            return
        }

        AppLogger.info("Retrying MP4 download task: \(id)")

        // 重置终止原因和暂停原因
        terminationReason = .none
        pauseReason = nil

        // 重置状态为 pending，保留 resumeData 和 downloadedSize 用于断点续传
        state.send(.pending)

        // 重新启动下载（resume() 会自动使用已有的 resumeData）
        try await resume()
    }

    // MARK: - Storage Space Check During Download

    /// 检查是否有足够空间继续下载，空间不足时自动暂停
    private func checkStorageSpaceDuringDownload(downloaded: Int64, total: Int64) {
        let remainingBytes = total - downloaded
        if remainingBytes > 0,
           !storageManager.hasEnoughSpaceForContinue(requiredBytes: remainingBytes) {
            AppLogger.warning("Storage space insufficient during MP4 download, pausing task: \(id)")
            Task { [weak self] in
                guard let self = self else { return }
                await self.pause(reason: .insufficientStorage)
            }
        }
    }

    // MARK: - 前台下载（原有逻辑）

    private func resumeWithForegroundDownload() async throws {
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

                    // 存储空间持续监控
                    self.checkStorageSpaceDuringDownload(downloaded: downloaded, total: total)

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

                    self.totalSize = total
                    self.downloadedSize = downloaded
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
                self.completedAt = Date()
                state.send(.completed)

            } catch is CancellationError {
                // Task 被取消（来自 cancel() 调用）
                if self.terminationReason != .pauseRequested {
                    state.send(.cancelled)
                }
                // 如果是暂停导致的取消，不发送状态（pause() 会发送 .paused）
            } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
                // URLSession 任务被取消（来自 pause() 的 cancelWithResumeData）
                if self.terminationReason != .pauseRequested {
                    state.send(.cancelled)
                }
                // 如果是暂停导致的取消，不发送状态（pause() 会发送 .paused）
            } catch {
                AppLogger.error("MP4 download failed: \(error)")
                state.send(.failed)
                throw DownloadError.taskFailed(error)
            }
        }

        try await task?.value
    }

    // MARK: - 后台下载（使用 BackgroundDownloadSession）

    private func resumeWithBackgroundDownload() async throws {
        task = Task {
            do {
                guard let videoURL = URL(string: url) else {
                    throw DownloadError.invalidURL(url)
                }

                // 使用 withCheckedContinuation 将回调式 API 桥接为 async/await
                let downloadedURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in

                    let bgSession = BackgroundDownloadSession.shared

                    // 创建 URLRequest（支持自定义请求头）
                    var request = URLRequest(url: videoURL)
                    for (key, value) in self.configuration.customHeaders {
                        request.setValue(value, forHTTPHeaderField: key)
                    }

                    // 创建后台下载任务
                    let bgTask: URLSessionDownloadTask
                    if let resumeData = self.resumeData {
                        bgTask = bgSession.createDownloadTask(
                            resumeData: resumeData,
                            request: request,
                            taskId: self.id,
                            progress: { [weak self] downloaded, total in
                                guard let self = self else { return }

                                // 存储空间持续监控
                                self.checkStorageSpaceDuringDownload(downloaded: downloaded, total: total)

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

                                self.totalSize = total
                                self.downloadedSize = downloaded
                                self.progress.send(progressInfo)
                            },
                            completion: { result in
                                switch result {
                                case .success(let tempURL):
                                    continuation.resume(returning: tempURL)
                                case .failure(let error):
                                    continuation.resume(throwing: error)
                                }
                            }
                        ) ?? {
                            // resumeData 无效，创建新任务
                            let newTask = bgSession.createDownloadTask(
                                request: request,
                                taskId: self.id,
                                progress: { [weak self] downloaded, total in
                                    guard let self = self else { return }

                                    // 存储空间持续监控
                                    self.checkStorageSpaceDuringDownload(downloaded: downloaded, total: total)

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

                                    self.totalSize = total
                                    self.downloadedSize = downloaded
                                    self.progress.send(progressInfo)
                                },
                                completion: { result in
                                    switch result {
                                    case .success(let tempURL):
                                        continuation.resume(returning: tempURL)
                                    case .failure(let error):
                                        continuation.resume(throwing: error)
                                    }
                                }
                            )
                            return newTask
                        }()
                    } else {
                        bgTask = bgSession.createDownloadTask(
                            request: request,
                            taskId: self.id,
                            progress: { [weak self] downloaded, total in
                                guard let self = self else { return }

                                // 存储空间持续监控
                                self.checkStorageSpaceDuringDownload(downloaded: downloaded, total: total)

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

                                self.totalSize = total
                                self.downloadedSize = downloaded
                                self.progress.send(progressInfo)
                            },
                            completion: { result in
                                switch result {
                                case .success(let tempURL):
                                    continuation.resume(returning: tempURL)
                                case .failure(let error):
                                    continuation.resume(throwing: error)
                                }
                            }
                        )
                    }

                    // 保存后台任务引用
                    self.backgroundDownloadTask = bgTask
                    bgTask.resume()
                }

                // 移动到完成目录
                let destinationURL = storageManager.completedDirectory().appendingPathComponent(fileName)
                try storageManager.moveFile(from: downloadedURL, to: destinationURL)

                // 清理 resumeData
                self.resumeData = nil
                self.backgroundDownloadTask = nil

                self.completedURL = destinationURL
                self.completedAt = Date()
                state.send(.completed)

            } catch is CancellationError {
                // Task 被取消（来自 cancel() 调用）
                if self.terminationReason != .pauseRequested {
                    state.send(.cancelled)
                }
                // 如果是暂停导致的取消，不发送状态（pause() 会发送 .paused）
            } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
                // URLSession 后台任务被取消
                if self.terminationReason != .pauseRequested {
                    state.send(.cancelled)
                }
                // 如果是暂停导致的取消，不发送状态（pause() 会发送 .paused）
            } catch {
                AppLogger.error("MP4 background download failed: \(error)")
                state.send(.failed)
                throw DownloadError.taskFailed(error)
            }
        }

        try await task?.value
    }

    func pause() async {
        // 如果没有外部指定原因，默认为用户手动暂停
        if pauseReason == nil {
            pauseReason = .userInitiated
        }

        terminationReason = .pauseRequested
        defer { terminationReason = .none }

        if useBackgroundDownload {
            // 后台模式：通过 BackgroundDownloadSession 取消并获取 resumeData
            if let bgTask = backgroundDownloadTask {
                let data = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                    BackgroundDownloadSession.shared.cancelTask(bgTask) { resumeData in
                        continuation.resume(returning: resumeData)
                    }
                }
                resumeData = data
                AppLogger.info("MP4 background download paused, resumeData saved (\(data?.count ?? 0) bytes)")
            }
            backgroundDownloadTask = nil
        } else {
            // 前台模式：通过句柄调用 cancel(byProducingResumeData:) 获取 resumeData
            if let handle = downloadHandle {
                let data = await handle.cancelWithResumeData()
                resumeData = data
                AppLogger.info("MP4 download paused, resumeData saved (\(data?.count ?? 0) bytes)")
            }
            downloadHandle = nil
        }
        task?.cancel()
        speedCalculator.reset()
        state.send(.paused)
    }

    func cancel() async {
        terminationReason = .cancelRequested
        defer { terminationReason = .none }

        // 取消时清除暂停原因（不保留恢复能力）
        pauseReason = nil
        resumeData = nil

        if useBackgroundDownload {
            // 后台模式：取消后台任务
            if let bgTask = backgroundDownloadTask {
                BackgroundDownloadSession.shared.cancelTask(bgTask) { _ in }
            }
            backgroundDownloadTask = nil
        } else {
            // 前台模式
            downloadHandle = nil
        }

        task?.cancel()
        speedCalculator.reset()

        // 清理临时文件
        let tempDirectory = storageManager.createTaskDirectory(taskId: id)
        try? storageManager.deleteFile(at: tempDirectory)

        state.send(.cancelled)
    }

    /// 带原因的暂停（供网络监控使用）
    func pause(reason: PauseReason) async {
        pauseReason = reason
        AppLogger.info("MP4 task \(id) paused due to: \(reason.rawValue)")
        await pause()
    }
}

extension MP4DownloadTask {
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
