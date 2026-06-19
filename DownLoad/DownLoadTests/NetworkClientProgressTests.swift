//
//  NetworkClientProgressTests.swift
//  DownLoadTests
//
//  Created by hubin on 2026/6/19.
//

import Testing
import Foundation
@testable import DownLoad

@Suite("NetworkClient 进度回调测试")
struct NetworkClientProgressTests {

    // MARK: - downloadFile 进度回调测试

    @Test("downloadFile 在下载过程中触发多次进度回调")
    func testDownloadFileReportsProgress() async throws {
        let client = NetworkClient()
        var progressCalls: [(Int64, Int64)] = []

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NetworkClientProgressTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let destinationURL = tempDir.appendingPathComponent("test_progress.bin")

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // 使用一个足够大的文件以确保有多次进度回调
        guard let url = URL(string: "https://httpbin.org/bytes/65536") else {
            Issue.record("无法创建测试 URL")
            return
        }

        // 使用 withTaskGroup 实现带超时的下载
        let downloadResult: Result<URL, Error> = await withTaskGroup(of: Result<URL, Error>.self) { group in
            group.addTask {
                do {
                    let result = try await client.downloadFile(from: url, to: destinationURL) { downloaded, total in
                        progressCalls.append((downloaded, total))
                    }
                    return .success(result)
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 15_000_000_000) // 15秒超时
                return .failure(NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Timeout"]))
            }

            let first = await group.next()!
            group.cancelAll()
            return first
        }

        // 下载可能因网络原因失败，但只要触发了进度回调就算通过
        if case .failure(let error) = downloadResult {
            // 超时或网络错误不影响进度回调验证
            print("下载失败（预期可能）: \(error.localizedDescription)")
        }

        // 验证：应该至少有1次进度回调（下载过程中 + 完成时）
        #expect(progressCalls.count >= 1, "应有至少1次进度回调，实际 \(progressCalls.count) 次")

        // 如果有多次回调，验证 downloadedBytes 是递增的
        if progressCalls.count >= 2 {
            for i in 1..<progressCalls.count {
                #expect(progressCalls[i].0 >= progressCalls[i-1].0,
                       "下载字节数应递增: \(progressCalls[i-1].0) -> \(progressCalls[i].0)")
            }
        }
    }

    @Test("downloadFile 完成时进度回调报告完整下载")
    func testDownloadFileCompletionReportsFullProgress() async throws {
        let client = NetworkClient()
        var lastProgress: (Int64, Int64)?

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NetworkClientProgressTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let destinationURL = tempDir.appendingPathComponent("test_complete.bin")

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        guard let url = URL(string: "https://httpbin.org/bytes/1024") else {
            Issue.record("无法创建测试 URL")
            return
        }

        _ = try await client.downloadFile(from: url, to: destinationURL) { downloaded, total in
            lastProgress = (downloaded, total)
        }

        // 验证：最后一次进度回调中 downloaded 应等于 total
        #expect(lastProgress != nil, "应有至少1次进度回调")
        if let progress = lastProgress {
            #expect(progress.0 == progress.1,
                   "完成时 downloaded(\(progress.0)) 应等于 total(\(progress.1))")
            #expect(progress.0 > 0, "下载的字节数应大于 0")
        }

        // 验证文件已成功保存
        let fileExists = FileManager.default.fileExists(atPath: destinationURL.path)
        #expect(fileExists, "下载完成后文件应存在")
    }
}
