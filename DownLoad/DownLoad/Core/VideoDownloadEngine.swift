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

    private var mp4Handler: MP4DownloadHandler!
    private var m3u8Handler: M3U8DownloadHandler!
    private var thunderHandler: ThunderDownloadHandler!

    private init() {
        self.queueManager = DownloadQueueManager()
        self.storageManager = FileStorageManager()
        self.networkClient = NetworkClient()

        // 初始化处理器
        self.mp4Handler = MP4DownloadHandler(
            networkClient: networkClient,
            storageManager: storageManager
        )

        self.m3u8Handler = M3U8DownloadHandler(
            networkClient: networkClient,
            storageManager: storageManager
        )

        self.thunderHandler = ThunderDownloadHandler(
            networkClient: networkClient,
            storageManager: storageManager
        )
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

        // 2. 创建对应的Handler
        let handler = try createHandler(for: format)
        print("✅ Handler创建成功: \(type(of: handler))")

        // 3. 创建下载任务
        let task = try await handler.createTask(
            url: url,
            fileName: fileName,
            configuration: configuration
        )
        print("✅ 下载任务创建成功: \(task.fileName ?? "未知文件名")")

        // 4. 添加到队列
        await queueManager.addTask(task)
        print("✅ 任务已添加到队列")

        return task
    }

    /// 开始下载
    func startDownload(task: any DownloadTask) async throws {
        Logger.info("Starting download: \(task.id)")
        try await task.resume()
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
    }

    /// 删除下载任务
    func deleteDownloadTask(task: any DownloadTask) async {
        Logger.info("Deleting download task: \(task.id)")

        // 如果任务未完成，先取消
        if task.state.value != .completed {
            await task.cancel()
        }

        // 从队列中移除任务
        await queueManager.removeTask(task.id)

        // 如果任务已完成，删除对应的文件
        if task.state.value == .completed, let completedURL = task.completedURL {
            try? storageManager.deleteFile(at: completedURL)
            Logger.info("Deleted completed file: \(completedURL.path)")
        }
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
    private func createHandler(for format: VideoFormat) throws -> any DownloadHandlerProtocol {
        switch format {
        case .mp4:
            return mp4Handler
        case .m3u8:
            return m3u8Handler
        case .thunder:
            return thunderHandler
        }
    }
}
