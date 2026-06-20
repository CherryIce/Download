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
    case liveStreamNotSupported
    case keyFormatNotSupported(format: String)
    case byteRangeRequestFailed(url: String)
    case p2pDownloadNotSupported(protocolType: String)
    case magnetLinkNotSupported

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
        case .liveStreamNotSupported:
            return "Live HLS streams are not currently supported for download"
        case .keyFormatNotSupported(let format):
            return "Key format '\(format)' is not supported"
        case .byteRangeRequestFailed(let url):
            return "Byte range request failed for URL: \(url)"
        case .p2pDownloadNotSupported(let protocolType):
            return "\(protocolType) 协议需要迅雷客户端或 BT 客户端支持，本应用暂不支持 P2P 下载"
        case .magnetLinkNotSupported:
            return "磁力链接需要迅雷客户端或 BT 客户端支持，本应用暂不支持磁力链接下载"
        }
    }
}
