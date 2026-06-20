# Issue 35 修复计划：并发数硬编码 + 优先级机制

## Summary

修复 P3 问题 35："并发数硬编码，无优先级机制"。将 `DownloadQueueManager` 的并发数从硬编码的 `3` 改为可配置（从 `SettingsViewController` 读取用户设置），并引入任务优先级机制（高/中/低），使等待队列按优先级调度而非纯 FIFO。

## Current State Analysis

| 文件 | 问题 |
|---|---|
| `DownloadQueueManager.swift` 第18行 | `maxConcurrentTasks` 硬编码为 `3` |
| `DownloadQueueManager.swift` 第24行 | `pendingQueue: [UUID]` 纯 FIFO，无优先级 |
| `SettingsViewController.swift` 第69-72行 | 已有 `getMaxConcurrentDownloads()` 从 UserDefaults 读取，但 `DownloadQueueManager` 从未使用 |
| `Constants.swift` 第15行 | `maxConcurrentDownloads = 5` 存在但未被 `QueueManager` 使用 |
| `DownloadConfiguration.swift` | 有 `maxConcurrentDownloads` 字段，但 `QueueManager` 忽略 |
| `DownloadTaskProtocol.swift` | 协议无 `priority` 属性 |
| `MP4DownloadTask` / `M3U8DownloadTask` | 未实现优先级 |
| `DownloadQueueManagerTests.swift` | 多处硬编码断言 `3`，且缺少优先级测试 |

## Proposed Changes

### 1. 新建 `DownloadPriority` 枚举

**文件**: `DownLoad/DownLoad/Models/DownloadPriority.swift`（新建）

```swift
import Foundation

enum DownloadPriority: Int, Codable, Comparable, CaseIterable {
    case low = 0
    case normal = 1
    case high = 2

    static func < (lhs: DownloadPriority, rhs: DownloadPriority) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}
```

### 2. `DownloadTask` 协议添加 `priority` 属性

**文件**: `DownLoad/DownLoad/Core/DownloadTaskProtocol.swift`

在协议体中新增：`var priority: DownloadPriority { get set }`

### 3. `MP4DownloadTask` 实现 `priority`

**文件**: `DownLoad/DownLoad/Handlers/MP4DownloadHandler.swift`

- 在 `MP4DownloadTask` 类中新增 `var priority: DownloadPriority = .normal`
- `init` 增加 `priority: DownloadPriority = .normal` 参数并赋值

### 4. `M3U8DownloadTask` 实现 `priority`

**文件**: `DownLoad/DownLoad/Handlers/M3U8DownloadHandler.swift`

- 在 `M3U8DownloadTask` 类中新增 `var priority: DownloadPriority = .normal`
- `init` 增加 `priority: DownloadPriority = .normal` 参数并赋值

### 5. 重构 `DownloadQueueManager`

**文件**: `DownLoad/DownLoad/Core/DownloadQueueManager.swift`

- 将 `private let maxConcurrentTasks: Int = 3` 改为 `private let maxConcurrentTasks: Int`
- 新增 `init(maxConcurrentTasks: Int = Constants.Network.maxConcurrentDownloads)`
- 引入内部结构 `PendingQueueEntry`（含 `taskId` 和 `priority`）
- `pendingQueue` 从 `[UUID]` 改为 `[PendingQueueEntry]`
- 新增 `insertIntoPendingQueue(taskId:priority:)` 方法，按优先级降序插入（同优先级 FIFO）
- 修改 `removeTask`、`processNextPendingTask` 中所有访问 `pendingQueue` 的逻辑适配新结构

### 6. `VideoDownloadEngine` 传递并发数配置

**文件**: `DownLoad/DownLoad/Core/VideoDownloadEngine.swift`

- `private init()` 中：`self.queueManager = DownloadQueueManager(maxConcurrentTasks: SettingsViewController.getMaxConcurrentDownloads())`

### 7. 更新测试

**文件**: `DownLoad/DownLoadTests/DownloadQueueManagerTests.swift`

- `MockDownloadTask` 添加 `var priority: DownloadPriority = .normal` 和 `init` 参数
- `createQueueManager()` 改为 `createQueueManager(maxConcurrent: Int = Constants.Network.maxConcurrentDownloads)`
- 所有硬编码 `3` 的断言替换为 `maxConcurrent` 变量
- 新增 `DownloadQueueManagerPriorityTests` Suite，包含4个优先级测试：
  - `testHighPriorityTaskRunsBeforeLow`
  - `testSamePriorityFIFOOrder`
  - `testPrioritySchedulingAfterCompletion`
  - `testPrioritySchedulingAfterRemoval`

## Assumptions & Decisions

- `DownloadPriority` 使用 `Int` rawValue 便于排序和后续持久化，但本次不涉及数据库 schema 变更（最小改动原则）。
- 优先级默认 `.normal`，确保所有现有代码向后兼容。
- 并发数默认值使用 `Constants.Network.maxConcurrentDownloads`（5），与 `SettingsViewController` 的兜底逻辑一致。
- 同优先级任务保持 FIFO 顺序，通过 `firstIndex(where:)` 查找插入位置实现。
- `priority` 为 `var` 属性，允许运行时动态调整（虽然本次不实现动态调整 UI）。

## Verification Steps

1. 编译通过，无 Swift 编译错误。
2. 所有现有测试通过（并发控制测试）。
3. 新增优先级测试全部通过。
4. 设置页面修改并发数后，重启 App 生效。
5. 批量下载功能不受影响。
6. 任务恢复功能不受影响（恢复的任务默认 `.normal` 优先级）。
