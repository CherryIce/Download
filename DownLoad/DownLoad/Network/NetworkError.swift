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
        }
    }
}
