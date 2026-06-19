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
        static let stateFileName = "download_state.json"  // M3U8下载状态文件名
        static let maxEncryptionKeys: Int = 10        // 密钥轮换数量上限
    }

    /// 网络监控相关常量
    struct NetworkMonitor {
        /// 网络状态变更后的恢复延迟（秒），避免网络短暂波动导致频繁暂停/恢复
        static let networkRestoreDelay: TimeInterval = 2.0
        /// 网络断开后的暂停延迟（秒），给系统一点缓冲时间
        static let networkLostDelay: TimeInterval = 0.5
        /// 默认是否允许蜂窝网络下载
        static let defaultAllowCellularDownload = true
    }
}
