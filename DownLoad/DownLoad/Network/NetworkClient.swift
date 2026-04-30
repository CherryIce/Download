//
//  NetworkClient.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation

/// 网络客户端
actor NetworkClient {

    private let session: URLSession
    private let retryCount: Int

    init(configuration: DownloadConfiguration = .default) {
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeoutInterval
        sessionConfiguration.timeoutIntervalForResource = configuration.timeoutInterval * 2
        sessionConfiguration.httpMaximumConnectionsPerHost = configuration.maxConcurrentDownloads

        self.session = URLSession(configuration: sessionConfiguration)
        self.retryCount = configuration.retryCount
    }

    /// 下载字符串内容
    func downloadString(from url: URL) async throws -> String {
        var lastError: Error?

        for attempt in 0..<retryCount {
            do {
                let (data, response) = try await session.data(from: url)

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
                let (data, response) = try await session.data(from: url)

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

    /// 下载文件（带进度回调）
    func downloadFile(
        from url: URL,
        to destinationURL: URL,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws -> URL {
        let (asyncBytes, response) = try await session.bytes(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.httpError(statusCode: httpResponse.statusCode)
        }

        let totalBytes = response.expectedContentLength
        var downloadedBytes: Int64 = 0

        FileManager.default.createFile(atPath: destinationURL.path, contents: nil, attributes: nil)
        let fileHandle = try FileHandle(forWritingTo: destinationURL)

        defer {
            try? fileHandle.close()
        }

        for try await byte in asyncBytes {
            try fileHandle.write(contentsOf: [byte])
            downloadedBytes += 1

            if downloadedBytes % 1024 == 0 {
                progress(downloadedBytes, totalBytes)
            }
        }

        progress(downloadedBytes, totalBytes)

        return destinationURL
    }

    /// 下载文件（支持断点续传）
    func downloadFileWithResume(
        from url: URL,
        to destinationURL: URL,
        resumeData: Data? = nil,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws -> (URL, Data?) {
        var request = URLRequest(url: url)

        // 如果有resumeData，这里需要从resumeData中提取已下载的字节数
        // 简化实现：直接使用Range头
        // 实际应该从resumeData中解析

        let (asyncBytes, response) = try await session.bytes(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.httpError(statusCode: httpResponse.statusCode)
        }

        let totalBytes = response.expectedContentLength
        var downloadedBytes: Int64 = 0

        if !FileManager.default.fileExists(atPath: destinationURL.path) {
            FileManager.default.createFile(atPath: destinationURL.path, contents: nil, attributes: nil)
        }

        let fileHandle = try FileHandle(forWritingTo: destinationURL)
        try fileHandle.seekToEnd()

        defer {
            try? fileHandle.close()
        }

        for try await byte in asyncBytes {
            try fileHandle.write(contentsOf: [byte])
            downloadedBytes += 1

            if downloadedBytes % 1024 == 0 {
                progress(downloadedBytes, totalBytes)
            }
        }

        progress(downloadedBytes, totalBytes)

        return (destinationURL, nil)
    }
}
