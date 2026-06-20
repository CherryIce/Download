//
//  SpeedCalculatorTests.swift
//  DownLoadTests
//
//  Created by hubin on 2026/6/19.
//

import Testing
import Foundation
@testable import DownLoad

@Suite("SpeedCalculator 速度计算器测试")
struct SpeedCalculatorTests {

    // MARK: - 速度计算测试

    @Test("添加样本后速度计算正确")
    func testAddSampleAndCalculateSpeed() {
        let calculator = SpeedCalculator()

        // 模拟：0秒时下载0字节，1秒时下载1024字节，2秒时下载3072字节
        calculator.addSample(bytes: 0, timestamp: 0)
        calculator.addSample(bytes: 1024, timestamp: 1)
        calculator.addSample(bytes: 3072, timestamp: 2)

        // 速度 = (3072 - 0) / (2 - 0) = 1536 bytes/s
        let speed = calculator.calculateSpeed()
        #expect(speed == 1536, "速度应为 1536 bytes/s，实际为 \(speed)")
    }

    @Test("单个样本返回零速度")
    func testSingleSampleReturnsZero() {
        let calculator = SpeedCalculator()

        calculator.addSample(bytes: 1024, timestamp: 1)

        let speed = calculator.calculateSpeed()
        #expect(speed == 0, "单个样本应返回 0 速度")
    }

    @Test("两个相同时刻的样本返回零速度")
    func testSameTimestampReturnsZero() {
        let calculator = SpeedCalculator()

        calculator.addSample(bytes: 0, timestamp: 1.0)
        calculator.addSample(bytes: 1024, timestamp: 1.0)

        let speed = calculator.calculateSpeed()
        #expect(speed == 0, "相同时刻的样本应返回 0 速度")
    }

    @Test("速度不会为负数")
    func testSpeedIsNeverNegative() {
        let calculator = SpeedCalculator()

        // 模拟异常情况：后一个样本字节数小于前一个
        calculator.addSample(bytes: 5000, timestamp: 0)
        calculator.addSample(bytes: 3000, timestamp: 1)

        let speed = calculator.calculateSpeed()
        #expect(speed >= 0, "速度不应为负数")
    }

    // MARK: - 平均速度测试

    @Test("平均速度计算正确")
    func testCalculateAverageSpeed() {
        let calculator = SpeedCalculator()

        calculator.addSample(bytes: 0, timestamp: 0)
        calculator.addSample(bytes: 5000, timestamp: 5)

        let avgSpeed = calculator.calculateAverageSpeed()
        #expect(avgSpeed == 1000, "平均速度应为 1000 bytes/s，实际为 \(avgSpeed)")
    }

    // MARK: - 剩余时间测试

    @Test("剩余时间计算正确")
    func testCalculateRemainingTime() {
        let calculator = SpeedCalculator()

        calculator.addSample(bytes: 0, timestamp: 0)
        calculator.addSample(bytes: 1000, timestamp: 1) // 速度 = 1000 bytes/s

        // 总共 5000 字节，已下载 1000 字节，剩余 4000 字节
        // 预计剩余时间 = 4000 / 1000 = 4 秒
        let remaining = calculator.calculateRemainingTime(totalBytes: 5000, downloadedBytes: 1000)
        #expect(remaining != nil, "剩余时间不应为 nil")
        #expect(remaining! == 4.0, "剩余时间应为 4.0 秒，实际为 \(remaining!)")
    }

    @Test("已下载完成时剩余时间为零")
    func testRemainingTimeZeroWhenComplete() {
        let calculator = SpeedCalculator()

        calculator.addSample(bytes: 0, timestamp: 0)
        calculator.addSample(bytes: 5000, timestamp: 5)

        let remaining = calculator.calculateRemainingTime(totalBytes: 5000, downloadedBytes: 5000)
        #expect(remaining == 0, "已下载完成时剩余时间应为 0")
    }

    @Test("速度为零时剩余时间为 nil")
    func testRemainingTimeNilWhenNoSpeed() {
        let calculator = SpeedCalculator()

        // 只有一个样本，速度为 0
        calculator.addSample(bytes: 100, timestamp: 1)

        let remaining = calculator.calculateRemainingTime(totalBytes: 5000, downloadedBytes: 100)
        #expect(remaining == nil, "速度为零时剩余时间应为 nil")
    }

    // MARK: - 样本限制测试

    @Test("样本数量不超过最大限制")
    func testSampleCountLimit() {
        let calculator = SpeedCalculator()

        // 添加超过 maxSamples(10) 的样本
        for i in 0..<15 {
            calculator.addSample(bytes: Int64(i * 100), timestamp: Double(i))
        }

        // 速度应基于最近的10个样本计算
        // 最旧样本: index 5, bytes=500, time=5
        // 最新样本: index 14, bytes=1400, time=14
        let speed = calculator.calculateSpeed()
        let expectedSpeed = Int64((1400 - 500) / (14 - 5)) // 100
        #expect(speed == expectedSpeed, "速度应基于滑动窗口计算，期望 \(expectedSpeed)，实际 \(speed)")
    }

    // MARK: - 重置测试

    @Test("重置后样本清空")
    func testResetClearsSamples() {
        let calculator = SpeedCalculator()

        calculator.addSample(bytes: 1000, timestamp: 1)
        calculator.addSample(bytes: 2000, timestamp: 2)

        calculator.reset()

        let speed = calculator.calculateSpeed()
        #expect(speed == 0, "重置后速度应为 0")
    }

    // MARK: - 格式化测试

    @Test("格式化速度 - B/s")
    func testFormatSpeedBytes() {
        let formatted = SpeedCalculator.formatSpeed(512)
        #expect(formatted == "512 B/s", "512 bytes/s 应格式化为 '512 B/s'，实际为 '\(formatted)'")
    }

    @Test("格式化速度 - KB/s")
    func testFormatSpeedKB() {
        let formatted = SpeedCalculator.formatSpeed(1536) // 1.5 KB
        #expect(formatted == "1.5 KB/s", "1536 bytes/s 应格式化为 '1.5 KB/s'，实际为 '\(formatted)'")
    }

    @Test("格式化速度 - MB/s")
    func testFormatSpeedMB() {
        let formatted = SpeedCalculator.formatSpeed(1_048_576) // 1 MB
        #expect(formatted == "1.0 MB/s", "1MB/s 应格式化为 '1.0 MB/s'，实际为 '\(formatted)'")
    }

    @Test("格式化速度 - GB/s")
    func testFormatSpeedGB() {
        let formatted = SpeedCalculator.formatSpeed(1_073_741_824) // 1 GB
        #expect(formatted == "1.0 GB/s", "1GB/s 应格式化为 '1.0 GB/s'，实际为 '\(formatted)'")
    }

    @Test("格式化时间 - 秒")
    func testFormatTimeSeconds() {
        let formatted = SpeedCalculator.formatTime(45)
        #expect(formatted == "45秒", "45秒应格式化为 '45秒'，实际为 '\(formatted)'")
    }

    @Test("格式化时间 - 分钟秒")
    func testFormatTimeMinutes() {
        let formatted = SpeedCalculator.formatTime(125) // 2分5秒
        #expect(formatted == "2分钟5秒", "125秒应格式化为 '2分钟5秒'，实际为 '\(formatted)'")
    }

    @Test("格式化时间 - 小时分钟")
    func testFormatTimeHours() {
        let formatted = SpeedCalculator.formatTime(3725) // 1小时2分5秒
        #expect(formatted == "1小时2分钟", "3725秒应格式化为 '1小时2分钟'，实际为 '\(formatted)'")
    }

    @Test("格式化时间 - nil 返回计算中")
    func testFormatTimeNil() {
        let formatted = SpeedCalculator.formatTime(nil)
        #expect(formatted == "计算中...", "nil 应格式化为 '计算中...'，实际为 '\(formatted)'")
    }

    @Test("格式化时间 - 零返回计算中")
    func testFormatTimeZero() {
        let formatted = SpeedCalculator.formatTime(0)
        #expect(formatted == "计算中...", "0秒应格式化为 '计算中...'，实际为 '\(formatted)'")
    }

    @Test("M3U8 进度使用字节而非片段计数")
    func testM3U8ByteProgress() {
        let calculator = SpeedCalculator()

        // 模拟下载 3 个片段，每个 1MB
        calculator.addSample(bytes: 0, timestamp: 0)
        calculator.addSample(bytes: 3_145_728, timestamp: 3)  // 3MB in 3s

        let speed = calculator.calculateSpeed()
        #expect(speed == 1_048_576, "速度应为 1MB/s，实际为 \(speed)")
    }

    // MARK: - 线程安全测试

    @Test("并发 addSample 和 calculateSpeed 不崩溃")
    func testConcurrentAccessDoesNotCrash() throws {
        let calculator = SpeedCalculator()
        let iterationCount = 1000

        try withThrowingTaskGroup(of: Void.self) { group in
            // 多个并发写入任务
            for i in 0..<10 {
                group.addTask {
                    for j in 0..<iterationCount {
                        let bytes = Int64(i * iterationCount + j) * 100
                        calculator.addSample(bytes: bytes, timestamp: Double(i * iterationCount + j) * 0.001)
                    }
                }
            }
            // 多个并发读取任务
            for _ in 0..<5 {
                group.addTask {
                    for _ in 0..<iterationCount {
                        let _ = calculator.calculateSpeed()
                        let _ = calculator.calculateAverageSpeed()
                    }
                }
            }
            // 并发重置任务
            for _ in 0..<2 {
                group.addTask {
                    for _ in 0..<100 {
                        calculator.reset()
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    @Test("calculateAverageSpeed 与 calculateSpeed 结果一致")
    func testAverageSpeedMatchesSpeed() {
        let calculator = SpeedCalculator()

        calculator.addSample(bytes: 0, timestamp: 0)
        calculator.addSample(bytes: 5000, timestamp: 5)

        let speed = calculator.calculateSpeed()
        let avgSpeed = calculator.calculateAverageSpeed()
        #expect(speed == avgSpeed, "平均速度应与当前速度一致，speed=\(speed)，avgSpeed=\(avgSpeed)")
    }
}
