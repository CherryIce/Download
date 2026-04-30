//
//  DownloadState.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation

/// 下载状态枚举
enum DownloadState: String, Codable {
    case pending = "pending"           // 等待中
    case downloading = "downloading"   // 下载中
    case paused = "paused"             // 已暂停
    case completed = "completed"       // 已完成
    case failed = "failed"             // 失败
    case cancelled = "cancelled"       // 已取消
}
