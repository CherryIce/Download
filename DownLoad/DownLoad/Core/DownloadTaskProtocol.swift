//
//  DownloadTaskProtocol.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation
import Combine

/// 暂停原因
enum PauseReason: String, Codable {
    case userInitiated       // 用户手动暂停
    case networkLost         // 网络断开自动暂停
    case cellularRestricted  // 蜂窝网络受限自动暂停
}

/// 下载任务协议
protocol DownloadTask: AnyObject {
    var id: UUID { get }
    var url: String { get }
    var fileName: String { get }
    var format: VideoFormat { get }
    var totalSize: Int64? { get }
    var downloadedSize: Int64 { get }
    var createdAt: Date { get }
    var completedAt: Date? { get }
    var resumeData: Data? { get }
    var configuration: DownloadConfiguration { get }
    var state: CurrentValueSubject<DownloadState, Never> { get }
    var progress: CurrentValueSubject<DownloadProgress, Never> { get }
    var completedURL: URL? { get }

    /// 当前暂停原因（nil 表示未被暂停或暂停原因未知）
    var pauseReason: PauseReason? { get set }

    func resume() async throws
    func pause() async
    func cancel() async

    /// 带原因的暂停（供 NetworkMonitor 调用）
    func pause(reason: PauseReason) async
}
