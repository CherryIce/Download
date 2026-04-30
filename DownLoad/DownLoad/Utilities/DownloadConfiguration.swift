//
//  DownloadConfiguration.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation

/// 下载配置
struct DownloadConfiguration {
    let maxConcurrentDownloads: Int
    let timeoutInterval: TimeInterval
    let retryCount: Int
    let enableBackgroundDownload: Bool

    static let `default` = DownloadConfiguration(
        maxConcurrentDownloads: Constants.Network.maxConcurrentDownloads,
        timeoutInterval: Constants.Network.timeoutInterval,
        retryCount: Constants.Network.maxRetryCount,
        enableBackgroundDownload: true
    )
}
