# 问题37 修复计划：`DownloadTask` 协议添加 `retry()` 方法

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 `DownloadTask` 协议添加 `retry()` 方法，使用户能够手动重试失败的下载任务，同时在单任务下载页添加 Retry 按钮。

**Architecture:** 协议层新增 `retry()` 方法；`MP4DownloadTask` 和 `M3U8DownloadTask` 分别实现（保留断点进度，重置错误状态）；`VideoDownloadEngine` 提供公共入口；`ViewController` 添加状态驱动的 Retry 按钮。

**Tech Stack:** Swift, UIKit, Combine

---

## 当前状态分析

- `DownloadTask` 协议已有 `resume()`/`pause()`/`cancel()`/`pause(reason:)`，但缺少 `retry()`
- `MP4DownloadTask` 的 `resume()` 已支持 `resumeData` 断点续传
- `M3U8DownloadTask` 的 `resume()` 会加载 `M3U8DownloadState` 恢复已完成片段
- `VideoDownloadEngine` 有 `startDownload(task:)`，但没有 retry 入口
- `ViewController.swift` 只有 Start/Pause/Cancel 三个按钮
- `retry()` 与 `resume()` 语义不同：`resume()` 恢复暂停任务，`retry()` 重试失败任务

---

## 修改文件清单

| 文件 | 路径 | 修改类型 |
|------|------|----------|
| `DownloadTaskProtocol.swift` | `/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/Core/DownloadTaskProtocol.swift` | 协议新增方法 |
| `MP4DownloadHandler.swift` | `/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/Handlers/MP4DownloadHandler.swift` | `MP4DownloadTask` 实现 `retry()` |
| `M3U8DownloadHandler.swift` | `/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/Handlers/M3U8DownloadHandler.swift` | `M3U8DownloadTask` 实现 `retry()` |
| `VideoDownloadEngine.swift` | `/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/Core/VideoDownloadEngine.swift` | 新增 `retryDownload(task:)` 公共方法 |
| `ViewController.swift` | `/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/ViewController.swift` | 添加 Retry 按钮及状态驱动显示逻辑 |
| `缺陷修复优先级排序.md` | `/Users/hubin/Desktop/MutiDownload/缺陷修复优先级排序.md` | 标记问题37为已修复 |

---

## Task 1: 协议层新增 `retry()` 方法

**Files:**
- Modify: `/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/Core/DownloadTaskProtocol.swift`

- [ ] **Step 1: 在 `DownloadTask` 协议中添加 `retry()` 方法**

```swift
    func resume() async throws
    func retry() async throws   // <-- 新增
    func pause() async
    func cancel() async

    /// 带原因的暂停（供 NetworkMonitor 调用）
    func pause(reason: PauseReason) async
```

---

## Task 2: `MP4DownloadTask` 实现 `retry()`

**Files:**
- Modify: `/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/Handlers/MP4DownloadHandler.swift`

- [ ] **Step 1: 在 `resume()` 方法后插入 `retry()` 实现**

```swift
    func retry() async throws {
        guard state.value == .failed else {
            Logger.warning("MP4 retry() called but state is not .failed (current: \(state.value.displayText)), task: \(id)")
            return
        }

        Logger.info("Retrying MP4 download task: \(id)")

        // 重置终止原因和暂停原因
        terminationReason = .none
        pauseReason = nil

        // 重置状态为 pending，保留 resumeData 和 downloadedSize 用于断点续传
        state.send(.pending)

        // 重新启动下载（resume() 会自动使用已有的 resumeData）
        try await resume()
    }
```

---

## Task 3: `M3U8DownloadTask` 实现 `retry()`

**Files:**
- Modify: `/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/Handlers/M3U8DownloadHandler.swift`

- [ ] **Step 1: 在 `resume()` 方法后插入 `retry()` 实现**

```swift
    func retry() async throws {
        guard state.value == .failed else {
            Logger.warning("M3U8 retry() called but state is not .failed (current: \(state.value.displayText)), task: \(id)")
            return
        }

        Logger.info("Retrying M3U8 download task: \(id), preserving \(downloadState.completedSegments.count)/\(downloadState.totalSegments) completed segments")

        // 清除暂停原因
        pauseReason = nil

        // 重置状态为 pending
        // 注意：不清理 downloadState，保留已下载片段的断点进度
        state.send(.pending)

        // 重新启动下载（resume() 会自动 loadDownloadState 并跳过已完成片段）
        try await resume()
    }
```

---

## Task 4: `VideoDownloadEngine` 新增 `retryDownload(task:)`

**Files:**
- Modify: `/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/Core/VideoDownloadEngine.swift`

- [ ] **Step 1: 在 `startDownload(task:)` 方法后插入 `retryDownload(task:)`**

```swift
    /// 重试失败的下载任务
    func retryDownload(task: any DownloadTask) async throws {
        Logger.info("Requesting retry for download: \(task.id)")

        // 检查网络是否可用
        guard NetworkMonitor.shared.isNetworkAvailableForDownload else {
            Logger.warning("Cannot retry download: network not available for downloads")
            throw DownloadError.networkError(
                NSError(domain: "NetworkMonitor", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "网络不可用，无法重试下载"
                ])
            )
        }

        // 检查任务是否已在队列中
        if await queueManager.getTask(by: task.id) == nil {
            await queueManager.addTask(task)
        }

        try await task.retry()
    }
```

---

## Task 5: `ViewController.swift` 添加 Retry 按钮

**Files:**
- Modify: `/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/ViewController.swift`

- [ ] **Step 1: 新增 `retryButton` 属性（在 `cancelButton` 定义之后）**

```swift
    private let retryButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Retry", for: .normal)
        button.backgroundColor = .systemGreen
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
        button.isHidden = true  // 默认隐藏，仅在失败时显示
        return button
    }()
```

- [ ] **Step 2: 将 Retry 按钮加入 StackView**

在 `setupUI()` 中：
```swift
        stackView.addArrangedSubview(downloadButton)
        stackView.addArrangedSubview(pauseButton)
        stackView.addArrangedSubview(cancelButton)
        stackView.addArrangedSubview(retryButton)   // <-- 新增
```

- [ ] **Step 3: 添加 Retry 按钮 Action**

在 `cancelButton.addTarget` 之后：
```swift
        retryButton.addTarget(self, action: #selector(retryDownload), for: .touchUpInside)
```

- [ ] **Step 4: 在状态监听中控制 Retry 按钮显示/隐藏**

修改 `startDownload()` 中 `task.state.sink` 闭包：
```swift
                // 监听状态
                task.state
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] state in
                        self?.log("State: \(state.displayText)")

                        // 控制 Retry 按钮显示：仅在失败时显示
                        self?.retryButton.isHidden = (state != .failed)

                        switch state {
                        case .completed:
                            let path = self?.currentTask?.completedURL?.path ?? "unknown"
                            self?.log("下载完成: \(path)")
                        case .failed:
                            self?.log("下载失败")
                        case .cancelled:
                            self?.log("下载已取消")
                            self?.retryButton.isHidden = true
                        default:
                            break
                        }
                    }
                    .store(in: &cancellables)
```

- [ ] **Step 5: 添加 `retryDownload()` 方法**

在 `cancelDownload()` 方法之后：
```swift
    @objc private func retryDownload() {
        guard let task = currentTask else {
            log("No active task to retry")
            return
        }

        guard task.state.value == .failed else {
            log("Task is not in failed state, cannot retry")
            return
        }

        Task {
            do {
                try await downloadEngine.retryDownload(task: task)
                log("Download retry started")
            } catch {
                log("Retry failed: \(error.localizedDescription)")
            }
        }
    }
```

---

## Task 6: 标记问题37为已修复

**Files:**
- Modify: `/Users/hubin/Desktop/MutiDownload/缺陷修复优先级排序.md`

- [ ] **Step 1: 将问题37行修改为已修复状态**

将：
```
| 37 | `DownloadTask` 协议缺少 `retry()` 方法 | `DownloadTaskProtocol.swift` | 用户无法手动重试失败任务 |
```

修改为：
```
| 37 | ~~`DownloadTask` 协议缺少 `retry()` 方法~~ ✅ 已修复 (2026-06-20) | `DownloadTaskProtocol.swift`、`MP4DownloadHandler.swift`、`M3U8DownloadHandler.swift`、`VideoDownloadEngine.swift`、`ViewController.swift` | 协议新增 `retry()` 方法；`MP4DownloadTask` 实现：重置状态为 `.pending`，保留 resumeData，调用 `resume()`；`M3U8DownloadTask` 实现：重置状态为 `.pending`，保留已下载片段状态，调用 `resume()`；`VideoDownloadEngine` 新增 `retryDownload(task:)` 公共入口；`ViewController` 添加 Retry 按钮，仅在任务失败时显示。编译通过。 |
```

---

## 关键设计决策

| 决策点 | 选择 | 理由 |
|--------|------|------|
| `retry()` 是否清理 resumeData / completedSegments | **不清理** | 保留断点续传能力，重试从上次进度继续 |
| `retry()` 是否允许非 `.failed` 状态调用 | **Guard 保护，仅 `.failed` 可调用** | 防止误操作，语义清晰 |
| Retry 按钮默认状态 | **隐藏 (`isHidden = true`)** | 仅在 `.failed` 状态时显示，避免干扰正常流程 |
| `VideoDownloadEngine.retryDownload` 是否重新添加队列 | **是，若不在队列中则添加** | 兼容任务被移除队列后重新重试的场景 |

---

## 验证步骤

1. **编译验证**
   - 执行 Xcode Build（Cmd+B），确认无编译错误
   - 特别关注 `DownloadTask` 协议一致性：`MP4DownloadTask` 和 `M3U8DownloadTask` 必须实现 `retry()`

2. **协议一致性验证**
   - 搜索 `protocol DownloadTask` 确认 `retry()` 已添加
   - 搜索 `func retry()` 确认两个实现类均有该方法

3. **MP4 重试验证**
   - 启动 App，输入一个 MP4 URL 开始下载
   - 模拟网络断开使任务进入 `.failed` 状态
   - 确认 Retry 按钮出现
   - 点击 Retry，确认任务从 `.pending` → `.downloading`，且 `downloadedSize` 保持原有值（断点续传）

4. **M3U8 重试验证**
   - 启动 App，输入一个 M3U8 URL 开始下载
   - 等待部分片段下载完成后模拟失败
   - 点击 Retry，确认 `calibrateDownloadedBytes` 仍能识别已下载片段，跳过已完成片段继续下载

5. **状态边界验证**
   - 在 `.downloading` / `.paused` / `.completed` 状态下确认 Retry 按钮不显示
   - 点击 Start/Pause/Cancel 按钮确认原有功能不受影响

6. **文档验证**
   - 确认 `缺陷修复优先级排序.md` 中问题37已标记为已修复，描述准确
