//
//  DownloadProgress.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation

/// 下载进度模型
struct DownloadProgress {
    let taskId: UUID
    let totalBytes: Int64
    let downloadedBytes: Int64
    let progress: Float  // 0.0 - 1.0
    let speed: Int64     // bytes/second
    let remainingTime: TimeInterval?

    var percentage: String {
        return String(format: "%.1f%%", progress * 100)
    }

    var formattedSpeed: String {
        return SpeedCalculator.formatSpeed(speed)
    }

    var formattedRemainingTime: String {
        return SpeedCalculator.formatTime(remainingTime)
    }

    var formattedDownloaded: String {
        return ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
    }

    var formattedTotal: String {
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    static let empty = DownloadProgress(
        taskId: UUID(),
        totalBytes: 0,
        downloadedBytes: 0,
        progress: 0,
        speed: 0,
        remainingTime: nil
    )
}
