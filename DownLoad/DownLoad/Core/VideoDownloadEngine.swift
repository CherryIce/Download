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
        let format = try detectVideoFormat(from: url)

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
            configuration: configuration
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
            let record = DownloadTaskRecord(from: m3u8Task.toDownloadItem())
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

            for record in incompleteRecords {
                // 避免重复添加
                if await queueManager.getTask(by: record.id) != nil {
                    continue
                }

                let item = record.toDownloadItem()

                // 根据格式创建对应的任务
                let task: any DownloadTask
                switch item.format {
                case .mp4:
                    let mp4Task = MP4DownloadTask(
                        id: item.id,
                        url: item.url,
                        fileName: item.fileName,
                        configuration: .default,
                        networkClient: networkClient,
                        storageManager: storageManager
                    )
                    mp4Task.totalSize = item.totalSize
                    mp4Task.downloadedSize = item.downloadedSize
                    mp4Task.completedAt = item.completedAt
                    if let resumeData = item.resumeData {
                        mp4Task.resumeData = resumeData
                    }
                    task = mp4Task
                case .m3u8:
                    Logger.warning("M3U8 task restoration not fully supported yet, skipping: \(item.id)")
                    continue
                case .thunder:
                    Logger.warning("Thunder task restoration not fully supported yet, skipping: \(item.id)")
                    continue
                }

                // 添加到队列
                await queueManager.addTask(task)
                observeTaskForDatabase(task)

                // 如果之前是下载中状态，设置为暂停
                if item.state == .downloading {
                    task.state.send(.paused)
                } else {
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
    private func detectVideoFormat(from url: String) throws -> VideoFormat {
        let lowercased = url.lowercased()

        if lowercased.hasPrefix("thunder://") {
            return .thunder
        } else if lowercased.contains(".m3u8") {
            return .m3u8
        } else if lowercased.contains(".mp4") {
            return .mp4
        } else {
            // 尝试作为MP4处理
            return .mp4
        }
    }

    /// 创建对应的Handler
    private func createHandler(for format: VideoFormat, networkClient: NetworkClient) -> any DownloadHandlerProtocol {
        switch format {
        case .mp4:
            return MP4DownloadHandler(networkClient: networkClient, storageManager: storageManager)
        case .m3u8:
            return M3U8DownloadHandler(networkClient: networkClient, storageManager: storageManager)
        case .thunder:
            return ThunderDownloadHandler(networkClient: networkClient, storageManager: storageManager)
        }
    }
}
