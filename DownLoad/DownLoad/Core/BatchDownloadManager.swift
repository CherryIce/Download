//
//  BatchDownloadManager.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation
import Combine

/// 批量下载管理器
actor BatchDownloadManager {

    static let shared = BatchDownloadManager()

    private var batchTasks: [UUID: BatchDownloadTask] = [:]
    private var taskBatchIds: [UUID: Set<UUID>] = [:]
    private var taskStateCancellables: [UUID: AnyCancellable] = [:]

    private init() {}

    /// 批量任务失败项
    struct BatchFailedItem: Identifiable {
        let id: UUID
        let url: String
        let fileName: String
        let errorDescription: String
        let failedAt: Date

        init(url: String, fileName: String, error: Error) {
            self.id = UUID()
            self.url = url
            self.fileName = fileName
            self.errorDescription = error.localizedDescription
            self.failedAt = Date()
        }

        init(record: BatchDownloadFailedItemRecord) {
            self.id = record.id
            self.url = record.url
            self.fileName = record.fileName
            self.errorDescription = record.errorDescription
            self.failedAt = record.failedAt
        }
    }

    /// 批量下载创建结果
    struct BatchDownloadResult {
        let batchTask: BatchDownloadTask
        let failedCount: Int
        let hasFailures: Bool

        var summary: String {
            let total = batchTask.taskItems.count + batchTask.failedItems.count
            let success = batchTask.taskItems.count
            let failed = failedCount
            return "共\(total)项，成功\(success)项，失败\(failed)项"
        }
    }

    /// 批量下载任务
    struct BatchDownloadTask: Identifiable {
        let id: UUID
        let name: String
        var taskItems: [BatchTaskItem]
        let createdAt: Date
        var state: BatchState
        var failedItems: [BatchFailedItem]

        init(
            id: UUID = UUID(),
            name: String,
            taskItems: [BatchTaskItem],
            createdAt: Date = Date(),
            state: BatchState = .pending,
            failedItems: [BatchFailedItem] = []
        ) {
            self.id = id
            self.name = name
            self.taskItems = taskItems
            self.createdAt = createdAt
            self.state = state
            self.failedItems = failedItems
        }
    }

    /// 批量任务项
    struct BatchTaskItem {
        let task: any DownloadTask
        let url: String
        let fileName: String

        init(task: any DownloadTask) {
            self.task = task
            self.url = task.url
            self.fileName = task.fileName
        }
    }

    /// 批量任务状态
    enum BatchState: String, Codable {
        case pending = "Pending"
        case downloading = "Downloading"
        case paused = "Paused"
        case completed = "Completed"
        case failed = "Failed"
        case partiallyFailed = "Partially Failed"
        case cancelled = "Cancelled"

        var displayText: String {
            switch self {
            case .pending: return "等待中"
            case .downloading: return "下载中"
            case .paused: return "已暂停"
            case .completed: return "已完成"
            case .failed: return "失败"
            case .partiallyFailed: return "部分失败"
            case .cancelled: return "已取消"
            }
        }
    }

    /// 创建批量下载任务
    func createBatchDownload(
        name: String,
        urls: [String],
        fileNames: [String]? = nil,
        configuration: DownloadConfiguration = .default
    ) async -> BatchDownloadResult {

        AppLogger.info("Creating batch download: \(name) with \(urls.count) URLs")
        AppLogger.info("开始创建批量任务，URLs: \(urls)")

        var taskItems: [BatchTaskItem] = []
        var failedItems: [BatchFailedItem] = []

        // 创建下载任务
        for (index, url) in urls.enumerated() {
            AppLogger.info("处理URL \(index + 1)/\(urls.count): \(url)")
            let fileName = fileNames?[index] ?? "video_\(index + 1).\(getFileExtension(from: url))"

            do {
                let task = try await VideoDownloadEngine.shared.createDownloadTask(
                    url: url,
                    fileName: fileName,
                    configuration: configuration
                )
                AppLogger.info("任务创建成功: \(fileName)")
                taskItems.append(BatchTaskItem(task: task))
            } catch {
                AppLogger.error("任务创建失败: \(error)，记录失败项并继续")
                let failedItem = BatchFailedItem(url: url, fileName: fileName, error: error)
                failedItems.append(failedItem)
            }
        }

        // 确定批量任务状态
        let state: BatchState
        if taskItems.isEmpty {
            state = .failed
        } else if !failedItems.isEmpty {
            state = .partiallyFailed
        } else {
            state = .pending
        }

        // 创建批量任务
        var batchTask = BatchDownloadTask(name: name, taskItems: taskItems, failedItems: failedItems)
        batchTask.state = state
        batchTasks[batchTask.id] = batchTask
        observeTaskStates(for: batchTask)
        persistBatchTask(batchTask)
        AppLogger.info("批量任务创建完成，ID: \(batchTask.id)，成功: \(taskItems.count)，失败: \(failedItems.count)")

        return BatchDownloadResult(batchTask: batchTask, failedCount: failedItems.count, hasFailures: !failedItems.isEmpty)
    }

    /// 开始批量下载
    func startBatchDownload(batchId: UUID) async throws {
        guard let batchTask = batchTasks[batchId] else {
            throw BatchDownloadError.invalidBatchId
        }

        AppLogger.info("Starting batch download: \(batchTask.name)")
        batchTasks[batchId]?.state = .downloading
        persistBatchTaskIfPresent(batchId: batchId)

        // 任务已在 Engine 的 queueManager 中，只需确保状态正确
        for item in batchTask.taskItems {
            if let liveTask = await VideoDownloadEngine.shared.getTask(by: item.task.id) {
                try? await VideoDownloadEngine.shared.startDownload(task: liveTask)
            }
        }
    }

    /// 暂停批量下载
    func pauseBatchDownload(batchId: UUID) async {
        guard let batchTask = batchTasks[batchId] else {
            return
        }

        AppLogger.info("Pausing batch download: \(batchTask.name)")
        batchTasks[batchId]?.state = .paused
        persistBatchTaskIfPresent(batchId: batchId)

        // 暂停所有任务
        for item in batchTask.taskItems {
            if let liveTask = await VideoDownloadEngine.shared.getTask(by: item.task.id) {
                await VideoDownloadEngine.shared.pauseDownload(task: liveTask)
            } else {
                await item.task.pause()
            }
        }
    }

    /// 取消批量下载
    func cancelBatchDownload(batchId: UUID) async {
        guard let batchTask = batchTasks[batchId] else {
            return
        }

        AppLogger.info("Cancelling batch download: \(batchTask.name)")
        batchTasks[batchId]?.state = .cancelled
        persistBatchTaskIfPresent(batchId: batchId)

        // 取消所有任务并从队列中移除
        for item in batchTask.taskItems {
            if let liveTask = await VideoDownloadEngine.shared.getTask(by: item.task.id) {
                await VideoDownloadEngine.shared.cancelDownload(task: liveTask)
            } else {
                await item.task.cancel()
            }
        }
    }

    /// 删除批量下载
    func deleteBatchDownload(batchId: UUID) async {
        guard let batchTask = batchTasks[batchId] else {
            return
        }

        AppLogger.info("Deleting batch download: \(batchTask.name)")

        // 删除所有任务（包括已完成文件的清理）
        for item in batchTask.taskItems {
            await VideoDownloadEngine.shared.deleteDownloadTask(task: item.task)
        }

        batchTasks.removeValue(forKey: batchId)
        detachBatchTask(batchId: batchId)
        deletePersistedBatchTask(batchId: batchId)
    }

    /// 获取所有批量任务
    func getAllBatchTasks() async -> [BatchDownloadTask] {
        return Array(batchTasks.values)
    }

    /// 获取指定批量任务
    func getBatchTask(by batchId: UUID) -> BatchDownloadTask? {
        return batchTasks[batchId]
    }

    /// 根据子任务状态重新推导并持久化批量任务状态。
    @discardableResult
    func recomputeBatchState(batchId: UUID) async -> BatchState? {
        guard var batchTask = batchTasks[batchId] else {
            return nil
        }

        var taskStates: [DownloadState] = []
        for item in batchTask.taskItems {
            if let liveTask = await VideoDownloadEngine.shared.getTask(by: item.task.id) {
                taskStates.append(liveTask.state.value)
            } else {
                taskStates.append(item.task.state.value)
            }
        }

        let newState = Self.inferredState(
            taskStates: taskStates,
            failedItemCount: batchTask.failedItems.count,
            persistedState: batchTask.state
        )

        if newState != batchTask.state {
            batchTask.state = newState
            batchTasks[batchId] = batchTask
            persistBatchTask(batchTask)
            AppLogger.info("Batch state recomputed: \(batchId) -> \(newState.displayText)")
        }

        return newState
    }

    static func inferredState(
        taskStates: [DownloadState],
        failedItemCount: Int,
        persistedState: BatchState
    ) -> BatchState {
        if persistedState == .cancelled {
            return .cancelled
        }

        if taskStates.isEmpty {
            return failedItemCount > 0 ? .failed : persistedState
        }

        if taskStates.allSatisfy({ $0 == .completed }) {
            return failedItemCount == 0 ? .completed : .partiallyFailed
        }

        if taskStates.contains(.downloading) {
            return .downloading
        }

        let hasRuntimeFailure = taskStates.contains(.failed)
        if hasRuntimeFailure || failedItemCount > 0 {
            let allRuntimeFailed = taskStates.allSatisfy { $0 == .failed }
            return allRuntimeFailed ? .failed : .partiallyFailed
        }

        if taskStates.contains(.paused) {
            return .paused
        }

        if taskStates.contains(.pending) {
            return .pending
        }

        return persistedState
    }

    /// 获取批量任务的进度
    func getBatchProgress(batchId: UUID) async -> (
        total: Int,
        completed: Int,
        downloading: Int,
        paused: Int,
        failed: Int,
        failedInCreation: Int
    )? {
        guard let batchTask = batchTasks[batchId] else {
            return nil
        }

        var completed = 0
        var downloading = 0
        var paused = 0
        var failed = 0

        for item in batchTask.taskItems {
            let task = await VideoDownloadEngine.shared.getTask(by: item.task.id)
            let state = task?.state.value ?? item.task.state.value

            switch state {
            case .completed:
                completed += 1
            case .downloading:
                downloading += 1
            case .paused:
                paused += 1
            case .failed:
                failed += 1
            case .cancelled, .pending:
                break
            }
        }

        let total = batchTask.taskItems.count + batchTask.failedItems.count
        let failedInCreation = batchTask.failedItems.count

        return (
            total: total,
            completed: completed,
            downloading: downloading,
            paused: paused,
            failed: failed,
            failedInCreation: failedInCreation
        )
    }

    /// 获取批量任务（用于同步检查）
    /*nonisolated*/ func getBatchTaskForSync(batchId: UUID) -> BatchDownloadTask? {
        return batchTasks[batchId]
    }

    /// 重试批量任务中的失败项
    func retryFailedItems(batchId: UUID) async -> BatchDownloadResult? {
        guard var batchTask = batchTasks[batchId] else {
            return nil
        }

        let failedItemsToRetry = batchTask.failedItems
        guard !failedItemsToRetry.isEmpty else {
            return nil
        }

        AppLogger.info("Retrying \(failedItemsToRetry.count) failed items for batch: \(batchTask.name)")

        var newTaskItems: [BatchTaskItem] = []
        var stillFailedItems: [BatchFailedItem] = []

        for failedItem in failedItemsToRetry {
            do {
                let task = try await VideoDownloadEngine.shared.createDownloadTask(
                    url: failedItem.url,
                    fileName: failedItem.fileName,
                    configuration: .default
                )
                newTaskItems.append(BatchTaskItem(task: task))
            } catch {
                let newFailedItem = BatchFailedItem(
                    url: failedItem.url,
                    fileName: failedItem.fileName,
                    error: error
                )
                stillFailedItems.append(newFailedItem)
            }
        }

        // 合并新成功的任务到现有任务列表
        let allTaskItems = batchTask.taskItems + newTaskItems

        // 更新批量任务
        batchTask.taskItems = allTaskItems
        batchTask.failedItems = stillFailedItems

        // 重新计算状态
        if allTaskItems.isEmpty {
            batchTask.state = .failed
        } else if !stillFailedItems.isEmpty {
            batchTask.state = .partiallyFailed
        } else {
            batchTask.state = .pending
        }

        batchTasks[batchId] = batchTask
        observeTaskStates(for: batchTask)
        persistBatchTask(batchTask)

        // 自动启动新添加的任务
        if !newTaskItems.isEmpty {
            for item in newTaskItems {
                try? await VideoDownloadEngine.shared.startDownload(task: item.task)
            }
            if batchTask.state == .pending {
                batchTasks[batchId]?.state = .downloading
                persistBatchTaskIfPresent(batchId: batchId)
            }
        }

        return BatchDownloadResult(
            batchTask: batchTask,
            failedCount: stillFailedItems.count,
            hasFailures: !stillFailedItems.isEmpty
        )
    }

    /// 清空所有批量下载
    func clearAllBatchDownloads() async {
        let batchIds = Array(batchTasks.keys)
        for batchId in batchIds {
            await deleteBatchDownload(batchId: batchId)
        }

        AppLogger.info("All batch downloads cleared")
    }

    /// 仅清空批量分组元数据，不删除子下载任务。
    func clearBatchMetadata() {
        batchTasks.removeAll()
        clearTaskStateObservers()
        do {
            try VideoDownloadEngine.shared.database.deleteAllBatchRecords()
        } catch {
            AppLogger.error("Failed to clear batch metadata: \(error)")
        }
    }

    /// 从数据库恢复批量下载分组。
    func restoreBatchDownloads() async {
        do {
            let records = try VideoDownloadEngine.shared.database.loadAllBatchRecords()
            var restoredTasks: [UUID: BatchDownloadTask] = [:]
            clearTaskStateObservers()

            for record in records {
                var taskItems: [BatchTaskItem] = []

                for taskId in record.taskIds {
                    if let liveTask = await VideoDownloadEngine.shared.getTask(by: taskId) {
                        taskItems.append(BatchTaskItem(task: liveTask))
                        continue
                    }

                    guard let taskRecord = try VideoDownloadEngine.shared.database.loadRecord(byId: taskId) else {
                        continue
                    }

                    let persistedTask = PersistedBatchDownloadTask(record: taskRecord)
                    taskItems.append(BatchTaskItem(task: persistedTask))
                }

                let failedItems = record.failedItems.map(BatchFailedItem.init(record:))
                let persistedState = BatchState(rawValue: record.state) ?? .pending
                var batchTask = BatchDownloadTask(
                    id: record.id,
                    name: record.name,
                    taskItems: taskItems,
                    createdAt: record.createdAt,
                    state: persistedState,
                    failedItems: failedItems
                )
                batchTask.state = recomputeState(for: batchTask, persistedState: persistedState)
                restoredTasks[batchTask.id] = batchTask
                observeTaskStates(for: batchTask)

                if batchTask.state != persistedState || taskItems.count != record.taskIds.count {
                    persistBatchTask(batchTask)
                }
            }

            batchTasks = restoredTasks
            AppLogger.info("Restored \(restoredTasks.count) batch download groups")
        } catch {
            AppLogger.error("Failed to restore batch downloads: \(error)")
        }
    }

    // MARK: - Private Methods

    /// 从URL获取文件扩展名
    private func getFileExtension(from url: String) -> String {
        if let format = VideoFormatDetector.detectFromURLString(url) {
            return format.fileExtension
        }
        return "mp4"
    }

    private func persistBatchTaskIfPresent(batchId: UUID) {
        guard let batchTask = batchTasks[batchId] else {
            return
        }
        persistBatchTask(batchTask)
    }

    private func persistBatchTask(_ batchTask: BatchDownloadTask) {
        let failedItemRecords = batchTask.failedItems.map {
            BatchDownloadFailedItemRecord(
                id: $0.id,
                url: $0.url,
                fileName: $0.fileName,
                errorDescription: $0.errorDescription,
                failedAt: $0.failedAt
            )
        }

        let record = BatchDownloadRecord(
            id: batchTask.id,
            name: batchTask.name,
            createdAt: batchTask.createdAt,
            state: batchTask.state.rawValue,
            taskIds: batchTask.taskItems.map { $0.task.id },
            failedItems: failedItemRecords
        )

        do {
            try VideoDownloadEngine.shared.database.saveBatchRecord(record)
        } catch {
            AppLogger.error("Failed to persist batch task \(batchTask.id): \(error)")
        }
    }

    private func deletePersistedBatchTask(batchId: UUID) {
        do {
            try VideoDownloadEngine.shared.database.deleteBatchRecord(byId: batchId)
        } catch {
            AppLogger.error("Failed to delete persisted batch task \(batchId): \(error)")
        }
    }

    private func recomputeState(for batchTask: BatchDownloadTask, persistedState: BatchState) -> BatchState {
        return Self.inferredState(
            taskStates: batchTask.taskItems.map { $0.task.state.value },
            failedItemCount: batchTask.failedItems.count,
            persistedState: persistedState
        )
    }

    private func observeTaskStates(for batchTask: BatchDownloadTask) {
        for item in batchTask.taskItems {
            let taskId = item.task.id
            taskBatchIds[taskId, default: []].insert(batchTask.id)

            guard taskStateCancellables[taskId] == nil else {
                continue
            }

            taskStateCancellables[taskId] = item.task.state
                .dropFirst()
                .sink { [weak self] _ in
                    Task {
                        await self?.recomputeBatchStateForTask(taskId: taskId)
                    }
                }
        }
    }

    private func recomputeBatchStateForTask(taskId: UUID) async {
        let batchIds = taskBatchIds[taskId] ?? []
        for batchId in batchIds {
            await recomputeBatchState(batchId: batchId)
        }
    }

    private func detachBatchTask(batchId: UUID) {
        for (taskId, batchIds) in taskBatchIds {
            var updatedBatchIds = batchIds
            updatedBatchIds.remove(batchId)
            if updatedBatchIds.isEmpty {
                taskBatchIds.removeValue(forKey: taskId)
                taskStateCancellables[taskId]?.cancel()
                taskStateCancellables.removeValue(forKey: taskId)
            } else {
                taskBatchIds[taskId] = updatedBatchIds
            }
        }
    }

    private func clearTaskStateObservers() {
        taskStateCancellables.values.forEach { $0.cancel() }
        taskStateCancellables.removeAll()
        taskBatchIds.removeAll()
    }
}

private final class PersistedBatchDownloadTask: DownloadTask {
    let id: UUID
    let url: String
    let fileName: String
    let format: VideoFormat
    let totalSize: Int64?
    var downloadedSize: Int64
    let createdAt: Date
    var completedAt: Date?
    var resumeData: Data?
    var lastError: Error?
    let configuration: DownloadConfiguration
    let state: CurrentValueSubject<DownloadState, Never>
    let progress: CurrentValueSubject<DownloadProgress, Never>
    let completedURL: URL?
    var pauseReason: PauseReason?
    var priority: DownloadPriority = .normal

    init(record: DownloadTaskRecord) {
        self.id = record.id
        self.url = record.url
        self.fileName = record.fileName
        self.format = VideoFormat(rawValue: record.format) ?? .mp4
        self.totalSize = record.totalSize
        self.downloadedSize = record.downloadedSize
        self.createdAt = record.createdAt
        self.completedAt = record.completedAt
        self.resumeData = record.resumeData
        self.configuration = .default

        let restoredState = DownloadState(rawValue: record.state) ?? .pending
        self.state = CurrentValueSubject<DownloadState, Never>(restoredState)
        self.progress = CurrentValueSubject<DownloadProgress, Never>(DownloadProgress(
            taskId: record.id,
            totalBytes: record.totalSize ?? 0,
            downloadedBytes: record.downloadedSize,
            progress: record.progress,
            speed: 0,
            remainingTime: 0
        ))
        self.completedURL = restoredState == .completed ? record.toDownloadItem().fileURL : nil
    }

    func resume() async throws {
        throw BatchDownloadError.restoredTaskUnavailable
    }

    func retry() async throws {
        throw BatchDownloadError.restoredTaskUnavailable
    }

    func pause() async {
        state.send(.paused)
    }

    func pause(reason: PauseReason) async {
        pauseReason = reason
        state.send(.paused)
    }

    func cancel() async {
        state.send(.cancelled)
    }
}

/// 批量下载错误
enum BatchDownloadError: Error {
    case invalidBatchId
    case noTasksInBatch
    case restoredTaskUnavailable
}
