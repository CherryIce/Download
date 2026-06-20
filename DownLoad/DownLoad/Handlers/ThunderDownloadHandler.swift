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
        // 根据格式分支处理
        switch format {
        case .magnet:
            // 直接输入的磁力链接，不需要解析
            Logger.info("Magnet link detected, not supported: \(url)")
            throw DownloadError.magnetLinkNotSupported

        case .thunderP2P:
            // thunderp2p:// 链接，尝试解析
            return try await handleThunderP2P(url: url, fileName: fileName, configuration: configuration)

        case .thunder:
            // 经典 thunder:// 链接
            return try await handleClassicThunder(url: url, fileName: fileName, configuration: configuration)

        default:
            throw DownloadError.thunderProtocolError
        }
    }

    /// 处理经典迅雷链接
    private func handleClassicThunder(url: String, fileName: String?, configuration: DownloadConfiguration) async throws -> any DownloadTask {
        let result = try parser.parse(thunderURL: url)
        let realURLString = result.url.absoluteString

        Logger.info("Thunder protocol decoded to: \(realURLString)")

        // 如果解码后是磁力链接，抛出不支持错误
        if result.isMagnetLink {
            Logger.info("Thunder link decoded to magnet link, not supported: \(realURLString)")
            throw DownloadError.magnetLinkNotSupported
        }

        // 判断真实 URL 的格式并委托给对应 Handler
        let detectedFormat = await detectVideoFormat(from: realURLString)
        return try await delegateToHandler(url: realURLString, fileName: fileName, configuration: configuration, format: detectedFormat)
    }

    /// 处理迅雷 P2P 链接
    private func handleThunderP2P(url: String, fileName: String?, configuration: DownloadConfiguration) async throws -> any DownloadTask {
        let result = try parser.parse(thunderURL: url)

        // P2P 链接触发 P2P 不支持提示
        if result.isP2P && result.isMagnetLink {
            Logger.info("ThunderP2P decoded to magnet link, not supported: \(result.url.absoluteString)")
            throw DownloadError.magnetLinkNotSupported
        }

        // P2P 链接解码后为普通 URL（罕见但可能），尝试委托下载
        let realURLString = result.url.absoluteString
        Logger.info("ThunderP2P decoded to real URL: \(realURLString)")

        let detectedFormat = await detectVideoFormat(from: realURLString)
        return try await delegateToHandler(url: realURLString, fileName: fileName, configuration: configuration, format: detectedFormat)
    }

    /// 委托给对应的 Handler 处理
    private func delegateToHandler(url: String, fileName: String?, configuration: DownloadConfiguration, format: VideoFormat) async throws -> any DownloadTask {
        switch format {
        case .mp4, .webm, .mkv, .flv, .mov:
            return try await mp4Handler.createTask(
                url: url,
                fileName: fileName,
                configuration: configuration,
                format: format
            )
        case .m3u8:
            return try await m3u8Handler.createTask(
                url: url,
                fileName: fileName,
                configuration: configuration,
                format: format
            )
        case .thunder, .thunderP2P, .magnet:
            // 避免无限递归
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
