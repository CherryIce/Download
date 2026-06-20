//
//  StorageError.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation

enum StorageError: Error, LocalizedError {
    case fileNotFound(String)
    case directoryCreationFailed(String)
    case insufficientStorage(required: Int64, available: Int64)
    case fileWriteFailed(String)
    case fileReadFailed(String)
    case fileDeleteFailed(String)
    case databaseOpenFailed(String)
    case databaseQueryFailed(String)
    case databaseMigrationFailed(String)
    case recordNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "文件未找到：\(path)"
        case .directoryCreationFailed(let path):
            return "创建目录失败：\(path)"
        case .insufficientStorage(let required, let available):
            return "存储空间不足。需要：\(required) 字节，可用：\(available) 字节"
        case .fileWriteFailed(let path):
            return "写入文件失败：\(path)"
        case .fileReadFailed(let path):
            return "读取文件失败：\(path)"
        case .fileDeleteFailed(let path):
            return "删除文件失败：\(path)"
        case .databaseOpenFailed(let message):
            return "数据库打开失败：\(message)"
        case .databaseQueryFailed(let message):
            return "数据库查询失败：\(message)"
        case .databaseMigrationFailed(let message):
            return "数据库迁移失败：\(message)"
        case .recordNotFound(let id):
            return "记录未找到，ID：\(id)"
        }
    }
}
