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
    let keyFormat: String?          // 密钥格式，如 "identity", "com.apple.streamingkeydelivery"
}

/// M3U8字节范围信息（用于 #EXT-X-BYTERANGE 和 #EXT-X-MAP 的 BYTERANGE 属性）
struct M3U8ByteRange {
    let length: Int
    let offset: Int?  // nil 表示接续上一个范围的末尾
}

/// M3U8初始化片段信息（用于 fMP4 容器的 #EXT-X-MAP）
struct M3U8MapInfo {
    let uri: URL
    let byteRange: M3U8ByteRange?
}

/// M3U8片段
struct M3U8Segment {
    let url: URL
    let duration: Double
    let encryption: M3U8Encryption?
    let byteRange: M3U8ByteRange?   // 字节范围（子范围片段）
    let map: M3U8MapInfo?            // 片段级别的 MAP 覆盖（通常为 nil，继承播放列表级别）
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
    let isLive: Bool                 // 是否为直播流（无 #EXT-X-ENDLIST）
    let mediaSequence: Int?          // #EXT-X-MEDIA-SEQUENCE 值
    let map: M3U8MapInfo?            // 播放列表级别的初始化片段（fMP4）
    let isFMP4: Bool                 // 是否为 fMP4 容器（存在 #EXT-X-MAP 时为 true）

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

    // 字节级跟踪
    var segmentByteSizes: [Int: Int64]  // index -> 文件大小（字节）
    var totalEstimatedBytes: Int64?     // 估算总字节数

    // 用于恢复时识别 playlist 是否变化
    var playlistIdentifier: String?     // 存储 playlist URL

    // fMP4 和密钥轮换支持
    var isFMP4: Bool                           // 是否 fMP4 容器
    var encryptionKeys: [String: String]       // keyURL -> 缓存文件名（密钥轮换支持）
    var initSegmentDownloaded: Bool            // 初始化片段是否已下载

    init(totalSegments: Int, segmentURLs: [String] = [], playlistIdentifier: String? = nil) {
        self.totalSegments = totalSegments
        self.completedSegments = []
        self.failedSegments = []
        self.segmentURLs = segmentURLs
        self.segmentByteSizes = [:]
        self.totalEstimatedBytes = nil
        self.playlistIdentifier = playlistIdentifier
        self.isFMP4 = false
        self.encryptionKeys = [:]
        self.initSegmentDownloaded = false
    }

    var progress: Float {
        guard totalSegments > 0 else { return 0 }
        return Float(completedSegments.count) / Float(totalSegments)
    }

    /// 已下载字节总数
    var downloadedBytes: Int64 {
        return segmentByteSizes.values.reduce(0, +)
    }
}
