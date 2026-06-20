//
//  CompletedFileItem.swift
//  DownLoad
//

import Foundation

/// 已完成文件展示模型
/// 合并文件系统信息和数据库元数据
struct CompletedFileItem: Identifiable {
    let id: UUID
    let fileName: String
    let fileURL: URL
    let fileSize: Int64
    let format: VideoFormat
    let completedAt: Date?
    let sourceURL: String?
    let createdAt: Date?
    let hasDatabaseRecord: Bool

    /// 格式化文件大小
    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    /// 格式化完成时间
    var formattedCompletedAt: String? {
        guard let date = completedAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// 文件扩展名（大写）
    var fileExtension: String {
        (fileName as NSString).pathExtension.uppercased()
    }
}
