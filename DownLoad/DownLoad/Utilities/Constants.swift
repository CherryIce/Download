//
//  Constants.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation

struct Constants {
    struct Network {
        static let timeoutInterval: TimeInterval = 30
        static let resourceTimeoutInterval: TimeInterval = 60
        static let maxRetryCount = 3
        static let maxConcurrentDownloads = 5
    }

    struct Storage {
        static let downloadsDirectoryName = "VideoDownloads"
        static let inProgressDirectoryName = "InProgress"
        static let completedDirectoryName = "Completed"
        static let cacheDirectoryName = "Cache"
        static let maxCacheSize: Int64 = 1024 * 1024 * 1024 // 1GB
        static let cacheExpirationDays = 30
        static let defaultMP4SpaceRequirement: Int64 = 100 * 1024 * 1024 // 默认MP4空间要求：100MB
    }

    struct Download {
        static let progressUpdateInterval: TimeInterval = 0.1
        static let minProgressChange: Float = 0.01
    }

    struct M3U8 {
        static let maxConcurrentSegmentDownloads = 6  // M3U8片段最大并发下载数
        static let mergeBufferSize = 256 * 1024       // 流式合并缓冲区大小：256KB
    }
}
