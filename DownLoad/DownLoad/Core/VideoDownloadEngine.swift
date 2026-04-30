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

        // 2. 创建对应的Handler
        let handler = try createHandler(for: format)

        // 3. 创建下载任务
        let task = try await handler.createTask(
            url: url,
            fileName: fileName,
            configuration: configuration
        )

        // 4. 添加到队列
        await queueManager.addTask(task)

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
