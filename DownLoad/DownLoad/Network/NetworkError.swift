//
//  NetworkError.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation

enum NetworkError: Error, LocalizedError {
    case invalidURL(String)
    case noData
    case httpError(statusCode: Int)
    case connectionError(Error)
    case timeout
    case invalidResponse
    case resumeError(underlying: Error, resumeData: Data?)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "URL 无效：\(url)"
        case .noData:
            return "未收到数据"
        case .httpError(let statusCode):
            return "HTTP 错误，状态码：\(statusCode)"
        case .connectionError(let error):
            return "连接错误：\(error.localizedDescription)"
        case .timeout:
            return "请求超时"
        case .invalidResponse:
            return "服务器响应无效"
        case .resumeError(let underlying, _):
            return "下载失败（已保存可恢复数据）：\(underlying.localizedDescription)"
        }
    }

    /// 提取 resumeData（如果有）
    var resumeData: Data? {
        if case .resumeError(_, let data) = self {
            return data
        }
        return nil
    }
}
