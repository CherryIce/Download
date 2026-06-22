//
//  VideoDownloadEngine.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation
import Combine
import Network

/// 视频下载引擎
class VideoDownloadEngine {

    static let shared = VideoDownloadEngine()

    /// 数据库访问器（只读，供已完成文件页面查询记录）
    private(set) var database: DownloadTaskDatabase

    private let queueManager: DownloadQueueManager
    private let storageManager: FileStorageManager
    private let networkClient: NetworkClient
    private var databaseCancellables: [UUID: AnyCancellable] = [:]
    private var notificationCancellables: [UUID: AnyCancellable] = [:]
    private let notificationBridge = DownloadTaskNotificationBridge()
    private var hasRestoredTasks = false

    // MARK: - Network Monitoring

    private var networkCancellables: Set<AnyCancellable> = []
    /// 网络恢复延迟任务（用于防抖）
    private var networkRestoreWorkItem: DispatchWorkItem?
    /// 网络断开延迟任务（用于防抖）
    private var networkLostWorkItem: DispatchWorkItem?

    private init() {
        self.queueManager = DownloadQueueManager(maxConcurrentTasks: SettingsViewController.getMaxConcurrentDownloads())
        self.storageManager = FileStorageManager()
        self.networkClient = NetworkClient()
        do {
            self.database = try DownloadTaskDatabase()
        } catch {
            fatalError("Failed to initialize download task database: \(error)")
        }

        // 初始化网络监控订阅
        setupNetworkMonitoring()
    }

    // MARK: - Network Monitoring

    /// 设置网络状态监控订阅
    private func setupNetworkMonitoring() {
        let monitor = NetworkMonitor.shared

        // 订阅网络状态变更
        monitor.statusChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newStatus in
                self?.handleNetworkStatusChange(newStatus)
            }
            .store(in: &networkCancellables)
    }

    /// 处理网络状态变化
    private func handleNetworkStatusChange(_ newStatus: NetworkStatus) {
        // 取消之前的延迟任务（防抖）
        networkLostWorkItem?.cancel()
        networkRestoreWorkItem?.cancel()

        if newStatus == .unavailable {
            // 网络断开：延迟一小段时间后暂停所有下载任务
            let workItem = DispatchWorkItem { [weak self] in
                self?.pauseAllDownloadingTasks(reason: .networkLost)
            }
            networkLostWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Constants.NetworkMonitor.networkLostDelay,
                execute: workItem
            )
            AppLogger.info("Network lost detected, will pause downloads in \(Constants.NetworkMonitor.networkLostDelay)s")

        } else if newStatus == .cellular && !NetworkMonitor.shared.isCellularAllowed {
            // 蜂窝网络但不允许蜂窝下载：暂停所有任务
            let workItem = DispatchWorkItem { [weak self] in
                self?.pauseAllDownloadingTasks(reason: .cellularRestricted)
            }
            networkLostWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Constants.NetworkMonitor.networkLostDelay,
                execute: workItem
            )
            AppLogger.info("Cellular network detected but cellular download disabled, will pause downloads")

        } else {
            // 网络恢复（WiFi 或允许的蜂窝）：延迟后恢复因网络断开暂停的任务
            let workItem = DispatchWorkItem { [weak self] in
                self?.resumeNetworkPausedTasks()
            }
            networkRestoreWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Constants.NetworkMonitor.networkRestoreDelay,
                execute: workItem
            )
            AppLogger.info("Network restored (\(newStatus)), will resume paused downloads in \(Constants.NetworkMonitor.networkRestoreDelay)s")
        }
    }

    /// 暂停所有正在下载的任务（因网络原因）
    private func pauseAllDownloadingTasks(reason: PauseReason) {
        Task { [weak self] in
            guard let self = self else { return }
            let allTasks = await self.queueManager.getAllTasks()
            var pausedCount = 0

            for task in allTasks {
                // 只暂停正在下载中的任务
                if task.state.value == .downloading {
                    await task.pause(reason: reason)
                    pausedCount += 1
                }
            }

            AppLogger.info("Paused \(pausedCount) downloading tasks due to: \(reason.rawValue)")
        }
    }

    /// 恢复因网络断开而暂停的任务
    /// 注意：用户手动暂停的任务（pauseReason == .userInitiated）不会被恢复
    private func resumeNetworkPausedTasks() {
        Task { [weak self] in
            guard let self = self else { return }

            // 再次检查网络是否可用（防止延迟期间网络又断了）
            guard NetworkMonitor.shared.isNetworkAvailableForDownload else {
                AppLogger.info("Network no longer available, skipping auto-resume")
                return
            }

            let allTasks = await self.queueManager.getAllTasks()
            var resumedCount = 0

            for task in allTasks {
                // 只恢复因网络原因暂停的任务
                if task.state.value == .paused,
                   task.pauseReason == .networkLost || task.pauseReason == .cellularRestricted {
                    do {
                        try await task.resume()
                        resumedCount += 1
                    } catch {
                        AppLogger.error("Failed to resume network-paused task \(task.id): \(error)")
                    }
                }
            }

            AppLogger.info("Resumed \(resumedCount) network-paused tasks")
        }
    }

    /// 创建下载任务
    func createDownloadTask(
        url: String,
        fileName: String? = nil,
        configuration: DownloadConfiguration = .default
    ) async throws -> any DownloadTask {

        // 检查网络是否可用
        guard NetworkMonitor.shared.isNetworkAvailableForDownload else {
            AppLogger.warning("Cannot create download task: network not available for downloads")
            throw DownloadError.networkError(
                NSError(domain: "NetworkMonitor", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "网络不可用，无法创建下载任务"
                ])
            )
        }

        // 1. 解析URL类型
        let format = await detectVideoFormat(from: url)

        AppLogger.info("Creating download task for URL: \(url), format: \(format)")
        AppLogger.info("创建下载任务，URL: \(url), 格式: \(format)")

        // 2. 如果有自定义请求头，为该任务创建独立的 NetworkClient
        let client: NetworkClient
        if !configuration.customHeaders.isEmpty {
            client = NetworkClient(configuration: configuration)
        } else {
            client = networkClient
        }

        // 3. 创建对应的Handler
        let handler = createHandler(for: format, networkClient: client)
        AppLogger.info("Handler创建成功: \(type(of: handler))")

        // 4. 创建下载任务
        let task = try await handler.createTask(
            url: url,
            fileName: fileName,
            configuration: configuration,
            format: format
        )
        AppLogger.info("下载任务创建成功: \(task.fileName)")

        // 5. 保存到数据库并监听状态/进度变化
        persistTask(task)
        observeTaskForDatabase(task)

        // 6. 添加到队列
        await queueManager.addTask(task)
        AppLogger.info("任务已添加到队列")

        return task
    }

    /// 开始下载
    /// 任务已经由 queueManager 在 addTask 时自动调度，此方法仅用于外部显式触发（如暂停后恢复）
    func startDownload(task: any DownloadTask) async throws {
        AppLogger.info("Requesting start for download: \(task.id)")

        // 检查网络是否可用
        guard NetworkMonitor.shared.isNetworkAvailableForDownload else {
            AppLogger.warning("Cannot start download: network not available for downloads")
            throw DownloadError.networkError(
                NSError(domain: "NetworkMonitor", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "网络不可用，无法开始下载"
                ])
            )
        }

        // 检查任务是否已在队列中
        if await queueManager.getTask(by: task.id) == nil {
            // 任务不在队列中，先添加（会自动调度）
            await queueManager.addTask(task)
        } else {
            // 任务已在队列中，如果处于暂停状态，重新调度
            if task.state.value == .paused {
                // 任务会从暂停状态恢复，状态变化会触发重新调度
                try await task.resume()
            }
        }
    }

    /// 重试失败的下载任务
    func retryDownload(task: any DownloadTask) async throws {
        AppLogger.info("Requesting retry for download: \(task.id)")

        // 检查网络是否可用
        guard NetworkMonitor.shared.isNetworkAvailableForDownload else {
            AppLogger.warning("Cannot retry download: network not available for downloads")
            throw DownloadError.networkError(
                NSError(domain: "NetworkMonitor", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "网络不可用，无法重试下载"
                ])
            )
        }

        // 检查任务是否已在队列中
        if await queueManager.getTask(by: task.id) == nil {
            await queueManager.addTask(task)
        }

        try await task.retry()
    }

    /// 暂停下载
    func pauseDownload(task: any DownloadTask) async {
        AppLogger.info("Pausing download: \(task.id)")
        await task.pause()
    }

    /// 取消下载
    func cancelDownload(task: any DownloadTask) async {
        AppLogger.info("Cancelling download: \(task.id)")
        await task.cancel()
        await queueManager.removeTask(task.id)
        deleteTaskRecord(task.id)
    }

    /// 删除下载任务
    func deleteDownloadTask(task: any DownloadTask) async {
        AppLogger.info("Deleting download task: \(task.id)")

        // 先保存 completedURL 和完成状态，因为 cancel() 会改变状态
        let completedURL = task.completedURL
        let isCompleted = task.state.value == .completed

        // 如果任务未完成，先取消
        if !isCompleted {
            await task.cancel()
        }

        // 从队列中移除任务
        await queueManager.removeTask(task.id)

        // 如果任务已完成，删除对应的文件
        if isCompleted, let url = completedURL {
            try? storageManager.deleteFile(at: url)
            AppLogger.info("Deleted completed file: \(url.path)")
        }

        // 删除数据库记录
        deleteTaskRecord(task.id)

        // 清理临时文件（即使已完成也检查）
        if let tempDirectory = try? storageManager.createTaskDirectory(taskId: task.id) {
            try? storageManager.deleteFile(at: tempDirectory)
        }

        // 触发缓存清理
        triggerCacheCleanup()
    }

    /// 获取所有下载任务
    public func getAllTasks() async -> [any DownloadTask] {
        return await queueManager.getAllTasks()
    }

    /// 获取指定任务
    public func getTask(by id: UUID) async -> (any DownloadTask)? {
        return await queueManager.getTask(by: id)
    }

    /// 应用当前设置到运行中的引擎组件。
    public func applyCurrentSettings() async {
        await queueManager.updateMaxConcurrentTasks(SettingsViewController.getMaxConcurrentDownloads())
    }

    /// 清理所有下载
    public func clearAllDownloads() async {
        let tasks = await queueManager.getAllTasks()
        for task in tasks {
            await task.cancel()
        }
        await queueManager.clearAll()

        // 清理临时文件
        guard let inProgressDir = try? storageManager.inProgressDirectory() else {
            AppLogger.error("Failed to access in-progress directory for cleanup")
            // 清空数据库
            try? database.deleteAllRecords()
            await BatchDownloadManager.shared.clearBatchMetadata()
            triggerCacheCleanup()
            return
        }
        try? storageManager.cleanDirectory(at: inProgressDir)

        AppLogger.info("All downloads cleared")

        // 清空数据库
        try? database.deleteAllRecords()
        await BatchDownloadManager.shared.clearBatchMetadata()

        // 触发缓存清理
        triggerCacheCleanup()
    }

    // MARK: - Cache Cleanup

    /// 触发缓存清理（在任务完成/取消/删除后调用）
    private func triggerCacheCleanup() {
        Task(priority: .background) {
            let result = storageManager.performFullCacheCleanup()
            if result.deletedCount > 0 {
                AppLogger.info("Post-download cache cleanup: removed \(result.deletedCount) files, freed \(ByteCountFormatter.string(fromByteCount: result.freedBytes, countStyle: .file))")
            }
        }
    }

    // MARK: - Database Persistence

    /// 监听任务状态变化并同步到数据库
    private func observeTaskForDatabase(_ task: any DownloadTask) {
        let taskId = task.id

        notificationCancellables[taskId]?.cancel()
        notificationCancellables[taskId] = notificationBridge.observe(task)

        databaseCancellables[taskId]?.cancel()
        let cancellable = task.state
            .dropFirst()
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.global(qos: .utility))
            .sink { [weak self] newState in
                guard let self = self else { return }
                Task {
                    self.persistTask(task)
                    if newState == .completed || newState == .failed || newState == .cancelled {
                        self.databaseCancellables.removeValue(forKey: taskId)
                        self.notificationCancellables.removeValue(forKey: taskId)
                        // 任务结束（完成/失败/取消）后触发缓存清理
                        self.triggerCacheCleanup()
                    }
                }
            }

        databaseCancellables[taskId] = cancellable
    }

    /// 将任务持久化到数据库
    private func persistTask(_ task: any DownloadTask) {
        if let mp4Task = task as? MP4DownloadTask {
            let record = DownloadTaskRecord(from: mp4Task.toDownloadItem())
            try? database.saveRecord(record)
        } else if let m3u8Task = task as? M3U8DownloadTask {
            let record = DownloadTaskRecord(
                from: m3u8Task.toDownloadItem(),
                m3u8ResumeData: (try? m3u8Task.stateFileURL())?.path
            )
            try? database.saveRecord(record)
        }
    }

    /// 从数据库删除任务记录
    private func deleteTaskRecord(_ taskId: UUID) {
        try? database.deleteRecord(byId: taskId)
    }

    /// 从数据库恢复未完成的任务
    func restoreTasksFromDatabase() async {
        guard !hasRestoredTasks else { return }
        hasRestoredTasks = true

        AppLogger.info("Restoring tasks from database...")

        do {
            let records = try database.loadAllRecords()
            let incompleteRecords = records.filter { record in
                let state = DownloadState(rawValue: record.state) ?? .pending
                return state != .completed && state != .cancelled
            }

            AppLogger.info("Found \(incompleteRecords.count) incomplete tasks to restore")

            // 尝试获取仍在运行的后台下载任务（App 被系统杀死后重启场景）
            let activeBackgroundTasks = await BackgroundDownloadSession.shared.getAllTasks()
            var backgroundTaskURLMap: [String: Int] = [:] // URL -> taskIdentifier
            for activeTask in activeBackgroundTasks {
                if let originalRequest = activeTask.originalRequest,
                   let urlString = originalRequest.url?.absoluteString {
                    backgroundTaskURLMap[urlString] = activeTask.taskIdentifier
                }
            }

            for record in incompleteRecords {
                // 避免重复添加
                if await queueManager.getTask(by: record.id) != nil {
                    continue
                }

                let item = record.toDownloadItem()

                // 根据格式创建对应的任务
                let task: any DownloadTask
                switch item.format {
                case .mp4, .webm, .mkv, .flv, .mov:
                    let mp4Task = MP4DownloadTask(
                        id: item.id,
                        url: item.url,
                        fileName: item.fileName,
                        configuration: .default,
                        networkClient: networkClient,
                        storageManager: storageManager,
                        format: item.format
                    )
                    mp4Task.totalSize = item.totalSize
                    mp4Task.downloadedSize = item.downloadedSize
                    mp4Task.completedAt = item.completedAt
                    if let resumeData = item.resumeData {
                        mp4Task.resumeData = resumeData
                    }
                    task = mp4Task

                    // 如果有对应的后台任务仍在运行，重新注册回调
                    if let taskIdentifier = backgroundTaskURLMap[item.url] {
                        AppLogger.info("Re-registering background task handler for: \(item.url), taskIdentifier: \(taskIdentifier)")
                        BackgroundDownloadSession.shared.registerHandler(
                            for: taskIdentifier,
                            taskId: item.id,
                            progress: { [weak mp4Task] downloaded, total in
                                guard let mp4Task = mp4Task else { return }

                                mp4Task.totalSize = total
                                mp4Task.downloadedSize = downloaded
                                mp4Task.progress.send(DownloadProgress(
                                    taskId: mp4Task.id,
                                    totalBytes: total,
                                    downloadedBytes: downloaded,
                                    progress: total > 0 ? Float(downloaded) / Float(total) : 0,
                                    speed: 0,
                                    remainingTime: 0
                                ))
                            },
                            completion: { [weak mp4Task] result in
                                guard let mp4Task = mp4Task else { return }
                                switch result {
                                case .success(let tempURL):
                                    do {
                                        let destinationURL = try self.storageManager.completedDirectory().appendingPathComponent(mp4Task.fileName)
                                        try self.storageManager.moveFile(from: tempURL, to: destinationURL)
                                        mp4Task.markCompleted(url: destinationURL)
                                    } catch {
                                        AppLogger.error("Failed to move background downloaded file: \(error)")
                                        mp4Task.lastError = error
                                        mp4Task.state.send(.failed)
                                    }
                                case .failure(let error):
                                    AppLogger.error("Background download failed after restore: \(error)")
                                    mp4Task.lastError = error
                                    mp4Task.state.send(.failed)
                                }
                            }
                        )
                        // 后台任务仍在运行，保持 downloading 状态
                        task.state.send(.downloading)
                    }
                case .m3u8:
                    do {
                        guard let m3u8URL = URL(string: item.url) else {
                            AppLogger.error("Invalid M3U8 URL for restored task: \(item.id)")
                            continue
                        }

                        // 重新解析 M3U8
                        let m3u8Content = try await networkClient.downloadString(from: m3u8URL)
                        let playlist = try M3U8Parser().parse(content: m3u8Content, baseURL: m3u8URL)

                        let mediaPlaylist: M3U8MediaPlaylist
                        if let masterPlaylist = playlist as? M3U8MasterPlaylist {
                            let variant = masterPlaylist.selectBestVariant()
                            let variantContent = try await networkClient.downloadString(from: variant.url)
                            mediaPlaylist = try M3U8Parser().parse(content: variantContent, baseURL: variant.url) as! M3U8MediaPlaylist
                        } else {
                            mediaPlaylist = playlist as! M3U8MediaPlaylist
                        }

                        // 跳过直播流恢复
                        if mediaPlaylist.isLive {
                            AppLogger.warning("Skipping live stream restoration: \(item.id)")
                            continue
                        }

                        // 恢复所有加密密钥（支持密钥轮换）
                        var encryptionKeyCache: [URL: Data] = [:]
                        let uniqueKeyURLs = Set(mediaPlaylist.segments.compactMap { $0.encryption?.keyURL })
                        for keyURL in uniqueKeyURLs {
                            encryptionKeyCache[keyURL] = try await networkClient.downloadData(from: keyURL)
                        }

                        let m3u8Task = M3U8DownloadTask(
                            id: item.id,
                            url: item.url,
                            playlist: mediaPlaylist,
                            encryptionKeyCache: encryptionKeyCache,
                            fileName: item.fileName,
                            configuration: .default,
                            networkClient: networkClient,
                            storageManager: storageManager
                        )

                        m3u8Task.totalSize = item.totalSize
                        m3u8Task.downloadedSize = item.downloadedSize
                        m3u8Task.completedAt = item.completedAt

                        task = m3u8Task
                    } catch {
                        AppLogger.error("Failed to restore M3U8 task \(item.id): \(error)")
                        continue
                    }
                case .thunder, .thunderP2P, .magnet:
                    AppLogger.warning("Thunder/P2P/Magnet task restoration not fully supported, skipping: \(item.id)")
                    continue
                }

                // 添加到队列
                await queueManager.addTask(task)
                observeTaskForDatabase(task)

                // 如果之前是下载中状态且没有匹配的后台任务，设置为暂停
                if item.state == .downloading && backgroundTaskURLMap[item.url] == nil {
                    task.state.send(.paused)
                } else if item.state != .downloading {
                    task.state.send(item.state)
                }
            }

            AppLogger.info("Restored tasks from database")
            await BatchDownloadManager.shared.restoreBatchDownloads()
        } catch {
            AppLogger.error("Failed to restore tasks from database: \(error)")
        }
    }

    // MARK: - Batch Download Methods

    /// 批量创建下载任务
    public func createBatchDownload(
        name: String,
        urls: [String],
        fileNames: [String]? = nil,
        configuration: DownloadConfiguration = .default
    ) async -> BatchDownloadManager.BatchDownloadResult {
        return await BatchDownloadManager.shared.createBatchDownload(
            name: name,
            urls: urls,
            fileNames: fileNames,
            configuration: configuration
        )
    }

    /// 开始批量下载
    public func startBatchDownload(batchId: UUID) async throws {
        try await BatchDownloadManager.shared.startBatchDownload(batchId: batchId)
    }

    /// 暂停批量下载
    public func pauseBatchDownload(batchId: UUID) async {
        await BatchDownloadManager.shared.pauseBatchDownload(batchId: batchId)
    }

    /// 取消批量下载
    public func cancelBatchDownload(batchId: UUID) async {
        await BatchDownloadManager.shared.cancelBatchDownload(batchId: batchId)
    }

    /// 删除批量下载
    public func deleteBatchDownload(batchId: UUID) async {
        await BatchDownloadManager.shared.deleteBatchDownload(batchId: batchId)
    }

    /// 获取所有批量下载任务
    public func getAllBatchTasks() async -> [BatchDownloadManager.BatchDownloadTask] {
        return await BatchDownloadManager.shared.getAllBatchTasks()
    }

    /// 获取指定批量下载任务
    public func getBatchTask(by batchId: UUID) async -> BatchDownloadManager.BatchDownloadTask? {
        return await BatchDownloadManager.shared.getBatchTask(by: batchId)
    }

    /// 获取批量下载进度
    public func getBatchProgress(batchId: UUID) async -> (total: Int, completed: Int, downloading: Int, paused: Int, failed: Int, failedInCreation: Int)? {
        return await BatchDownloadManager.shared.getBatchProgress(batchId: batchId)
    }

    /// 重试批量任务中的失败项
    public func retryFailedItems(batchId: UUID) async -> BatchDownloadManager.BatchDownloadResult? {
        return await BatchDownloadManager.shared.retryFailedItems(batchId: batchId)
    }

    /// 清空所有批量下载
    public func clearAllBatchDownloads() async {
        await BatchDownloadManager.shared.clearAllBatchDownloads()
    }

    /// 从数据库恢复批量下载分组
    public func restoreBatchDownloads() async {
        await BatchDownloadManager.shared.restoreBatchDownloads()
    }


    // MARK: - Private Methods

    /// 检测视频格式
    /// 采用三级检测策略：
    /// 1. URL 字符串快速匹配（无网络开销）
    /// 2. HEAD 请求 Content-Type 检测（需要一次网络往返）
    /// 3. 兜底默认 .mp4
    private func detectVideoFormat(from url: String) async -> VideoFormat {
        // 第一级：URL 字符串快速匹配
        if let format = VideoFormatDetector.detectFromURLString(url) {
            AppLogger.info("Format detected from URL string: \(format) for URL: \(url)")
            return format
        }

        // 第二级：HEAD 请求 Content-Type 检测
        guard let urlObj = URL(string: url) else {
            AppLogger.warning("Invalid URL for format detection, defaulting to mp4: \(url)")
            return .mp4
        }

        do {
            let headers = try await networkClient.fetchResponseHeaders(from: urlObj)
            if let format = VideoFormatDetector.detectFromContentType(headers.contentType) {
                AppLogger.info("Format detected from Content-Type '\(headers.contentType ?? "nil")': \(format) for URL: \(url)")
                return format
            }

            AppLogger.info("Content-Type '\(headers.contentType ?? "nil")' not recognized, defaulting to mp4 for URL: \(url)")
            return .mp4
        } catch {
            // HEAD 请求失败，兜底为 mp4
            AppLogger.warning("HEAD request failed for format detection (\(error.localizedDescription)), defaulting to mp4 for URL: \(url)")
            return .mp4
        }
    }

    /// 创建对应的Handler
    private func createHandler(for format: VideoFormat, networkClient: NetworkClient) -> any DownloadHandlerProtocol {
        switch format {
        case .mp4, .webm, .mkv, .flv, .mov:
            return MP4DownloadHandler(networkClient: networkClient, storageManager: storageManager)
        case .m3u8:
            return M3U8DownloadHandler(networkClient: networkClient, storageManager: storageManager)
        case .thunder, .thunderP2P, .magnet:
            return ThunderDownloadHandler(networkClient: networkClient, storageManager: storageManager)
        }
    }
}
