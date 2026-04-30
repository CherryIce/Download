//
//  DownloadTaskProtocol.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation
import Combine

/// 下载任务协议
protocol DownloadTask: AnyObject {
    var id: UUID { get }
    var url: String { get }
    var fileName: String { get }
    var configuration: DownloadConfiguration { get }
    var state: CurrentValueSubject<DownloadState, Never> { get }
    var progress: CurrentValueSubject<DownloadProgress, Never> { get }
    var completedURL: URL? { get }

    func resume() async throws
    func pause() async
    func cancel() async
}
