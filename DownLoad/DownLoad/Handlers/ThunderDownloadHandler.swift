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

    init(
        networkClient: NetworkClient,
        storageManager: FileStorageManager
    ) {
        self.parser = ThunderParser()
        self.mp4Handler = MP4DownloadHandler(networkClient: networkClient, storageManager: storageManager)
        self.m3u8Handler = M3U8DownloadHandler(networkClient: networkClient, storageManager: storageManager)
    }

    func createTask(
        url: String,
        fileName: String?,
        configuration: DownloadConfiguration
    ) async throws -> any DownloadTask {
        // 1. 解析迅雷链接获取真实URL
        let realURL = try parser.parse(thunderURL: url)
        let realURLString = realURL.absoluteString

        Logger.info("Thunder protocol decoded to: \(realURLString)")

        // 2. 判断真实URL的格式
        let format = detectVideoFormat(from: realURLString)

        // 3. 委托给对应的Handler处理
        switch format {
        case .mp4:
            return try await mp4Handler.createTask(
                url: realURLString,
                fileName: fileName,
                configuration: configuration
            )
        case .m3u8:
            return try await m3u8Handler.createTask(
                url: realURLString,
                fileName: fileName,
                configuration: configuration
            )
        case .thunder:
            // 如果还是迅雷协议，抛出错误避免无限递归
            throw DownloadError.thunderProtocolError
        }
    }

    /// 检测视频格式
    private func detectVideoFormat(from url: String) -> VideoFormat {
        let lowercased = url.lowercased()

        if lowercased.contains(".m3u8") {
            return .m3u8
        } else if lowercased.contains(".mp4") {
            return .mp4
        } else {
            // 默认尝试作为MP4处理
            return .mp4
        }
    }
}
