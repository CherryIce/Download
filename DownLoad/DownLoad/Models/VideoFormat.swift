//
//  VideoFormat.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation

/// 视频格式枚举
enum VideoFormat: String, Codable {
    case mp4 = "mp4"
    case m3u8 = "m3u8"
    case thunder = "thunder"
    case webm = "webm"
    case mkv = "mkv"
    case flv = "flv"
    case mov = "mov"

    var fileExtension: String {
        switch self {
        case .mp4:
            return "mp4"
        case .m3u8, .thunder:
            return "mp4" // m3u8下载后转换为mp4
        case .webm:
            return "webm"
        case .mkv:
            return "mkv"
        case .flv:
            return "flv"
        case .mov:
            return "mov"
        }
    }

    /// 是否使用 M3U8 下载处理器（HLS 流媒体）
    var isStreamingFormat: Bool {
        return self == .m3u8
    }

    /// 是否使用直接二进制下载（MP4/WebM/MKV/FLV/MOV 均走同一下载器）
    var isDirectDownloadFormat: Bool {
        switch self {
        case .mp4, .webm, .mkv, .flv, .mov:
            return true
        case .m3u8, .thunder:
            return false
        }
    }
}
