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

    var displayText: String {
        switch self {
        case .pending: return "等待中"
        case .downloading: return "下载中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}
