//
//  VideoDownloadEngine.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation
import Combine

/// 视频下载引擎
class VideoDownloadEngine {

    static let shared = VideoDownloadEngine()

    private let queueManager: DownloadQueueManager
    private let storageManager: FileStorageManager
    private let networkClient: NetworkClient
    private let database: DownloadTaskDatabase
    private var databaseCancellables: [UUID: AnyCancellable] = [:]
    private var hasRestoredTasks = false

    private init() {
        self.queueManager = DownloadQueueManager()
        self.storageManager = FileStorageManager()
        self.networkClient = NetworkClient()
        do {
            self.database = try DownloadTaskDatabase()
        } catch {
            fatalError("Failed to initialize download task database: \(error)")
        }
    }

    /// 创建下载任务
    func createDownloadTask(
        url: String,
        fileName: String? = nil,
        configuration: DownloadConfiguration = .default
    ) async throws -> any DownloadTask {

        // 1. 解析URL类型
        let format = await detectVideoFormat(from: url)

        Logger.info("Creating download task for URL: \(url), format: \(format)")
        print("🔥 VideoDownloadEngine: 创建下载任务，URL: \(url), 格式: \(format)")

        // 2. 如果有自定义请求头，为该任务创建独立的 NetworkClient
        let client: NetworkClient
        if !configuration.customHeaders.isEmpty {
            client = NetworkClient(configuration: configuration)
        } else {
            client = networkClient
        }

        // 3. 创建对应的Handler
        let handler = createHandler(for: format, networkClient: client)
        print("✅ Handler创建成功: \(type(of: handler))")

        // 4. 创建下载任务
        let task = try await handler.createTask(
            url: url,
            fileName: fileName,
            configuration: configuration,
            format: format
        )
        print("✅ 下载任务创建成功: \(task.fileName ?? "未知文件名")")

        // 5. 添加到队列
        await queueManager.addTask(task)
        print("✅ 任务已添加到队列")

        // 6. 保存到数据库并监听状态变化
        persistTask(task)
        observeTaskForDatabase(task)

        return task
    }

    /// 开始下载
    /// 任务已经由 queueManager 在 addTask 时自动调度，此方法仅用于外部显式触发（如暂停后恢复）
    func startDownload(task: any DownloadTask) async throws {
        Logger.info("Requesting start for download: \(task.id)")

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

    /// 暂停下载
    func pauseDownload(task: any DownloadTask) async {
        Logger.info("Pausing download: \(task.id)")
        await task.pause()
    }

    /// 取消下载
    func cancelDownload(task: any DownloadTask) async {
        Logger.info("Cancelling download: \(task.id)")
        await task.cancel()
        await queueManager.removeTask(task.id)
        deleteTaskRecord(task.id)
    }

    /// 删除下载任务
    func deleteDownloadTask(task: any DownloadTask) async {
        Logger.info("Deleting download task: \(task.id)")

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
            Logger.info("Deleted completed file: \(url.path)")
        }

        // 删除数据库记录
        deleteTaskRecord(task.id)
    }

    /// 获取所有下载任务
    public func getAllTasks() async -> [any DownloadTask] {
        return await queueManager.getAllTasks()
    }

    /// 获取指定任务
    public func getTask(by id: UUID) async -> (any DownloadTask)? {
        return await queueManager.getTask(by: id)
    }

    /// 清理所有下载
    public func clearAllDownloads() async {
        let tasks = await queueManager.getAllTasks()
        for task in tasks {
            await task.cancel()
        }
        await queueManager.clearAll()

        // 清理临时文件
        let inProgressDir = storageManager.inProgressDirectory()
        try? storageManager.cleanDirectory(at: inProgressDir)

        Logger.info("All downloads cleared")

        // 清空数据库
        try? database.deleteAllRecords()
    }

    // MARK: - Database Persistence

    /// 监听任务状态变化并同步到数据库
    private func observeTaskForDatabase(_ task: any DownloadTask) {
        let taskId = task.id

        let cancellable = task.state
            .dropFirst()
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.global(qos: .utility))
            .sink { [weak self] newState in
                guard let self = self else { return }
                Task {
                    self.persistTask(task)
                    if newState == .completed || newState == .failed || newState == .cancelled {
                        self.databaseCancellables.removeValue(forKey: taskId)
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
                m3u8ResumeData: m3u8Task.stateFileURL?.path
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

        Logger.info("Restoring tasks from database...")

        do {
            let records = try database.loadAllRecords()
            let incompleteRecords = records.filter { record in
                let state = DownloadState(rawValue: record.state) ?? .pending
                return state != .completed && state != .cancelled
            }

            Logger.info("Found \(incompleteRecords.count) incomplete tasks to restore")

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
                        Logger.info("Re-registering background task handler for: \(item.url), taskIdentifier: \(taskIdentifier)")
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
                                        let destinationURL = self.storageManager.completedDirectory().appendingPathComponent(mp4Task.fileName)
                                        try self.storageManager.moveFile(from: tempURL, to: destinationURL)
                                        mp4Task.markCompleted(url: destinationURL)
                                    } catch {
                                        Logger.error("Failed to move background downloaded file: \(error)")
                                        mp4Task.state.send(.failed)
                                    }
                                case .failure(let error):
                                    Logger.error("Background download failed after restore: \(error)")
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
                            Logger.error("Invalid M3U8 URL for restored task: \(item.id)")
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

                        // 恢复加密密钥
                        var encryptionKey: Data?
                        if mediaPlaylist.isEncrypted, let encryption = mediaPlaylist.segments.first?.encryption {
                            encryptionKey = try await networkClient.downloadData(from: encryption.keyURL)
                        }

                        let m3u8Task = M3U8DownloadTask(
                            id: item.id,
                            url: item.url,
                            playlist: mediaPlaylist,
                            encryptionKey: encryptionKey,
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
                        Logger.error("Failed to restore M3U8 task \(item.id): \(error)")
                        continue
                    }
                case .thunder:
                    Logger.warning("Thunder task restoration not fully supported yet, skipping: \(item.id)")
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

            Logger.info("Restored tasks from database")
        } catch {
            Logger.error("Failed to restore tasks from database: \(error)")
        }
    }

    // MARK: - Batch Download Methods

    /// 批量创建下载任务
    public func createBatchDownload(
        name: String,
        urls: [String],
        fileNames: [String]? = nil,
        configuration: DownloadConfiguration = .default
    ) async throws -> BatchDownloadManager.BatchDownloadTask {
        return try await BatchDownloadManager.shared.createBatchDownload(
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
    public func getBatchProgress(batchId: UUID) async -> (total: Int, completed: Int, downloading: Int, paused: Int, failed: Int)? {
        return await BatchDownloadManager.shared.getBatchProgress(batchId: batchId)
    }


    /// 清空所有批量下载
    public func clearAllBatchDownloads() async {
        await BatchDownloadManager.shared.clearAllBatchDownloads()
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
            Logger.info("Format detected from URL string: \(format) for URL: \(url)")
            return format
        }

        // 第二级：HEAD 请求 Content-Type 检测
        guard let urlObj = URL(string: url) else {
            Logger.warning("Invalid URL for format detection, defaulting to mp4: \(url)")
            return .mp4
        }

        do {
            let headers = try await networkClient.fetchResponseHeaders(from: urlObj)
            if let format = VideoFormatDetector.detectFromContentType(headers.contentType) {
                Logger.info("Format detected from Content-Type '\(headers.contentType ?? "nil")': \(format) for URL: \(url)")
                return format
            }

            Logger.info("Content-Type '\(headers.contentType ?? "nil")' not recognized, defaulting to mp4 for URL: \(url)")
            return .mp4
        } catch {
            // HEAD 请求失败，兜底为 mp4
            Logger.warning("HEAD request failed for format detection (\(error.localizedDescription)), defaulting to mp4 for URL: \(url)")
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
        case .thunder:
            return ThunderDownloadHandler(networkClient: networkClient, storageManager: storageManager)
        }
    }
}
