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
    /// 自定义请求头，key 为请求头名称，value 为请求头值。为空时使用默认请求头。
    let customHeaders: [String: String]
    /// 是否允许蜂窝网络下载（仅对当前任务有效）
    let allowCellularDownload: Bool

    static var `default`: DownloadConfiguration {
        return DownloadConfiguration(
            maxConcurrentDownloads: SettingsViewController.getMaxConcurrentDownloads(),
            timeoutInterval: SettingsViewController.getTimeoutInterval(),
            retryCount: SettingsViewController.getRetryCount(),
            enableBackgroundDownload: SettingsViewController.getEnableBackgroundDownload(),
            customHeaders: [:],
            allowCellularDownload: SettingsViewController.getAllowCellularDownload()
        )
    }

    /// 带自定义请求头的便捷构造方法
    init(
        maxConcurrentDownloads: Int = Constants.Network.maxConcurrentDownloads,
        timeoutInterval: TimeInterval = Constants.Network.timeoutInterval,
        retryCount: Int = Constants.Network.maxRetryCount,
        enableBackgroundDownload: Bool = true,
        customHeaders: [String: String] = [:],
        allowCellularDownload: Bool = Constants.NetworkMonitor.defaultAllowCellularDownload
    ) {
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.timeoutInterval = timeoutInterval
        self.retryCount = retryCount
        self.enableBackgroundDownload = enableBackgroundDownload
        self.customHeaders = customHeaders
        self.allowCellularDownload = allowCellularDownload
    }
}
