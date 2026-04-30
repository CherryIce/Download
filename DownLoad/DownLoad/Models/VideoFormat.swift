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

    var fileExtension: String {
        switch self {
        case .mp4:
            return "mp4"
        case .m3u8, .thunder:
            return "mp4" // m3u8下载后转换为mp4
        }
    }
}
