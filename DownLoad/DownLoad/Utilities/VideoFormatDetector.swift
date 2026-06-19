//
//  VideoFormatDetector.swift
//  DownLoad
//
//  Created on 2026/6/20.
//

import Foundation

/// 视频格式检测器
/// 支持通过 URL 字符串匹配（快速路径）和 HEAD 请求 Content-Type（慢速路径）两种检测方式
struct VideoFormatDetector {

    // MARK: - Content-Type 到 VideoFormat 的映射表

    private static let contentTypeMapping: [String: VideoFormat] = [
        // HLS 流媒体
        "application/vnd.apple.mpegurl": .m3u8,
        "application/x-mpegurl": .m3u8,
        "audio/mpegurl": .m3u8,
        "audio/x-mpegurl": .m3u8,

        // MP4 / MPEG-4
        "video/mp4": .mp4,
        "video/mpeg": .mp4,
        "application/mp4": .mp4,
        "application/octet-stream": .mp4,  // 很多CDN对视频文件返回 octet-stream

        // WebM
        "video/webm": .webm,
        "audio/webm": .webm,

        // MKV (Matroska)
        "video/x-matroska": .mkv,
        "video/matroska": .mkv,
        "audio/x-matroska": .mkv,

        // FLV (Flash Video)
        "video/x-flv": .flv,
        "video/flv": .flv,

        // QuickTime / MOV
        "video/quicktime": .mov,
        "video/x-quicktime": .mov,
    ]

    // MARK: - 已知的视频文件扩展名到格式的映射

    private static let extensionMapping: [String: VideoFormat] = [
        "m3u8": .m3u8,
        "mp4": .mp4,
        "webm": .webm,
        "mkv": .mkv,
        "flv": .flv,
        "mov": .mov,
    ]

    // MARK: - URL 字符串快速匹配

    /// 通过 URL 字符串检测视频格式（无网络请求）
    /// - Parameter url: 视频 URL 字符串
    /// - Returns: 检测到的格式；无法识别时返回 nil
    static func detectFromURLString(_ url: String) -> VideoFormat? {
        let lowercased = url.lowercased()

        // 迅雷协议特殊处理
        if lowercased.hasPrefix("thunder://") {
            return .thunder
        }

        // 从 URL 路径中提取文件扩展名
        // 使用 URL.pathExtension 自动去除查询参数和片段
        guard let urlObj = URL(string: url) else {
            return nil
        }

        let pathExtension = urlObj.pathExtension.lowercased()
        if !pathExtension.isEmpty, let format = extensionMapping[pathExtension] {
            return format
        }

        // 兜底：检查整个 URL 字符串中是否包含已知扩展名
        // 确保匹配的是真正的扩展名（后面跟着 ?、#、& 或字符串结尾）
        for (ext, format) in extensionMapping {
            let pattern = "\\.\(ext)([?&#]|$)"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               regex.firstMatch(in: lowercased, range: NSRange(lowercased.startIndex..., in: lowercased)) != nil {
                return format
            }
        }

        return nil
    }

    // MARK: - Content-Type 检测

    /// 通过 HTTP Content-Type 检测视频格式
    /// - Parameter contentType: HTTP 响应头 Content-Type 值（可能为 nil）
    /// - Returns: 检测到的格式；无法识别时返回 nil
    static func detectFromContentType(_ contentType: String?) -> VideoFormat? {
        guard let contentType = contentType?.lowercased().trimmingCharacters(in: .whitespaces) else {
            return nil
        }

        // Content-Type 可能包含参数，如 "video/mp4; charset=utf-8"
        // 只取分号前的 MIME 类型部分
        let mimeType = contentType.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? contentType

        return contentTypeMapping[mimeType]
    }
}
