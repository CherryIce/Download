//
//  DownloadQueueManager.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation

/// 下载队列管理器
actor DownloadQueueManager {

    private var tasks: [UUID: any DownloadTask] = [:]
    private let maxConcurrentTasks: Int = 3

    /// 添加任务到队列
    func addTask(_ task: any DownloadTask) {
        tasks[task.id] = task
        Logger.info("Task added to queue: \(task.id)")
    }

    /// 移除任务
    func removeTask(_ taskId: UUID) {
        tasks.removeValue(forKey: taskId)
        Logger.info("Task removed from queue: \(taskId)")
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

    /// 清空队列
    func clearAll() {
        tasks.removeAll()
        Logger.info("All tasks cleared from queue")
    }
}
