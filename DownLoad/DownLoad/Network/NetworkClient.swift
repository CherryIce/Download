//
//  NetworkClient.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation

// MARK: - 可取消的下载任务句柄（支持暂停时获取 resumeData）

/// 可取消的下载任务句柄，支持暂停时通过 cancel(byProducingResumeData:) 获取 resumeData
class ResumableDownloadHandle {
    private let urlSessionTask: URLSessionDownloadTask
    private var _resumeData: Data?

    init(urlSessionTask: URLSessionDownloadTask) {
        self.urlSessionTask = urlSessionTask
    }

    /// 暂停下载并保存 resumeData，供下次恢复使用
    func cancelWithResumeData() async -> Data? {
        await withCheckedContinuation { continuation in
            self.urlSessionTask.cancel(byProducingResumeData: { data in
                self._resumeData = data
                continuation.resume(returning: data)
            })
        }
    }

    /// 最近一次暂停保存的 resumeData
    var resumeData: Data? { _resumeData }
}

// MARK: - Download Delegate（内部辅助类，用于接收 URLSession 下载进度回调）

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progressHandler: (Int64, Int64) -> Void
    var completionHandler: ((Result<URL, Error>) -> Void)?
    var resumeDataHandler: ((Data?) -> Void)?

    init(progress: @escaping (Int64, Int64) -> Void) {
        self.progressHandler = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progressHandler(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        completionHandler?(.success(location))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            // 提取 resumeData（如果有的话）
            let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            resumeDataHandler?(resumeData)
            completionHandler?(.failure(error))
        }
    }
}

/// 网络客户端
actor NetworkClient {

    private let session: URLSession
    private let retryCount: Int
    private let customHeaders: [String: String]

    init(configuration: DownloadConfiguration = .default) {
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeoutInterval
        sessionConfiguration.timeoutIntervalForResource = configuration.timeoutInterval * 2
        sessionConfiguration.httpMaximumConnectionsPerHost = configuration.maxConcurrentDownloads

        self.session = URLSession(configuration: sessionConfiguration)
        self.retryCount = configuration.retryCount
        self.customHeaders = configuration.customHeaders
    }

    /// 创建带有自定义请求头的 URLRequest
    private func makeRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        for (key, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    /// 下载字符串内容
    func downloadString(from url: URL) async throws -> String {
        var lastError: Error?

        for attempt in 0..<retryCount {
            do {
                let request = makeRequest(for: url)
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NetworkError.invalidResponse
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    throw NetworkError.httpError(statusCode: httpResponse.statusCode)
                }

                guard let string = String(data: data, encoding: .utf8) else {
                    throw NetworkError.noData
                }

                return string
            } catch {
                lastError = error
                Logger.error("Download string attempt \(attempt + 1) failed: \(error.localizedDescription)")

                if attempt < retryCount - 1 {
                    let delay = pow(2.0, Double(attempt))
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        throw lastError ?? NetworkError.connectionError(NSError(domain: "NetworkClient", code: -1))
    }

    /// 下载数据
    func downloadData(from url: URL) async throws -> Data {
        var lastError: Error?

        for attempt in 0..<retryCount {
            do {
                let request = makeRequest(for: url)
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NetworkError.invalidResponse
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    throw NetworkError.httpError(statusCode: httpResponse.statusCode)
                }

                return data
            } catch {
                lastError = error
                Logger.error("Download data attempt \(attempt + 1) failed: \(error.localizedDescription)")

                if attempt < retryCount - 1 {
                    let delay = pow(2.0, Double(attempt))
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        throw lastError ?? NetworkError.connectionError(NSError(domain: "NetworkClient", code: -1))
    }

    /// 下载文件（带实时进度回调）
    func downloadFile(
        from url: URL,
        to destinationURL: URL,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(progress: progress)
            let downloadSession = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)

            delegate.completionHandler = { result in
                switch result {
                case .success(let tempURL):
                    do {
                        let dir = destinationURL.deletingLastPathComponent()
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        if FileManager.default.fileExists(atPath: destinationURL.path) {
                            try FileManager.default.removeItem(at: destinationURL)
                        }
                        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                        let size = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0
                        progress(size, size)
                        continuation.resume(returning: destinationURL)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            let request = makeRequest(for: url)
            let task = downloadSession.downloadTask(with: request)
            task.resume()
        }
    }

    /// 下载文件（支持断点续传，带实时进度回调）
    /// - Returns: 成功时返回 destinationURL；失败时抛出 NetworkError.resumeError，其中包含 resumeData
    func downloadFileWithResume(
        from url: URL,
        to destinationURL: URL,
        resumeData: Data? = nil,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(progress: progress)
            let downloadSession = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)

            var savedResumeData: Data?

            delegate.resumeDataHandler = { data in
                savedResumeData = data
            }

            delegate.completionHandler = { result in
                switch result {
                case .success(let tempURL):
                    do {
                        let dir = destinationURL.deletingLastPathComponent()
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        if FileManager.default.fileExists(atPath: destinationURL.path) {
                            try FileManager.default.removeItem(at: destinationURL)
                        }
                        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                        let size = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0
                        progress(size, size)
                        continuation.resume(returning: destinationURL)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                case .failure(let error):
                    let wrappedError = NetworkError.resumeError(
                        underlying: error,
                        resumeData: savedResumeData
                    )
                    continuation.resume(throwing: wrappedError)
                }
            }

            let downloadTask: URLSessionDownloadTask
            if let resumeData = resumeData {
                downloadTask = downloadSession.downloadTask(withResumeData: resumeData)
            } else {
                let request = makeRequest(for: url)
                downloadTask = downloadSession.downloadTask(with: request)
            }
            downloadTask.resume()
        }
    }

    /// 获取远程文件大小（通过 HEAD 请求读取 Content-Length）
    func fetchRemoteFileSize(from url: URL) async throws -> Int64 {
        var request = makeRequest(for: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.httpError(statusCode: httpResponse.statusCode)
        }
        let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length")
        return Int64(contentLength ?? "") ?? 0
    }

    /// 下载文件（支持断点续传 + 可取消句柄，用于 MP4DownloadTask 暂停/恢复场景）
    func downloadFileWithResumeCancellable(
        from url: URL,
        to destinationURL: URL,
        resumeData: Data? = nil,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws -> (URL, ResumableDownloadHandle) {
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(progress: progress)
            let downloadSession = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)

            let downloadTask: URLSessionDownloadTask
            if let resumeData = resumeData {
                downloadTask = downloadSession.downloadTask(withResumeData: resumeData)
            } else {
                let request = makeRequest(for: url)
                downloadTask = downloadSession.downloadTask(with: request)
            }

            let handle = ResumableDownloadHandle(urlSessionTask: downloadTask)

            delegate.completionHandler = { result in
                switch result {
                case .success(let tempURL):
                    do {
                        let dir = destinationURL.deletingLastPathComponent()
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        if FileManager.default.fileExists(atPath: destinationURL.path) {
                            try FileManager.default.removeItem(at: destinationURL)
                        }
                        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                        let size = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0
                        progress(size, size)
                        continuation.resume(returning: (destinationURL, handle))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            downloadTask.resume()
        }
    }
}
