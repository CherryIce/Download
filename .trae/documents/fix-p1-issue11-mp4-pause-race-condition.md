# P1 问题11：MP4 暂停时序竞态修复计划

> **Goal:** 修复 `MP4DownloadTask.pause()` 中前台下载模式的时序竞态，确保暂停时 resumeData 正确保存且状态不混乱。

**Architecture:** 通过引入显式的暂停意图状态机，区分"暂停导致的取消"和"真正的取消/失败"，避免竞态条件下状态错误。

**Tech Stack:** Swift, Combine, URLSession

---

## Summary

在 `MP4DownloadTask.pause()` 方法中，前台下载模式存在时序竞态：
- `handle.cancelWithResumeData()` 调用 `urlSessionTask.cancel(byProducingResumeData:)` 取消 URLSession 下载任务
- 这会导致 `DownloadDelegate.didCompleteWithError` 被调用，`downloadFileWithResumeCancellable` 抛出 `NSURLErrorCancelled` 错误
- 前台下载 Task 进入 catch 块，可能发送 `.failed` 或 `.cancelled` 状态
- 与 `pause()` 最后发送的 `.paused` 状态冲突

修复方案：添加 `terminationReason` 状态机，在 Task 内部根据暂停/取消意图正确处理错误，避免状态混乱。

---

## Current State Analysis

### 涉及文件
- `/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/Handlers/MP4DownloadHandler.swift`（主要修改）

### 问题代码位置
- `MP4DownloadTask.pause()` 第352-377行
- `MP4DownloadTask.resumeWithForegroundDownload()` 第127-191行
- `MP4DownloadTask.resumeWithBackgroundDownload()` 第195-350行

### 竞态场景
1. 用户点击暂停，调用 `pause()`
2. `handle.cancelWithResumeData()` 取消 URLSessionDownloadTask
3. `DownloadDelegate.didCompleteWithError` 被调用，恢复 `downloadFileWithResumeCancellable` 的 continuation 并抛出错误
4. 前台下载 Task 进入 catch 块，发送 `.failed` 状态
5. `pause()` 最后发送 `.paused` 状态覆盖
6. 结果：UI 可能先显示失败再显示暂停，且 resumeData 获取可能受影响

---

## Proposed Changes

### Task 1: 添加终止原因状态机

**Files:**
- Modify: `/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/Handlers/MP4DownloadHandler.swift`

在 `MP4DownloadTask` 类中添加：

```swift
/// 任务终止原因，用于区分暂停、取消和真正的失败
private enum TaskTerminationReason {
    case none
    case pauseRequested
    case cancelRequested
}

private var terminationReason: TaskTerminationReason = .none
```

位置：在 `private var backgroundDownloadTask: URLSessionDownloadTask?` 之后添加。

---

### Task 2: 修改 pause() 方法

**Files:**
- Modify: `/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/Handlers/MP4DownloadHandler.swift`

将 `pause()` 方法（第352-377行）修改为：

```swift
func pause() async {
    terminationReason = .pauseRequested
    defer { terminationReason = .none }

    if useBackgroundDownload {
        // 后台模式：通过 BackgroundDownloadSession 取消并获取 resumeData
        if let bgTask = backgroundDownloadTask {
            let data = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                BackgroundDownloadSession.shared.cancelTask(bgTask) { resumeData in
                    continuation.resume(returning: resumeData)
                }
            }
            resumeData = data
            Logger.info("MP4 background download paused, resumeData saved (\(data?.count ?? 0) bytes)")
        }
        backgroundDownloadTask = nil
    } else {
        // 前台模式：通过句柄调用 cancel(byProducingResumeData:) 获取 resumeData
        if let handle = downloadHandle {
            let data = await handle.cancelWithResumeData()
            resumeData = data
            Logger.info("MP4 download paused, resumeData saved (\(data?.count ?? 0) bytes)")
        }
        downloadHandle = nil
    }

    task?.cancel()
    speedCalculator.reset()
    state.send(.paused)
}
```

说明：在方法开头设置 `terminationReason = .pauseRequested`，方法结束时通过 `defer` 重置。这样前台/后台下载 Task 在 catch 块中可以判断取消是由暂停引起的。

---

### Task 3: 修改 cancel() 方法

**Files:**
- Modify: `/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/Handlers/MP4DownloadHandler.swift`

将 `cancel()` 方法（第379-402行）修改为：

```swift
func cancel() async {
    terminationReason = .cancelRequested
    defer { terminationReason = .none }

    // 取消时清除 resumeData（不保留恢复能力）
    resumeData = nil

    if useBackgroundDownload {
        // 后台模式：取消后台任务
        if let bgTask = backgroundDownloadTask {
            BackgroundDownloadSession.shared.cancelTask(bgTask) { _ in }
        }
        backgroundDownloadTask = nil
    } else {
        // 前台模式
        downloadHandle = nil
    }

    task?.cancel()
    speedCalculator.reset()

    // 清理临时文件
    let tempDirectory = storageManager.createTaskDirectory(taskId: id)
    try? storageManager.deleteFile(at: tempDirectory)

    state.send(.cancelled)
}
```

说明：同样设置 `terminationReason = .cancelRequested`，让 Task 内部知道这是取消操作。

---

### Task 4: 修改前台下载错误处理

**Files:**
- Modify: `/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/Handlers/MP4DownloadHandler.swift`

将 `resumeWithForegroundDownload()` 中的 catch 块（第180-187行）修改为：

```swift
            } catch is CancellationError {
                // Task 被取消（来自 cancel() 调用）
                if self.terminationReason != .pauseRequested {
                    state.send(.cancelled)
                }
                // 如果是暂停导致的取消，不发送状态（pause() 会发送 .paused）
            } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
                // URLSession 任务被取消（来自 pause() 的 cancelWithResumeData）
                if self.terminationReason != .pauseRequested {
                    state.send(.cancelled)
                }
                // 如果是暂停导致的取消，不发送状态（pause() 会发送 .paused）
            } catch {
                Logger.error("MP4 download failed: \(error)")
                state.send(.failed)
                throw DownloadError.taskFailed(error)
            }
```

说明：
- `CancellationError`：Swift Task 被取消时抛出
- `NSURLErrorCancelled`：URLSession 任务被取消时抛出
- 两种情况都检查 `terminationReason`，如果是暂停导致的则不发送状态

---

### Task 5: 修改后台下载错误处理

**Files:**
- Modify: `/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/Handlers/MP4DownloadHandler.swift`

将 `resumeWithBackgroundDownload()` 中的 catch 块（第339-346行）修改为：

```swift
            } catch is CancellationError {
                // Task 被取消（来自 cancel() 调用）
                if self.terminationReason != .pauseRequested {
                    state.send(.cancelled)
                }
                // 如果是暂停导致的取消，不发送状态（pause() 会发送 .paused）
            } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
                // URLSession 后台任务被取消
                if self.terminationReason != .pauseRequested {
                    state.send(.cancelled)
                }
                // 如果是暂停导致的取消，不发送状态（pause() 会发送 .paused）
            } catch {
                Logger.error("MP4 background download failed: \(error)")
                state.send(.failed)
                throw DownloadError.taskFailed(error)
            }
```

---

## Assumptions & Decisions

1. **假设 `pause()` 和 `cancel()` 不会被并发调用**：`terminationReason` 是简单变量，如果两个方法同时执行可能出现竞态。但基于当前调用模式（UI 按钮触发），这种并发不太可能发生。

2. **使用 `defer` 重置状态**：确保无论方法如何退出（正常返回或异常），`terminationReason` 都会被重置。

3. **不修改 `ResumableDownloadHandle`**：`cancelWithResumeData()` 的实现是正确的，问题出在调用方和 Task 生命周期的协调上。

4. **保持向后兼容**：修改后的代码与现有调用方完全兼容，不需要修改其他文件。

---

## Verification Steps

1. **编译验证**：
   - 打开 Xcode 项目，编译整个项目
   - 确保无编译错误

2. **功能验证**：
   - 启动前台 MP4 下载，点击暂停
   - 检查日志：应看到 "MP4 download paused, resumeData saved (X bytes)"
   - 检查状态：应直接变为 `.paused`，不应出现 `.failed` 或 `.cancelled` 中间状态
   - 点击恢复：应从断点继续下载

3. **取消验证**：
   - 启动前台 MP4 下载，点击取消
   - 检查状态：应变为 `.cancelled`
   - 检查临时文件：应被清理

4. **后台模式验证**：
   - 启动后台 MP4 下载，点击暂停
   - 检查状态：应直接变为 `.paused`
   - 点击恢复：应从断点继续下载

5. **失败场景验证**：
   - 启动前台 MP4 下载，断开网络
   - 检查状态：应变为 `.failed`
   - 不应影响暂停/取消的正常逻辑
