# P0 任务3和任务4 修复计划

> **目标：** 修复 `deleteDownloadTask` 逻辑错误（任务3）和批量删除不清理已完成文件（任务4）

**当前状态分析：**
- `VideoDownloadEngine.deleteDownloadTask()` 中，先调用 `cancel()` 将状态改为 `.cancelled`，再检查 `state == .completed`，条件永远为 false，导致已完成文件永远不会被删除。
- `BatchDownloadManager.deleteBatchDownload()` 只调用 `cancelDownload()`，不删除已完成文件，导致存储泄漏。

**涉及文件：**
- `DownLoad/DownLoad/Core/VideoDownloadEngine.swift` - 修复 `deleteDownloadTask` 方法
- `DownLoad/DownLoad/Core/BatchDownloadManager.swift` - 修复 `deleteBatchDownload` 方法

---

## 任务1: 修复 `VideoDownloadEngine.deleteDownloadTask` 逻辑错误

**文件：** `DownLoad/DownLoad/Core/VideoDownloadEngine.swift`

**问题：** 先 `cancel()` 再检查 `.completed`，条件永远为 false

**修复方案：** 在取消前保存 `completedURL`，然后再执行取消和删除逻辑。

**修改内容（第98-114行）：**

```swift
/// 删除下载任务
func deleteDownloadTask(task: any DownloadTask) async {
    Logger.info("Deleting download task: \(task.id)")

    // 先保存 completedURL，因为 cancel() 会改变状态
    let completedURL = task.completedURL
    let isCompleted = task.state.value == .completed

    // 如果任务未完成，先取消
    if !isCompleted {
        await task.cancel()
    }

    // 从队列中移除任务
    await queueManager.removeTask(task.id)

    // 如果任务已完成，删除对应的文件
    if isCompleted, let url = completedURL {
        try? storageManager.deleteFile(at: url)
        Logger.info("Deleted completed file: \(url.path)")
    }
}
```

**验证步骤：**
1. 检查编译是否通过
2. 确认逻辑：已完成任务 → 删除文件；未完成任务 → 取消 + 从队列移除

---

## 任务2: 修复 `BatchDownloadManager.deleteBatchDownload` 不清理已完成文件

**文件：** `DownLoad/DownLoad/Core/BatchDownloadManager.swift`

**问题：** 只调用 `cancelDownload()`，不删除已完成文件

**修复方案：** 调用 `VideoDownloadEngine.shared.deleteDownloadTask()` 替代 `cancelDownload()`，确保已完成文件被清理。

**修改内容（第160-174行）：**

```swift
/// 删除批量下载
func deleteBatchDownload(batchId: UUID) async {
    guard let batchTask = batchTasks[batchId] else {
        return
    }

    Logger.info("Deleting batch download: \(batchTask.name)")

    // 删除所有任务（包括已完成文件的清理）
    for item in batchTask.taskItems {
        await VideoDownloadEngine.shared.deleteDownloadTask(task: item.task)
    }

    batchTasks.removeValue(forKey: batchId)
}
```

**验证步骤：**
1. 检查编译是否通过
2. 确认批量删除时会清理已完成文件

---

## 任务3: 更新缺陷修复记录

**文件：** `/Users/hubin/Desktop/MutiDownload/缺陷修复优先级排序.md`

**修改内容：**
将任务3和任务4的状态更新为已修复，并添加修复说明。

---

## 验证清单

- [ ] `VideoDownloadEngine.swift` 编译通过
- [ ] `BatchDownloadManager.swift` 编译通过
- [ ] 任务3：已完成任务的文件在删除时被正确清理
- [ ] 任务4：批量删除时已完成文件被正确清理
- [ ] 缺陷修复记录文件已更新
