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
            return "Invalid URL: \(url)"
        case .noData:
            return "No data received"
        case .httpError(let statusCode):
            return "HTTP error with status code: \(statusCode)"
        case .connectionError(let error):
            return "Connection error: \(error.localizedDescription)"
        case .timeout:
            return "Request timeout"
        case .invalidResponse:
            return "Invalid response from server"
        case .resumeError(let underlying, _):
            return "Download failed with resumable data: \(underlying.localizedDescription)"
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
