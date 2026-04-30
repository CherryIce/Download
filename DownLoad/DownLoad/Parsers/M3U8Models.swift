//
//  M3U8Models.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation

/// M3U8播放列表协议
protocol M3U8Playlist {}

/// M3U8加密方法
enum M3U8EncryptionMethod: String {
    case aes128 = "AES-128"
    case sampleAES = "SAMPLE-AES"
    case none = "NONE"
}

/// M3U8加密信息
struct M3U8Encryption {
    let method: M3U8EncryptionMethod
    let keyURL: URL
    let iv: Data?
}

/// M3U8片段
struct M3U8Segment {
    let url: URL
    let duration: Double
    let encryption: M3U8Encryption?
}

/// M3U8变体流（Master Playlist中的条目）
struct M3U8Variant {
    let bandwidth: Int
    let resolution: String?
    let url: URL
}

/// Master Playlist（多码率列表）
struct M3U8MasterPlaylist: M3U8Playlist {
    let variants: [M3U8Variant]

    /// 选择最佳变体流
    func selectBestVariant(for bandwidth: Int64? = nil) -> M3U8Variant {
        if let bandwidth = bandwidth {
            // 选择不超过指定带宽的最高质量
            let suitableVariants = variants.filter { $0.bandwidth <= Int(bandwidth) }
            return suitableVariants.max(by: { $0.bandwidth < $1.bandwidth }) ?? variants.first!
        } else {
            // 选择最高质量
            return variants.max(by: { $0.bandwidth < $1.bandwidth }) ?? variants.first!
        }
    }
}

/// Media Playlist（TS片段列表）
struct M3U8MediaPlaylist: M3U8Playlist {
    let segments: [M3U8Segment]
    let targetDuration: Double
    let isEncrypted: Bool
    let version: Int?

    var totalDuration: Double {
        segments.reduce(0) { $0 + $1.duration }
    }

    var totalSegments: Int {
        segments.count
    }
}

/// M3U8下载状态
struct M3U8DownloadState: Codable {
    let totalSegments: Int
    var completedSegments: Set<Int>
    var failedSegments: Set<Int>
    var segmentURLs: [String]

    init(totalSegments: Int, segmentURLs: [String] = []) {
        self.totalSegments = totalSegments
        self.completedSegments = []
        self.failedSegments = []
        self.segmentURLs = segmentURLs
    }

    var progress: Float {
        guard totalSegments > 0 else { return 0 }
        return Float(completedSegments.count) / Float(totalSegments)
    }
}
