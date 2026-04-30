//
//  DownloadError.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation

enum DownloadError: Error, LocalizedError {
    case invalidURL(String)
    case networkError(Error)
    case parseError(String)
    case fileSystemError(Error)
    case insufficientStorage(required: Int64, available: Int64)
    case taskCancelled
    case taskFailed(Error)
    case encryptionNotSupported
    case invalidM3U8Format
    case thunderProtocolError

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .parseError(let message):
            return "Parse error: \(message)"
        case .fileSystemError(let error):
            return "File system error: \(error.localizedDescription)"
        case .insufficientStorage(let required, let available):
            return "Insufficient storage. Required: \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)), Available: \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))"
        case .taskCancelled:
            return "Download task cancelled"
        case .taskFailed(let error):
            return "Download task failed: \(error.localizedDescription)"
        case .encryptionNotSupported:
            return "Encryption method not supported"
        case .invalidM3U8Format:
            return "Invalid M3U8 format"
        case .thunderProtocolError:
            return "Invalid thunder protocol format"
        }
    }
}
