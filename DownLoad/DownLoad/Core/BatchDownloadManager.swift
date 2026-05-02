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
    private let queueManager = DownloadQueueManager()

    private init() {}

    /// 批量下载任务
    struct BatchDownloadTask: Identifiable {
        let id: UUID
        let name: String
        let taskItems: [BatchTaskItem]
        let createdAt: Date
        var state: BatchState

        init(id: UUID = UUID(), name: String, taskItems: [BatchTaskItem]) {
            self.id = id
            self.name = name
            self.taskItems = taskItems
            self.createdAt = Date()
            self.state = .pending
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
        case cancelled

        var rawValue: String {
            switch self {
            case .pending: return "Pending"
            case .downloading: return "Downloading"
            case .paused: return "Paused"
            case .completed: return "Completed"
            case .failed: return "Failed"
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
    ) async throws -> BatchDownloadTask {

        Logger.info("Creating batch download: \(name) with \(urls.count) URLs")
        print("🔥 BatchDownloadManager: 开始创建批量任务，URLs: \(urls)")

        var taskItems: [BatchTaskItem] = []
        var tasks: [any DownloadTask] = []

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
                tasks.append(task)
                taskItems.append(BatchTaskItem(task: task))
            } catch {
                print("❌ 任务创建失败: \(error)")
                throw error
            }
        }

        // 创建批量任务
        let batchTask = BatchDownloadTask(name: name, taskItems: taskItems)
        batchTasks[batchTask.id] = batchTask
        print("✅ 批量任务创建完成，ID: \(batchTask.id)")

        return batchTask
    }

    /// 开始批量下载
    func startBatchDownload(batchId: UUID) async throws {
        guard let batchTask = batchTasks[batchId] else {
            throw BatchDownloadError.invalidBatchId
        }

        Logger.info("Starting batch download: \(batchTask.name)")
        batchTasks[batchId]?.state = .downloading

        // 开始所有任务
        for item in batchTask.taskItems {
            do {
                try await VideoDownloadEngine.shared.startDownload(task: item.task)
            } catch {
                Logger.error("Failed to start task \(item.fileName): \(error)")
                // 标记任务失败但不停止整个批次
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

        // 取消并删除任务
        for item in batchTask.taskItems {
            await VideoDownloadEngine.shared.cancelDownload(task: item.task)
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
    func getBatchProgress(batchId: UUID) -> (total: Int, completed: Int, downloading: Int, paused: Int, failed: Int)? {
        guard let batchTask = batchTasks[batchId] else {
            return nil
        }

        var completed = 0
        var downloading = 0
        var paused = 0
        var failed = 0

        for item in batchTask.taskItems {
            switch item.task.state.value {
            case .completed:
                completed += 1
            case .downloading:
                downloading += 1
            case .paused:
                paused += 1
            case .failed:
                failed += 1
            case .cancelled:
                break
            default:
                break
            }
        }

        return (total: batchTask.taskItems.count, completed: completed, downloading: downloading, paused: paused, failed: failed)
    }

    /// 获取批量任务（用于同步检查）
    /*nonisolated*/ func getBatchTaskForSync(batchId: UUID) -> BatchDownloadTask? {
        return batchTasks[batchId]
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
        let components = url.components(separatedBy: ".")
        guard components.count > 1 else { return "mp4" }
        return components.last?.lowercased() ?? "mp4"
    }
}

/// 批量下载错误
enum BatchDownloadError: Error {
    case invalidBatchId
    case noTasksInBatch
}
