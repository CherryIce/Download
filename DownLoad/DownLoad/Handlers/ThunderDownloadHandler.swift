//
//  ThunderDownloadHandler.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation

/// 迅雷协议下载处理器
class ThunderDownloadHandler: DownloadHandlerProtocol {

    private let parser: ThunderParser
    private let mp4Handler: MP4DownloadHandler
    private let m3u8Handler: M3U8DownloadHandler
    private let networkClient: NetworkClient

    init(
        networkClient: NetworkClient,
        storageManager: FileStorageManager
    ) {
        self.parser = ThunderParser()
        self.mp4Handler = MP4DownloadHandler(networkClient: networkClient, storageManager: storageManager)
        self.m3u8Handler = M3U8DownloadHandler(networkClient: networkClient, storageManager: storageManager)
        self.networkClient = networkClient
    }

    func createTask(
        url: String,
        fileName: String?,
        configuration: DownloadConfiguration,
        format: VideoFormat
    ) async throws -> any DownloadTask {
        // 1. 解析迅雷链接获取真实URL
        let realURL = try parser.parse(thunderURL: url)
        let realURLString = realURL.absoluteString

        Logger.info("Thunder protocol decoded to: \(realURLString)")

        // 2. 判断真实URL的格式（使用共享的检测逻辑）
        let format = await detectVideoFormat(from: realURLString)

        // 3. 委托给对应的Handler处理
        switch format {
        case .mp4, .webm, .mkv, .flv, .mov:
            return try await mp4Handler.createTask(
                url: realURLString,
                fileName: fileName,
                configuration: configuration,
                format: format
            )
        case .m3u8:
            return try await m3u8Handler.createTask(
                url: realURLString,
                fileName: fileName,
                configuration: configuration,
                format: format
            )
        case .thunder:
            // 如果还是迅雷协议，抛出错误避免无限递归
            throw DownloadError.thunderProtocolError
        }
    }

    /// 检测视频格式（使用共享的 VideoFormatDetector + HEAD 请求）
    private func detectVideoFormat(from url: String) async -> VideoFormat {
        // 第一级：URL 字符串快速匹配
        if let format = VideoFormatDetector.detectFromURLString(url) {
            return format
        }

        // 第二级：HEAD 请求 Content-Type
        guard let urlObj = URL(string: url) else {
            return .mp4
        }

        do {
            let headers = try await networkClient.fetchResponseHeaders(from: urlObj)
            if let format = VideoFormatDetector.detectFromContentType(headers.contentType) {
                return format
            }
            return .mp4
        } catch {
            Logger.warning("HEAD request failed for thunder format detection, defaulting to mp4")
            return .mp4
        }
    }
}
