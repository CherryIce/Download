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
            return "URL 无效：\(url)"
        case .networkError(let error):
            return "网络错误：\(error.localizedDescription)"
        case .parseError(let message):
            return "解析错误：\(message)"
        case .fileSystemError(let error):
            return "文件系统错误：\(error.localizedDescription)"
        case .insufficientStorage(let required, let available):
            return "存储空间不足。需要：\(ByteCountFormatter.string(fromByteCount: required, countStyle: .file))，可用：\(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))"
        case .taskCancelled:
            return "下载任务已取消"
        case .taskFailed(let error):
            return "下载任务失败：\(error.localizedDescription)"
        case .encryptionNotSupported:
            return "不支持的加密方式"
        case .invalidM3U8Format:
            return "M3U8 格式无效"
        case .thunderProtocolError:
            return "迅雷协议格式无效"
        case .liveStreamNotSupported:
            return "暂不支持下载直播 HLS 流"
        case .keyFormatNotSupported(let format):
            return "不支持的密钥格式：\(format)"
        case .byteRangeRequestFailed(let url):
            return "字节范围请求失败，URL：\(url)"
        case .p2pDownloadNotSupported(let protocolType):
            return "\(protocolType) 协议需要迅雷客户端或 BT 客户端支持，本应用暂不支持 P2P 下载"
        case .magnetLinkNotSupported:
            return "磁力链接需要迅雷客户端或 BT 客户端支持，本应用暂不支持磁力链接下载"
        }
    }
}
