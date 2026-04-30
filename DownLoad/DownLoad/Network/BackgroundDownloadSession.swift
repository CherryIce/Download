//
//  BackgroundDownloadSession.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation

/// 后台下载会话管理器
class BackgroundDownloadSession: NSObject {

    static let shared = BackgroundDownloadSession()

    private var session: URLSession!
    private var completionHandler: (() -> Void)?
    private var downloadTasks: [URLSessionDownloadTask: UUID] = [:]
    private var taskProgressHandlers: [UUID: (Int64, Int64) -> Void] = [:]
    private var taskCompletionHandlers: [UUID: (Result<URL, Error>) -> Void] = [:]

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

    /// 创建后台下载任务
    func createDownloadTask(
        url: URL,
        taskId: UUID,
        progress: @escaping (Int64, Int64) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) -> URLSessionDownloadTask {

        let task = session.downloadTask(with: url)
        downloadTasks[task] = taskId
        taskProgressHandlers[taskId] = progress
        taskCompletionHandlers[taskId] = completion

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
        downloadTasks[task] = taskId
        taskProgressHandlers[taskId] = progress
        taskCompletionHandlers[taskId] = completion

        return task
    }

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
}

// MARK: - URLSessionDownloadDelegate

extension BackgroundDownloadSession: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let taskId = downloadTasks[downloadTask] else { return }

        // 移动文件到Documents目录
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationURL = documentsPath.appendingPathComponent("Temp_\(taskId.uuidString).tmp")

        do {
            try FileManager.default.moveItem(at: location, to: destinationURL)
            taskCompletionHandlers[taskId]?(.success(destinationURL))
        } catch {
            taskCompletionHandlers[taskId]?(.failure(error))
        }

        // 清理
        downloadTasks.removeValue(forKey: downloadTask)
        taskProgressHandlers.removeValue(forKey: taskId)
        taskCompletionHandlers.removeValue(forKey: taskId)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let taskId = downloadTasks[downloadTask] else { return }
        taskProgressHandlers[taskId]?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let downloadTask = task as? URLSessionDownloadTask,
              let taskId = downloadTasks[downloadTask] else { return }

        if let error = error {
            taskCompletionHandlers[taskId]?(.failure(error))
        }

        // 清理
        downloadTasks.removeValue(forKey: downloadTask)
        taskProgressHandlers.removeValue(forKey: taskId)
        taskCompletionHandlers.removeValue(forKey: taskId)
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
