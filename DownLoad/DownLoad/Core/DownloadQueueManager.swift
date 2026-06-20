//
//  DownloadQueueManager.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation
import Combine

/// 下载队列管理器
/// 负责管理下载任务的并发控制，限制同时运行的下载任务数量
actor DownloadQueueManager {

    // MARK: - Properties

    private var tasks: [UUID: any DownloadTask] = [:]
    private let maxConcurrentTasks: Int

    /// 当前正在运行的任务ID集合
    private var runningTaskIds: Set<UUID> = []

    /// 等待队列条目，包含任务ID和优先级
    private struct PendingQueueEntry {
        let taskId: UUID
        let priority: DownloadPriority
    }

    /// 等待执行的任务队列（按优先级排序，高优先级在前；同优先级按FIFO）
    private var pendingQueue: [PendingQueueEntry] = []

    init(maxConcurrentTasks: Int = Constants.Network.maxConcurrentDownloads) {
        self.maxConcurrentTasks = maxConcurrentTasks
    }

    /// 任务状态订阅存储，用于监听任务状态变化
    private var taskStateCancellables: [UUID: AnyCancellable] = [:]

    // MARK: - Public Methods

    /// 添加任务到队列
    /// 任务会被注册到队列中，并根据并发限制决定是否立即开始或进入等待状态
    func addTask(_ task: any DownloadTask) {
        let taskId = task.id

        // 避免重复添加
        guard tasks[taskId] == nil else {
            AppLogger.info("Task already exists in queue: \(taskId)")
            return
        }

        tasks[taskId] = task
        AppLogger.info("Task added to queue: \(taskId)")

        // 订阅任务状态变化，用于触发调度
        subscribeToTaskState(task)

        // 尝试启动任务（如果槽位未满则直接运行，否则进入等待队列）
        scheduleTask(taskId: taskId)
    }

    /// 移除任务
    /// 从队列中移除任务，释放占用的槽位，并触发调度
    func removeTask(_ taskId: UUID) {
        // 取消状态订阅
        taskStateCancellables[taskId]?.cancel()
        taskStateCancellables.removeValue(forKey: taskId)

        // 从运行集合和等待队列中移除
        runningTaskIds.remove(taskId)
        pendingQueue.removeAll { $0.taskId == taskId }

        tasks.removeValue(forKey: taskId)
        AppLogger.info("Task removed from queue: \(taskId)")

        // 触发调度，尝试启动等待队列中的任务
        processNextPendingTask()
    }

    /// 获取所有任务
    func getAllTasks() -> [any DownloadTask] {
        return Array(tasks.values)
    }

    /// 获取任务
    func getTask(by id: UUID) -> (any DownloadTask)? {
        return tasks[id]
    }

    /// 获取任务数量
    func taskCount() -> Int {
        return tasks.count
    }

    /// 获取当前正在运行的任务数量
    func runningTaskCount() -> Int {
        return runningTaskIds.count
    }

    /// 获取等待队列中的任务数量
    func pendingTaskCount() -> Int {
        return pendingQueue.count
    }

    /// 清空队列
    /// 取消所有任务，清理所有状态
    func clearAll() {
        // 取消所有状态订阅
        for cancellable in taskStateCancellables.values {
            cancellable.cancel()
        }
        taskStateCancellables.removeAll()

        runningTaskIds.removeAll()
        pendingQueue.removeAll()
        tasks.removeAll()

        AppLogger.info("All tasks cleared from queue")
    }

    // MARK: - Private Methods

    /// 订阅任务状态变化
    /// 当任务从 downloading 状态变为 completed/paused/failed/cancelled 时，释放槽位并调度下一个任务
    private func subscribeToTaskState(_ task: any DownloadTask) {
        let taskId = task.id

        let cancellable = task.state
            .dropFirst() // 跳过初始状态
            .receive(on: DispatchQueue.global(qos: .utility))
            .sink { [weak self] newState in
                guard let self = self else { return }

                Task {
                    await self.handleTaskStateChange(taskId: taskId, newState: newState)
                }
            }

        taskStateCancellables[taskId] = cancellable
    }

    /// 处理任务状态变化
    private func handleTaskStateChange(taskId: UUID, newState: DownloadState) {
        // 只有任务从 downloading 状态退出时才需要释放槽位
        let wasRunning = runningTaskIds.contains(taskId)

        switch newState {
        case .completed, .paused, .failed, .cancelled:
            if wasRunning {
                runningTaskIds.remove(taskId)
                AppLogger.info("Task \(taskId) finished with state: \(newState.rawValue), slot released. Running: \(runningTaskIds.count)/\(maxConcurrentTasks)")
                processNextPendingTask()
            }
        case .downloading:
            // 任务变为下载中，确保在运行集合中
            if tasks[taskId] != nil {
                runningTaskIds.insert(taskId)
            }
        case .pending:
            // 任务回到等待状态，从运行集合中移除
            if wasRunning {
                runningTaskIds.remove(taskId)
                processNextPendingTask()
            }
        }
    }

    /// 调度任务
    /// 如果当前运行任务数未达到上限，则直接启动；否则加入等待队列
    private func scheduleTask(taskId: UUID) {
        guard tasks[taskId] != nil else { return }

        // 检查是否已经在运行
        guard !runningTaskIds.contains(taskId) else { return }

        // 检查是否已经在等待队列
        guard !pendingQueue.contains(where: { $0.taskId == taskId }) else { return }

        if runningTaskIds.count < maxConcurrentTasks {
            // 有空闲槽位，启动任务
            startTask(taskId: taskId)
        } else {
            // 槽位已满，按优先级插入等待队列
            let priority = tasks[taskId]?.priority ?? .normal
            insertIntoPendingQueue(taskId: taskId, priority: priority)
        }
    }

    /// 按优先级插入等待队列（高优先级在前，同优先级FIFO）
    private func insertIntoPendingQueue(taskId: UUID, priority: DownloadPriority) {
        let newEntry = PendingQueueEntry(taskId: taskId, priority: priority)

        // 找到第一个优先级小于新条目的位置
        if let insertIndex = pendingQueue.firstIndex(where: { $0.priority < priority }) {
            pendingQueue.insert(newEntry, at: insertIndex)
        } else {
            pendingQueue.append(newEntry)
        }

        AppLogger.info("Task \(taskId) queued with priority \(priority). Queue position: \(pendingQueue.count), Running: \(runningTaskIds.count)/\(maxConcurrentTasks)")
    }

    /// 启动指定任务
    private func startTask(taskId: UUID) {
        guard let task = tasks[taskId] else { return }
        guard !runningTaskIds.contains(taskId) else { return }

        runningTaskIds.insert(taskId)
        AppLogger.info("Task \(taskId) started. Running: \(runningTaskIds.count)/\(maxConcurrentTasks)")

        // 异步启动任务，不阻塞当前 actor 方法
        Task {
            do {
                try await task.resume()
            } catch {
                AppLogger.error("Task \(taskId) failed to start: \(error)")
                // 启动失败时，任务状态会变为 failed，由状态订阅回调处理槽位释放
            }
        }
    }

    /// 处理等待队列中的下一个任务
    private func processNextPendingTask() {
        guard runningTaskIds.count < maxConcurrentTasks else { return }
        guard !pendingQueue.isEmpty else { return }

        // 取出等待队列中的第一个任务（已按优先级排序）
        let nextEntry = pendingQueue.removeFirst()
        let nextTaskId = nextEntry.taskId
        AppLogger.info("Processing next pending task: \(nextTaskId). Remaining in queue: \(pendingQueue.count)")

        startTask(taskId: nextTaskId)
    }
}
