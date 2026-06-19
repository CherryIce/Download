//
//  DownloadQueueManagerTests.swift
//  DownLoadTests
//
//  Created by hubin on 2026/6/19.
//

import Testing
import Foundation
import Combine
@testable import DownLoad

// MARK: - Mock Download Task

/// 模拟下载任务，用于测试并发控制逻辑
class MockDownloadTask: DownloadTask {
    let id: UUID
    let url: String
    let fileName: String
    let configuration: DownloadConfiguration
    let state: CurrentValueSubject<DownloadState, Never>
    let progress: CurrentValueSubject<DownloadProgress, Never>
    var completedURL: URL?
    
    let format: VideoFormat = .mp4
    var totalSize: Int64?
    var downloadedSize: Int64 = 0
    let createdAt: Date = Date()
    var completedAt: Date?
    var resumeData: Data?
    
    private var shouldFail: Bool
    private var delay: TimeInterval
    
    init(
        id: UUID = UUID(),
        url: String = "https://example.com/test.mp4",
        fileName: String = "test.mp4",
        shouldFail: Bool = false,
        delay: TimeInterval = 0.1
    ) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.configuration = .default
        self.state = CurrentValueSubject<DownloadState, Never>(.pending)
        self.progress = CurrentValueSubject<DownloadProgress, Never>(.empty)
        self.completedURL = nil
        self.shouldFail = shouldFail
        self.delay = delay
    }
    
    func resume() async throws {
        state.send(.downloading)
        
        // 模拟下载耗时
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        
        if shouldFail {
            state.send(.failed)
            throw DownloadError.taskFailed(NSError(domain: "Mock", code: -1))
        } else {
            state.send(.completed)
        }
    }
    
    func pause() async {
        state.send(.paused)
    }
    
    func cancel() async {
        state.send(.cancelled)
    }
}

// MARK: - Test Suite

@Suite("DownloadQueueManager 并发控制测试")
struct DownloadQueueManagerTests {
    
    // MARK: - Helper
    
    private func createQueueManager() -> DownloadQueueManager {
        return DownloadQueueManager()
    }
    
    private func createMockTasks(count: Int) -> [MockDownloadTask] {
        return (0..<count).map { index in
            MockDownloadTask(
                id: UUID(),
                url: "https://example.com/test\(index).mp4",
                fileName: "test\(index).mp4",
                delay: 0.2
            )
        }
    }
    
    // MARK: - 基础功能测试
    
    @Test("添加任务后任务数量正确")
    func testAddTaskIncreasesCount() async throws {
        let queueManager = createQueueManager()
        let task = MockDownloadTask()
        
        await queueManager.addTask(task)
        
        let count = await queueManager.taskCount()
        #expect(count == 1)
    }
    
    @Test("移除任务后任务数量正确")
    func testRemoveTaskDecreasesCount() async throws {
        let queueManager = createQueueManager()
        let task = MockDownloadTask()
        
        await queueManager.addTask(task)
        await queueManager.removeTask(task.id)
        
        let count = await queueManager.taskCount()
        #expect(count == 0)
    }
    
    @Test("重复添加同一任务不会重复计数")
    func testDuplicateAddTaskIgnored() async throws {
        let queueManager = createQueueManager()
        let task = MockDownloadTask()
        
        await queueManager.addTask(task)
        await queueManager.addTask(task)
        
        let count = await queueManager.taskCount()
        #expect(count == 1)
    }
    
    @Test("清空队列后任务数量为零")
    func testClearAllRemovesAllTasks() async throws {
        let queueManager = createQueueManager()
        let tasks = createMockTasks(count: 3)
        
        for task in tasks {
            await queueManager.addTask(task)
        }
        
        await queueManager.clearAll()
        
        let count = await queueManager.taskCount()
        #expect(count == 0)
    }
    
    // MARK: - 并发控制核心测试
    
    @Test("添加不超过最大并发数的任务应立即运行")
    func testAddTaskUnderLimitStartsImmediately() async throws {
        let queueManager = createQueueManager()
        let tasks = createMockTasks(count: 3)
        
        for task in tasks {
            await queueManager.addTask(task)
        }
        
        // 等待调度完成
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
        
        let runningCount = await queueManager.runningTaskCount()
        let pendingCount = await queueManager.pendingTaskCount()
        
        #expect(runningCount == 3, "应有3个任务在运行")
        #expect(pendingCount == 0, "等待队列应为空")
    }
    
    @Test("添加超过最大并发数的任务应进入等待队列")
    func testAddTaskOverLimitQueuesPending() async throws {
        let queueManager = createQueueManager()
        let tasks = createMockTasks(count: 5)
        
        for task in tasks {
            await queueManager.addTask(task)
        }
        
        // 等待调度完成
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
        
        let runningCount = await queueManager.runningTaskCount()
        let pendingCount = await queueManager.pendingTaskCount()
        
        #expect(runningCount == 3, "应有3个任务在运行")
        #expect(pendingCount == 2, "应有2个任务在等待")
    }
    
    @Test("并发数始终不超过上限")
    func testConcurrentLimitNeverExceeded() async throws {
        let queueManager = createQueueManager()
        let tasks = createMockTasks(count: 10)
        
        for task in tasks {
            await queueManager.addTask(task)
        }
        
        // 等待调度完成
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
        
        let runningCount = await queueManager.runningTaskCount()
        
        #expect(runningCount <= 3, "运行任务数不应超过上限3")
    }
    
    // MARK: - 自动调度测试
    
    @Test("任务完成后应自动调度等待队列中的任务")
    func testTaskCompletionTriggersNextPending() async throws {
        let queueManager = createQueueManager()
        let tasks = createMockTasks(count: 4)
        
        for task in tasks {
            await queueManager.addTask(task)
        }
        
        // 等待初始调度完成
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
        
        // 验证初始状态
        let initialRunningCount = await queueManager.runningTaskCount()
        let initialPendingCount = await queueManager.pendingTaskCount()
        #expect(initialRunningCount == 3)
        #expect(initialPendingCount == 1)
        
        // 等待第一个任务完成（模拟任务会在0.2秒后完成）
        try await Task.sleep(nanoseconds: 300_000_000) // 0.3秒
        
        // 验证调度结果
        let finalRunningCount = await queueManager.runningTaskCount()
        let finalPendingCount = await queueManager.pendingTaskCount()
        
        #expect(finalRunningCount <= 3, "运行任务数不应超过上限")
        #expect(finalPendingCount == 0, "等待队列应为空")
    }
    
    @Test("任务暂停后应自动调度等待队列中的任务")
    func testTaskPauseTriggersNextPending() async throws {
        let queueManager = createQueueManager()
        let tasks = createMockTasks(count: 4)
        
        for task in tasks {
            await queueManager.addTask(task)
        }
        
        // 等待初始调度完成
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
        
        // 验证初始状态
        let initialRunningCount = await queueManager.runningTaskCount()
        let initialPendingCount = await queueManager.pendingTaskCount()
        #expect(initialRunningCount == 3)
        #expect(initialPendingCount == 1)
        
        // 暂停第一个运行的任务
        await tasks[0].pause()
        
        // 等待调度完成
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2秒
        
        // 验证调度结果
        let finalRunningCount = await queueManager.runningTaskCount()
        let finalPendingCount = await queueManager.pendingTaskCount()
        
        #expect(finalRunningCount <= 3, "运行任务数不应超过上限")
        #expect(finalPendingCount == 0, "等待队列应为空")
    }
    
    @Test("任务取消后应自动调度等待队列中的任务")
    func testTaskCancelTriggersNextPending() async throws {
        let queueManager = createQueueManager()
        let tasks = createMockTasks(count: 4)
        
        for task in tasks {
            await queueManager.addTask(task)
        }
        
        // 等待初始调度完成
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
        
        // 验证初始状态
        let initialRunningCount = await queueManager.runningTaskCount()
        let initialPendingCount = await queueManager.pendingTaskCount()
        #expect(initialRunningCount == 3)
        #expect(initialPendingCount == 1)
        
        // 取消第一个运行的任务
        await tasks[0].cancel()
        
        // 等待调度完成
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2秒
        
        // 验证调度结果
        let finalRunningCount = await queueManager.runningTaskCount()
        let finalPendingCount = await queueManager.pendingTaskCount()
        
        #expect(finalRunningCount <= 3, "运行任务数不应超过上限")
        #expect(finalPendingCount == 0, "等待队列应为空")
    }
    
    @Test("任务失败后应自动调度等待队列中的任务")
    func testTaskFailureTriggersNextPending() async throws {
        let queueManager = createQueueManager()
        
        // 创建3个正常任务和1个会失败的任务
        let failingTask = MockDownloadTask(shouldFail: true, delay: 0.1)
        let normalTasks = createMockTasks(count: 3)
        
        // 先添加会失败的任务，再添加正常任务
        await queueManager.addTask(failingTask)
        for task in normalTasks {
            await queueManager.addTask(task)
        }
        
        // 等待初始调度完成
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
        
        // 验证初始状态
        let initialRunningCount = await queueManager.runningTaskCount()
        let initialPendingCount = await queueManager.pendingTaskCount()
        #expect(initialRunningCount == 3)
        #expect(initialPendingCount == 1)
        
        // 等待失败任务完成（会在0.1秒后失败）
        try await Task.sleep(nanoseconds: 300_000_000) // 0.3秒
        
        // 验证调度结果
        let finalRunningCount = await queueManager.runningTaskCount()
        let finalPendingCount = await queueManager.pendingTaskCount()
        
        #expect(finalRunningCount <= 3, "运行任务数不应超过上限")
        #expect(finalPendingCount == 0, "等待队列应为空")
    }
    
    // MARK: - 边界情况测试
    
    @Test("移除等待队列中的任务不会触发调度")
    func testRemovePendingTaskDoesNotTriggerSchedule() async throws {
        let queueManager = createQueueManager()
        let tasks = createMockTasks(count: 5)
        
        for task in tasks {
            await queueManager.addTask(task)
        }
        
        // 等待初始调度完成
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
        
        // 移除一个等待队列中的任务（第5个任务）
        await queueManager.removeTask(tasks[4].id)
        
        let runningCount = await queueManager.runningTaskCount()
        let pendingCount = await queueManager.pendingTaskCount()
        let taskCount = await queueManager.taskCount()
        
        #expect(runningCount == 3, "运行任务数应保持3")
        #expect(pendingCount == 1, "等待队列应剩1个")
        #expect(taskCount == 4, "总任务数应为4")
    }
    
    @Test("空队列添加任务应立即启动")
    func testAddTaskToEmptyQueueStartsImmediately() async throws {
        let queueManager = createQueueManager()
        let task = MockDownloadTask()
        
        await queueManager.addTask(task)
        
        // 等待调度完成
        try await Task.sleep(nanoseconds: 50_000_000) // 0.05秒
        
        let runningCount = await queueManager.runningTaskCount()
        let pendingCount = await queueManager.pendingTaskCount()
        
        #expect(runningCount == 1, "应有1个任务在运行")
        #expect(pendingCount == 0, "等待队列应为空")
    }
    
    @Test("大量任务添加后并发数始终受控")
    func testMassiveTasksConcurrentLimit() async throws {
        let queueManager = createQueueManager()
        let tasks = createMockTasks(count: 20)
        
        for task in tasks {
            await queueManager.addTask(task)
        }
        
        // 等待调度完成
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
        
        let runningCount = await queueManager.runningTaskCount()
        let pendingCount = await queueManager.pendingTaskCount()
        
        #expect(runningCount == 3, "应有3个任务在运行")
        #expect(pendingCount == 17, "应有17个任务在等待")
    }
}
