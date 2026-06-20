# P2 问题24修复计划：`DownloadQueueManager` 状态回调中 `@MainActor` 绕过 actor 隔离

## 摘要

`DownloadQueueManager` 是一个 `actor`，负责下载任务的并发控制（最大3个并行，FIFO等待队列）。在 `subscribeToTaskState` 方法中，状态回调通过 `Task { @MainActor in ... }` 将执行切换到主线程，绕过了 actor 隔离保护，导致 `handleTaskStateChange` 中对 actor 可变状态（`runningTaskIds`、`tasks`、`pendingQueue`）的读写不在 actor 的序列化 executor 上执行，存在潜在线程安全隐患。

## 当前状态分析

**问题代码位置：** `DownloadQueueManager.swift` 第 115-130 行

```swift
private func subscribeToTaskState(_ task: any DownloadTask) {
    let taskId = task.id
    let cancellable = task.state
        .dropFirst()
        .receive(on: DispatchQueue.global(qos: .utility))  // ① 全局后台队列接收
        .sink { [weak self] newState in
            guard let self = self else { return }
            Task { @MainActor in                                // ② 错误：切换到主线程
                await self.handleTaskStateChange(taskId: taskId, newState: newState)
            }
        }
    taskStateCancellables[taskId] = cancellable
}
```

**问题根因：**
1. `DownloadQueueManager` 是 `actor`，所有可变状态受 actor 隔离保护
2. `Task { @MainActor in ... }` 将 `handleTaskStateChange` 的执行切换到主线程而非 actor executor
3. `handleTaskStateChange` 直接读写 actor 的可变属性（`runningTaskIds`、`tasks`、`pendingQueue`），这些操作本应串行化在 actor 隔离域内
4. 虽然通过 `await self` 编译器会生成 actor hop，但 `@MainActor` 标注使整个闭包在 MainActor 上执行，`self` 是通过 `[weak self]` 捕获的非隔离引用，`handleTaskStateChange` 是 `private` 方法，在 `@MainActor` 上下文中调用时编译器不会强制 hop 到 actor executor
5. 队列管理器的状态回调与 UI 无关，不应绑定到主线程

**影响范围：**
- `DownloadQueueManager.swift` — 唯一需要修改的文件
- `VideoDownloadEngine.swift` — 调用方，无需修改（通过 `await` 调用，天然安全）
- `DownloadQueueManagerTests.swift` — 测试文件，验证修复后行为不变

## 修复方案

### 修改文件：`DownLoad/DownLoad/Core/DownloadQueueManager.swift`

**修改1：`subscribeToTaskState` 方法（第 115-130 行）**

将 `Task { @MainActor in ... }` 改为 `Task { ... }`，让 Swift 并发运行时自动 hop 回 actor 的 executor 执行 `handleTaskStateChange`：

```swift
private func subscribeToTaskState(_ task: any DownloadTask) {
    let taskId = task.id

    let cancellable = task.state
        .dropFirst()
        .receive(on: DispatchQueue.global(qos: .utility))
        .sink { [weak self] newState in
            guard let self = self else { return }

            Task {
                await self.handleTaskStateChange(taskId: taskId, newState: newState)
            }
        }

    taskStateCancellables[taskId] = cancellable
}
```

**变更要点：**
- 移除 `@MainActor` 标注
- `Task { await self.handleTaskStateChange(...) }` 会让 Swift 并发运行时自动将执行 hop 到 `DownloadQueueManager` actor 的 executor 上
- actor 隔离保证 `handleTaskStateChange` 中对可变状态的访问是串行化的
- 状态回调逻辑与 UI 无关，不需要在主线程执行

### 修改文件：`缺陷修复优先级排序.md`

修复完成后，将问题24标记为已修复，添加修复记录。

## 假设与决策

1. **不修改 `receive(on:)` 的调度队列**：`DispatchQueue.global(qos: .utility)` 用于 Combine 管道的下游处理，与 actor 隔离无关，保持不变
2. **不修改 `handleTaskStateChange` 方法本身**：该方法逻辑正确，只需确保它在 actor executor 上执行
3. **不修改 `VideoDownloadEngine`**：它通过 `await` 调用 `DownloadQueueManager` 的 public 方法，天然安全

## 验证步骤

1. **编译验证**：`xcodebuild build` 确保编译通过，无警告
2. **单元测试**：运行 `DownloadQueueManagerTests` 的 12 个测试用例，确保全部通过
3. **行为验证**：确认修复后队列调度行为不变——任务完成/暂停/取消/失败后自动触发等待队列调度
4. **记录更新**：在 `缺陷修复优先级排序.md` 中标记问题24为已修复
