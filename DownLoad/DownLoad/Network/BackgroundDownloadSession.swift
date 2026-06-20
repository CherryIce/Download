//
//  BackgroundDownloadSession.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation

/// 后台下载会话管理器
/// 使用串行队列保护字典访问的线程安全
class BackgroundDownloadSession: NSObject {

    static let shared = BackgroundDownloadSession()

    private var session: URLSession!
    private var completionHandler: (() -> Void)?

    // 线程安全：所有字典操作通过 syncQueue 串行化
    private let syncQueue = DispatchQueue(label: "com.video.downloader.background.sync")
    private var downloadTasks: [URLSessionDownloadTask: UUID] = [:]
    private var taskProgressHandlers: [UUID: (Int64, Int64) -> Void] = [:]
    private var taskCompletionHandlers: [UUID: (Result<URL, Error>) -> Void] = [:]
    // 保存 taskId -> URL 映射，用于 App 重启后恢复
    private var taskURLMap: [UUID: String] = [:]

    private override init() {
        super.init()
        setupSession()
    }

    private func setupSession() {
        let config = URLSessionConfiguration.background(withIdentifier: "com.video.downloader.background")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 5

        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - 创建下载任务

    /// 创建后台下载任务（URL 方式）
    func createDownloadTask(
        url: URL,
        taskId: UUID,
        progress: @escaping (Int64, Int64) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) -> URLSessionDownloadTask {

        let request = URLRequest(url: url)
        return createDownloadTask(request: request, taskId: taskId, progress: progress, completion: completion)
    }

    /// 创建后台下载任务（URLRequest 方式，支持自定义请求头）
    func createDownloadTask(
        request: URLRequest,
        taskId: UUID,
        progress: @escaping (Int64, Int64) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) -> URLSessionDownloadTask {

        let task = session.downloadTask(with: request)
        syncQueue.sync {
            downloadTasks[task] = taskId
            taskProgressHandlers[taskId] = progress
            taskCompletionHandlers[taskId] = completion
            taskURLMap[taskId] = request.url?.absoluteString
        }

        return task
    }

    /// 创建带恢复数据的下载任务
    func createDownloadTask(
        resumeData: Data,
        taskId: UUID,
        progress: @escaping (Int64, Int64) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) -> URLSessionDownloadTask? {

        let task = session.downloadTask(withResumeData: resumeData)
        syncQueue.sync {
            downloadTasks[task] = taskId
            taskProgressHandlers[taskId] = progress
            taskCompletionHandlers[taskId] = completion
        }

        return task
    }

    /// 创建带恢复数据和自定义请求头的下载任务
    func createDownloadTask(
        resumeData: Data,
        request: URLRequest,
        taskId: UUID,
        progress: @escaping (Int64, Int64) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) -> URLSessionDownloadTask? {

        let task = session.downloadTask(withResumeData: resumeData)
        syncQueue.sync {
            downloadTasks[task] = taskId
            taskProgressHandlers[taskId] = progress
            taskCompletionHandlers[taskId] = completion
            taskURLMap[taskId] = request.url?.absoluteString
        }

        return task
    }

    // MARK: - 任务控制

    /// 取消任务并获取恢复数据
    func cancelTask(_ task: URLSessionDownloadTask, completion: @escaping (Data?) -> Void) {
        task.cancel { data in
            completion(data)
        }
    }

    /// 设置后台下载完成处理器
    func setCompletionHandler(_ handler: @escaping () -> Void) {
        self.completionHandler = handler
    }

    /// 获取所有任务
    func getAllTasks() async -> [URLSessionTask] {
        return await session.allTasks
    }

    // MARK: - App 重启后恢复

    /// 获取指定 taskId 对应的 URL
    func getURL(forTaskId taskId: UUID) -> String? {
        return syncQueue.sync {
            taskURLMap[taskId]
        }
    }

    /// 为已存在的后台任务重新注册回调（App 重启后使用）
    /// - Parameters:
    ///   - taskIdentifier: URLSessionDownloadTask 的 taskIdentifier
    ///   - taskId: 业务层任务 ID
    ///   - progress: 进度回调
    ///   - completion: 完成回调
    func registerHandler(
        for taskIdentifier: Int,
        taskId: UUID,
        progress: @escaping (Int64, Int64) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        syncQueue.sync {
            taskProgressHandlers[taskId] = progress
            taskCompletionHandlers[taskId] = completion
        }
        // 注意：downloadTasks 字典无法在重启后恢复（因为 URLSessionDownloadTask 对象已丢失）
        // delegate 中需要通过 taskIdentifier -> taskId 的反向映射来查找
        // 这里我们维护一个 taskIdentifier -> taskId 的映射
        syncQueue.sync {
            taskIdentifierMap[taskIdentifier] = taskId
        }
    }

    // taskIdentifier -> taskId 反向映射（用于 App 重启后恢复）
    private var taskIdentifierMap: [Int: UUID] = [:]
}

// MARK: - URLSessionDownloadDelegate

extension BackgroundDownloadSession: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskId: UUID? = syncQueue.sync {
            downloadTasks[downloadTask]
        }

        // 如果 downloadTasks 中找不到（App 重启后），尝试 taskIdentifierMap
        let resolvedTaskId: UUID? = taskId ?? syncQueue.sync {
            taskIdentifierMap[downloadTask.taskIdentifier]
        }

        guard let taskId = resolvedTaskId else {
            AppLogger.warning("BackgroundDownloadSession: didFinishDownloadingTo but no taskId found for task \(downloadTask.taskIdentifier)")
            return
        }

        // 直接返回系统临时路径，由调用方（MP4DownloadTask）负责文件移动
        let completion: ((Result<URL, Error>) -> Void)? = syncQueue.sync {
            taskCompletionHandlers[taskId]
        }
        completion?(.success(location))

        // 清理
        syncQueue.sync {
            downloadTasks.removeValue(forKey: downloadTask)
            taskProgressHandlers.removeValue(forKey: taskId)
            taskCompletionHandlers.removeValue(forKey: taskId)
            taskURLMap.removeValue(forKey: taskId)
            taskIdentifierMap.removeValue(forKey: downloadTask.taskIdentifier)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskId: UUID? = syncQueue.sync {
            downloadTasks[downloadTask]
        }

        let resolvedTaskId: UUID? = taskId ?? syncQueue.sync {
            taskIdentifierMap[downloadTask.taskIdentifier]
        }

        guard let taskId = resolvedTaskId else { return }

        let progress: ((Int64, Int64) -> Void)? = syncQueue.sync {
            taskProgressHandlers[taskId]
        }
        progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let downloadTask = task as? URLSessionDownloadTask else { return }

        let taskId: UUID? = syncQueue.sync {
            downloadTasks[downloadTask]
        }

        let resolvedTaskId: UUID? = taskId ?? syncQueue.sync {
            taskIdentifierMap[downloadTask.taskIdentifier]
        }

        guard let taskId = resolvedTaskId else { return }

        if let error = error {
            let completion: ((Result<URL, Error>) -> Void)? = syncQueue.sync {
                taskCompletionHandlers[taskId]
            }
            completion?(.failure(error))
        }

        // 清理
        syncQueue.sync {
            downloadTasks.removeValue(forKey: downloadTask)
            taskProgressHandlers.removeValue(forKey: taskId)
            taskCompletionHandlers.removeValue(forKey: taskId)
            taskURLMap.removeValue(forKey: taskId)
            taskIdentifierMap.removeValue(forKey: downloadTask.taskIdentifier)
        }
    }
}

// MARK: - URLSessionDelegate

extension BackgroundDownloadSession: URLSessionDelegate {

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.completionHandler?()
            self.completionHandler = nil
        }
    }
}
