//
//  DownloadPriority.swift
//  DownLoad
//
//  Created by hubin on 2026/6/20.
//

import Foundation

/// 下载优先级
enum DownloadPriority: Int, Codable, Comparable, CaseIterable {
    case low = 0
    case normal = 1
    case high = 2

    static func < (lhs: DownloadPriority, rhs: DownloadPriority) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}
