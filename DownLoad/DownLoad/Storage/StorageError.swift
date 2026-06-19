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
            return "File not found at path: \(path)"
        case .directoryCreationFailed(let path):
            return "Failed to create directory at path: \(path)"
        case .insufficientStorage(let required, let available):
            return "Insufficient storage. Required: \(required) bytes, Available: \(available) bytes"
        case .fileWriteFailed(let path):
            return "Failed to write file at path: \(path)"
        case .fileReadFailed(let path):
            return "Failed to read file at path: \(path)"
        case .fileDeleteFailed(let path):
            return "Failed to delete file at path: \(path)"
        case .databaseOpenFailed(let message):
            return "Database open failed: \(message)"
        case .databaseQueryFailed(let message):
            return "Database query failed: \(message)"
        case .databaseMigrationFailed(let message):
            return "Database migration failed: \(message)"
        case .recordNotFound(let id):
            return "Record not found for id: \(id)"
        }
    }
}
