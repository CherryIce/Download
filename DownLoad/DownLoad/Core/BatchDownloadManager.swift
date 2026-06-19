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

        init(id: UUID = UUID(), name: String, taskItems: [BatchTaskItem], failedItems: [BatchFailedItem] = []) {
            self.id = id
            self.name = name
            self.taskItems = taskItems
            self.createdAt = Date()
            self.state = .pending
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
    enum BatchState {
        case pending
        case downloading
        case paused
        case completed
        case failed
        case partiallyFailed
        case cancelled

        var rawValue: String {
            switch self {
            case .pending: return "Pending"
            case .downloading: return "Downloading"
            case .paused: return "Paused"
            case .completed: return "Completed"
            case .failed: return "Failed"
            case .partiallyFailed: return "Partially Failed"
            case .cancelled: return "Cancelled"
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

        Logger.info("Creating batch download: \(name) with \(urls.count) URLs")
        print("🔥 BatchDownloadManager: 开始创建批量任务，URLs: \(urls)")

        var taskItems: [BatchTaskItem] = []
        var failedItems: [BatchFailedItem] = []

        // 创建下载任务
        for (index, url) in urls.enumerated() {
            print("🔥 处理URL \(index + 1)/\(urls.count): \(url)")
            let fileName = fileNames?[index] ?? "video_\(index + 1).\(getFileExtension(from: url))"

            do {
                let task = try await VideoDownloadEngine.shared.createDownloadTask(
                    url: url,
                    fileName: fileName,
                    configuration: configuration
                )
                print("✅ 任务创建成功: \(fileName)")
                taskItems.append(BatchTaskItem(task: task))
            } catch {
                print("❌ 任务创建失败: \(error)，记录失败项并继续")
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
        print("✅ 批量任务创建完成，ID: \(batchTask.id)，成功: \(taskItems.count)，失败: \(failedItems.count)")

        return BatchDownloadResult(batchTask: batchTask, failedCount: failedItems.count, hasFailures: !failedItems.isEmpty)
    }

    /// 开始批量下载
    func startBatchDownload(batchId: UUID) async throws {
        guard let batchTask = batchTasks[batchId] else {
            throw BatchDownloadError.invalidBatchId
        }

        Logger.info("Starting batch download: \(batchTask.name)")
        batchTasks[batchId]?.state = .downloading

        // 任务已在 Engine 的 queueManager 中，只需确保状态正确
        for item in batchTask.taskItems {
            if await VideoDownloadEngine.shared.getTask(by: item.task.id) == nil {
                try? await VideoDownloadEngine.shared.startDownload(task: item.task)
            }
        }
    }

    /// 暂停批量下载
    func pauseBatchDownload(batchId: UUID) async {
        guard let batchTask = batchTasks[batchId] else {
            return
        }

        Logger.info("Pausing batch download: \(batchTask.name)")
        batchTasks[batchId]?.state = .paused

        // 暂停所有任务
        for item in batchTask.taskItems {
            await VideoDownloadEngine.shared.pauseDownload(task: item.task)
        }
    }

    /// 取消批量下载
    func cancelBatchDownload(batchId: UUID) async {
        guard let batchTask = batchTasks[batchId] else {
            return
        }

        Logger.info("Cancelling batch download: \(batchTask.name)")
        batchTasks[batchId]?.state = .cancelled

        // 取消所有任务并从队列中移除
        for item in batchTask.taskItems {
            await VideoDownloadEngine.shared.cancelDownload(task: item.task)
        }
    }

    /// 删除批量下载
    func deleteBatchDownload(batchId: UUID) async {
        guard let batchTask = batchTasks[batchId] else {
            return
        }

        Logger.info("Deleting batch download: \(batchTask.name)")

        // 删除所有任务（包括已完成文件的清理）
        for item in batchTask.taskItems {
            await VideoDownloadEngine.shared.deleteDownloadTask(task: item.task)
        }

        batchTasks.removeValue(forKey: batchId)
    }

    /// 获取所有批量任务
    func getAllBatchTasks() async -> [BatchDownloadTask] {
        return Array(batchTasks.values)
    }

    /// 获取指定批量任务
    func getBatchTask(by batchId: UUID) -> BatchDownloadTask? {
        return batchTasks[batchId]
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

        Logger.info("Retrying \(failedItemsToRetry.count) failed items for batch: \(batchTask.name)")

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

        // 自动启动新添加的任务
        if !newTaskItems.isEmpty {
            for item in newTaskItems {
                try? await VideoDownloadEngine.shared.startDownload(task: item.task)
            }
            if batchTask.state == .pending {
                batchTasks[batchId]?.state = .downloading
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

        Logger.info("All batch downloads cleared")
    }

    // MARK: - Private Methods

    /// 从URL获取文件扩展名
    private func getFileExtension(from url: String) -> String {
        if let format = VideoFormatDetector.detectFromURLString(url) {
            return format.fileExtension
        }
        return "mp4"
    }
}

/// 批量下载错误
enum BatchDownloadError: Error {
    case invalidBatchId
    case noTasksInBatch
}
