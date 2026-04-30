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
        }
    }
}
