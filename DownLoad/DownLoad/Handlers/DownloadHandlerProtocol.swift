//
//  DownloadHandlerProtocol.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation

/// 下载处理器协议
protocol DownloadHandlerProtocol {
    func createTask(
        url: String,
        fileName: String?,
        configuration: DownloadConfiguration
    ) async throws -> any DownloadTask
}
