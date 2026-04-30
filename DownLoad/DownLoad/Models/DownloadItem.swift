//
//  DownloadItem.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation

/// 下载项模型
struct DownloadItem: Codable, Identifiable {
    let id: UUID
    let url: String
    let format: VideoFormat
    let fileName: String
    let totalSize: Int64?
    var downloadedSize: Int64
    var state: DownloadState
    let createdAt: Date
    var completedAt: Date?
    var resumeData: Data?

    init(
        id: UUID = UUID(),
        url: String,
        format: VideoFormat,
        fileName: String,
        totalSize: Int64? = nil,
        downloadedSize: Int64 = 0,
        state: DownloadState = .pending,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        resumeData: Data? = nil
    ) {
        self.id = id
        self.url = url
        self.format = format
        self.fileName = fileName
        self.totalSize = totalSize
        self.downloadedSize = downloadedSize
        self.state = state
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.resumeData = resumeData
    }

    var fileURL: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoDownloads/Completed")
            .appendingPathComponent(fileName)
    }
}
