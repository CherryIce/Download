//
//  SpeedCalculator.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation

/// 速度计算器
class SpeedCalculator {

    private var samples: [(timestamp: TimeInterval, bytes: Int64)] = []
    private let maxSamples = 10
    private var lastBytes: Int64 = 0
    private var lastTimestamp: TimeInterval = 0

    /// 添加样本
    func addSample(bytes: Int64, timestamp: TimeInterval = Date().timeIntervalSince1970) {
        samples.append((timestamp: timestamp, bytes: bytes))

        // 保持样本数量限制
        if samples.count > maxSamples {
            samples.removeFirst()
        }

        lastBytes = bytes
        lastTimestamp = timestamp
    }

    /// 计算当前速度（字节/秒）
    func calculateSpeed() -> Int64 {
        guard samples.count >= 2 else { return 0 }

        let oldest = samples.first!
        let newest = samples.last!

        let timeDiff = newest.timestamp - oldest.timestamp
        guard timeDiff > 0 else { return 0 }

        let bytesDiff = newest.bytes - oldest.bytes
        let speed = Int64(Double(bytesDiff) / timeDiff)

        return max(0, speed)
    }

    /// 计算平均速度（字节/秒）
    func calculateAverageSpeed() -> Int64 {
        guard samples.count >= 2 else { return 0 }

        let totalBytes = samples.last!.bytes - samples.first!.bytes
        let totalTime = samples.last!.timestamp - samples.first!.timestamp

        guard totalTime > 0 else { return 0 }

        return Int64(Double(totalBytes) / totalTime)
    }

    /// 计算剩余时间
    func calculateRemainingTime(totalBytes: Int64, downloadedBytes: Int64) -> TimeInterval? {
        let speed = calculateSpeed()
        guard speed > 0 else { return nil }

        let remainingBytes = totalBytes - downloadedBytes
        guard remainingBytes > 0 else { return 0 }

        return TimeInterval(remainingBytes) / TimeInterval(speed)
    }

    /// 重置
    func reset() {
        samples.removeAll()
        lastBytes = 0
        lastTimestamp = 0
    }

    /// 格式化速度显示
    static func formatSpeed(_ bytesPerSecond: Int64) -> String {
        if bytesPerSecond < 1024 {
            return "\(bytesPerSecond) B/s"
        } else if bytesPerSecond < 1024 * 1024 {
            return String(format: "%.1f KB/s", Double(bytesPerSecond) / 1024.0)
        } else if bytesPerSecond < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB/s", Double(bytesPerSecond) / (1024.0 * 1024.0))
        } else {
            return String(format: "%.1f GB/s", Double(bytesPerSecond) / (1024.0 * 1024.0 * 1024.0))
        }
    }

    /// 格式化时间显示
    static func formatTime(_ seconds: TimeInterval?) -> String {
        guard let seconds = seconds, seconds > 0 else {
            return "计算中..."
        }

        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60

        if hours > 0 {
            return String(format: "%d小时%d分钟", hours, minutes)
        } else if minutes > 0 {
            return String(format: "%d分钟%d秒", minutes, secs)
        } else {
            return String(format: "%d秒", secs)
        }
    }
}
