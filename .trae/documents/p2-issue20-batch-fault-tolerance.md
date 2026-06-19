# P2 Issue 20 修复计划：批量创建容错处理

> **For agentic workers:** 本计划修复缺陷修复优先级排序.md中P2问题20："批量创建时单个URL失败中断整个批量任务"。

**Goal:** 实现批量下载任务创建时的容错处理，单个URL失败不中断整个批量任务，支持失败记录和重试。

**Architecture:** 通过引入 `BatchFailedItem` 记录失败项、`BatchDownloadResult` 封装创建结果，将 `createBatchDownload` 从抛出异常改为返回结果对象。扩展 `BatchState` 新增 `partiallyFailed` 状态，UI层增加失败数量展示和重试交互。

**Tech Stack:** Swift, UIKit, Combine

---

## 当前状态分析

### 问题根因

在 `BatchDownloadManager.swift` 的 `createBatchDownload` 方法中（第86-103行），使用 `for` 循环逐个创建下载任务。当某个URL创建失败时，直接 `throw error`（第101行），导致：

1. **整个批量任务创建失败** —— 调用方收到异常
2. **产生孤儿任务** —— 之前已成功创建的任务已被加入 `VideoDownloadEngine` 的队列，但不在任何批量任务中
3. **用户无法管理** —— 这些孤儿任务只能通过单任务列表管理，造成混乱

### 涉及文件

| 文件 | 角色 |
|------|------|
| `DownLoad/DownLoad/Core/BatchDownloadManager.swift` | 核心：批量任务创建逻辑 |
| `DownLoad/DownLoad/Core/VideoDownloadEngine.swift` | 代理：批量创建方法签名适配 |
| `DownLoad/DownLoad/UI/BatchDownloadViewController.swift` | UI：创建交互和详情展示 |
| `DownLoad/DownLoad/UI/BatchDownloadCell.swift` | UI：单元格状态展示 |

---

## Proposed Changes

### Task 1: 扩展 BatchDownloadManager 数据结构和核心逻辑

**Files:**
- Modify: `DownLoad/DownLoad/Core/BatchDownloadManager.swift`

**修改内容：**

1. **新增 `BatchFailedItem` 结构体**（在 `BatchDownloadManager` 内）：

```swift
/// 批量任务失败项
struct BatchFailedItem: Identifiable {
    let id: UUID
    let url: String
    let fileName: String
    let errorDescription: String
    let failedAt: Date
    
    init(url: String, fileName: String, error: Error) {
        self.id = UUID()
        self.url = url
        self.fileName = fileName
        self.errorDescription = error.localizedDescription
        self.failedAt = Date()
    }
}
```

2. **新增 `BatchDownloadResult` 结构体**：

```swift
/// 批量下载创建结果
struct BatchDownloadResult {
    let batchTask: BatchDownloadTask
    let failedCount: Int
    let hasFailures: Bool
    
    var summary: String {
        let total = batchTask.taskItems.count + batchTask.failedItems.count
        let success = batchTask.taskItems.count
        let failed = failedCount
        return "共\(total)项，成功\(success)项，失败\(failed)项"
    }
}
```

3. **扩展 `BatchState` 枚举**，新增 `partiallyFailed`：

```swift
enum BatchState {
    case pending
    case downloading
    case paused
    case completed
    case failed
    case partiallyFailed  // 新增：部分失败
    case cancelled

    var rawValue: String {
        switch self {
        case .pending: return "Pending"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .partiallyFailed: return "Partially Failed"  // 新增
        case .cancelled: return "Cancelled"
        }
    }
}
```

4. **扩展 `BatchDownloadTask` 结构体**，增加失败项集合：

```swift
struct BatchDownloadTask: Identifiable {
    let id: UUID
    let name: String
    let taskItems: [BatchTaskItem]
    let createdAt: Date
    var state: BatchState
    var failedItems: [BatchFailedItem]  // 新增
    
    init(id: UUID = UUID(), name: String, taskItems: [BatchTaskItem], failedItems: [BatchFailedItem] = []) {
        self.id = id
        self.name = name
        self.taskItems = taskItems
        self.createdAt = Date()
        self.state = .pending
        self.failedItems = failedItems
    }
}
```

5. **修改 `createBatchDownload` 方法**，从 `throws` 改为返回 `BatchDownloadResult`，循环内捕获异常：

将第72-111行替换为：

```swift
/// 创建批量下载任务
func createBatchDownload(
    name: String,
    urls: [String],
    fileNames: [String]? = nil,
    configuration: DownloadConfiguration = .default
) async -> BatchDownloadResult {

    Logger.info("Creating batch download: \(name) with \(urls.count) URLs")
    print("🔥 BatchDownloadManager: 开始创建批量任务，URLs: \(urls)")

    var taskItems: [BatchTaskItem] = []
    var failedItems: [BatchFailedItem] = []

    // 创建下载任务
    for (index, url) in urls.enumerated() {
        print("🔥 处理URL \(index + 1)/\(urls.count): \(url)")
        let fileName = fileNames?[index] ?? "video_\(index + 1).\(getFileExtension(from: url))"

        do {
            let task = try await VideoDownloadEngine.shared.createDownloadTask(
                url: url,
                fileName: fileName,
                configuration: configuration
            )
            print("✅ 任务创建成功: \(fileName)")
            taskItems.append(BatchTaskItem(task: task))
        } catch {
            print("❌ 任务创建失败: \(error)，记录失败项并继续")
            let failedItem = BatchFailedItem(url: url, fileName: fileName, error: error)
            failedItems.append(failedItem)
        }
    }

    // 确定批量任务状态
    let state: BatchState
    if taskItems.isEmpty {
        state = .failed
    } else if !failedItems.isEmpty {
        state = .partiallyFailed
    } else {
        state = .pending
    }

    // 创建批量任务
    var batchTask = BatchDownloadTask(name: name, taskItems: taskItems, failedItems: failedItems)
    batchTask.state = state
    batchTasks[batchTask.id] = batchTask
    print("✅ 批量任务创建完成，ID: \(batchTask.id)，成功: \(taskItems.count)，失败: \(failedItems.count)")

    return BatchDownloadResult(batchTask: batchTask, failedCount: failedItems.count, hasFailures: !failedItems.isEmpty)
}
```

6. **新增 `retryFailedItems` 方法**（在 `clearAllBatchDownloads` 之前添加）：

```swift
/// 重试批量任务中的失败项
func retryFailedItems(batchId: UUID) async -> BatchDownloadResult? {
    guard var batchTask = batchTasks[batchId] else {
        return nil
    }

    let failedItemsToRetry = batchTask.failedItems
    guard !failedItemsToRetry.isEmpty else {
        return nil
    }

    Logger.info("Retrying \(failedItemsToRetry.count) failed items for batch: \(batchTask.name)")

    var newTaskItems: [BatchTaskItem] = []
    var stillFailedItems: [BatchFailedItem] = []

    for failedItem in failedItemsToRetry {
        do {
            let task = try await VideoDownloadEngine.shared.createDownloadTask(
                url: failedItem.url,
                fileName: failedItem.fileName,
                configuration: .default
            )
            newTaskItems.append(BatchTaskItem(task: task))
        } catch {
            let newFailedItem = BatchFailedItem(
                url: failedItem.url,
                fileName: failedItem.fileName,
                error: error
            )
            stillFailedItems.append(newFailedItem)
        }
    }

    // 合并新成功的任务到现有任务列表
    let allTaskItems = batchTask.taskItems + newTaskItems

    // 更新批量任务
    batchTask.taskItems = allTaskItems
    batchTask.failedItems = stillFailedItems

    // 重新计算状态
    if allTaskItems.isEmpty {
        batchTask.state = .failed
    } else if !stillFailedItems.isEmpty {
        batchTask.state = .partiallyFailed
    } else {
        batchTask.state = .pending
    }

    batchTasks[batchId] = batchTask

    // 自动启动新添加的任务
    if !newTaskItems.isEmpty {
        for item in newTaskItems {
            try? await VideoDownloadEngine.shared.startDownload(task: item.task)
        }
        if batchTask.state == .pending {
            batchTasks[batchId]?.state = .downloading
        }
    }

    return BatchDownloadResult(
        batchTask: batchTask,
        failedCount: stillFailedItems.count,
        hasFailures: !stillFailedItems.isEmpty
    )
}
```

7. **修改 `getBatchProgress` 方法**，扩展返回类型包含失败项：

将第187-216行替换为：

```swift
/// 获取批量任务的进度
func getBatchProgress(batchId: UUID) async -> (
    total: Int,
    completed: Int,
    downloading: Int,
    paused: Int,
    failed: Int,
    failedInCreation: Int
)? {
    guard let batchTask = batchTasks[batchId] else {
        return nil
    }

    var completed = 0
    var downloading = 0
    var paused = 0
    var failed = 0

    for item in batchTask.taskItems {
        let task = await VideoDownloadEngine.shared.getTask(by: item.task.id)
        let state = task?.state.value ?? item.task.state.value

        switch state {
        case .completed:
            completed += 1
        case .downloading:
            downloading += 1
        case .paused:
            paused += 1
        case .failed:
            failed += 1
        case .cancelled, .pending:
            break
        }
    }

    let total = batchTask.taskItems.count + batchTask.failedItems.count
    let failedInCreation = batchTask.failedItems.count

    return (
        total: total,
        completed: completed,
        downloading: downloading,
        paused: paused,
        failed: failed,
        failedInCreation: failedInCreation
    )
}
```

---

### Task 2: 适配 VideoDownloadEngine 代理方法

**Files:**
- Modify: `DownLoad/DownLoad/Core/VideoDownloadEngine.swift`

**修改内容：**

1. **修改 `createBatchDownload` 代理方法签名**，移除 `throws`：

将第381-393行替换为：

```swift
/// 批量创建下载任务
public func createBatchDownload(
    name: String,
    urls: [String],
    fileNames: [String]? = nil,
    configuration: DownloadConfiguration = .default
) async -> BatchDownloadManager.BatchDownloadResult {
    return await BatchDownloadManager.shared.createBatchDownload(
        name: name,
        urls: urls,
        fileNames: fileNames,
        configuration: configuration
    )
}
```

2. **新增 `retryFailedItems` 代理方法**（在 `clearAllBatchDownloads` 之前添加）：

```swift
/// 重试批量任务中的失败项
public func retryFailedItems(batchId: UUID) async -> BatchDownloadManager.BatchDownloadResult? {
    return await BatchDownloadManager.shared.retryFailedItems(batchId: batchId)
}
```

---

### Task 3: 修改 BatchDownloadCell 展示失败信息

**Files:**
- Modify: `DownLoad/DownLoad/UI/BatchDownloadCell.swift`

**修改内容：**

1. **新增 `failedCountLabel` UI 元素**（在 `countLabel` 之后）：

```swift
private let failedCountLabel: UILabel = {
    let label = UILabel()
    label.font = UIFont.systemFont(ofSize: 12)
    label.textColor = .systemRed
    label.translatesAutoresizingMaskIntoConstraints = false
    label.isHidden = true
    return label
}()
```

2. **在 `setupUI` 中添加约束**：

在 `contentView.addSubview(countLabel)` 后添加：
```swift
contentView.addSubview(failedCountLabel)
```

在约束数组中添加：
```swift
failedCountLabel.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 2),
failedCountLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
```

3. **修改 `updateProgress` 方法**，显示失败数量：

将第134-148行替换为：

```swift
private func updateProgress(batchTask: BatchDownloadManager.BatchDownloadTask) {
    Task {
        let progress = await engine.getBatchProgress(batchId: batchTask.id)
        let total = progress?.total ?? batchTask.taskItems.count
        let completed = progress?.completed ?? 0
        let downloading = progress?.downloading ?? 0
        let paused = progress?.paused ?? 0
        let failedInCreation = progress?.failedInCreation ?? 0

        await MainActor.run {
            progressView.progress = total > 0 ? Float(completed) / Float(total) : 0
            progressLabel.text = "\(completed)/\(total)"
            countLabel.text = "下载中:\(downloading) 暂停:\(paused)"
            
            if failedInCreation > 0 {
                failedCountLabel.text = "创建失败:\(failedInCreation)"
                failedCountLabel.isHidden = false
            } else {
                failedCountLabel.isHidden = true
            }
        }
    }
}
```

4. **修改 `updateStatusColor` 方法**，处理 `partiallyFailed`：

将第150-165行替换为：

```swift
private func updateStatusColor(_ state: BatchDownloadManager.BatchState) {
    switch state {
    case .pending:
        statusLabel.textColor = .secondaryLabel
    case .downloading:
        statusLabel.textColor = .systemBlue
    case .paused:
        statusLabel.textColor = .systemOrange
    case .completed:
        statusLabel.textColor = .systemGreen
    case .failed:
        statusLabel.textColor = .systemRed
    case .partiallyFailed:
        statusLabel.textColor = .systemOrange
    case .cancelled:
        statusLabel.textColor = .gray
    }
}
```

5. **修改 `prepareForReuse`**，清理失败标签：

在 `prepareForReuse` 中添加：
```swift
failedCountLabel.isHidden = true
failedCountLabel.text = ""
```

---

### Task 4: 修改 BatchDownloadViewController 交互逻辑

**Files:**
- Modify: `DownLoad/DownLoad/UI/BatchDownloadViewController.swift`

**修改内容：**

1. **修改 `createBatchDownload` 方法**，适配新的返回类型：

将第241-268行替换为：

```swift
private func createBatchDownload(urls: [String]) async {
    print("🔥 开始创建批量下载任务，URLs: \(urls)")

    let now = Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    let name = "下载任务 \(formatter.string(from: now))"
    print("🔥 批量任务名称: \(name)")

    let result = await batchManager.createBatchDownload(
        name: name,
        urls: urls
    )

    print("✅ 批量任务创建完成: \(result.batchTask.id)")
    print("📊 \(result.summary)")

    // 如果有失败项，显示提示
    if result.hasFailures {
        let message = result.summary + "\n失败项可在任务详情中查看并重试"
        showAlert(title: "批量任务创建完成（部分失败）", message: message)
    }

    await startBatchDownload(batchId: result.batchTask.id)
    print("✅ 批量任务已开始下载")

    await loadBatchTasks()
    print("✅ 任务列表已刷新")
}
```

2. **新增 `retryFailedItems` 方法**：

在 `startBatchDownload` 方法后添加：

```swift
/// 重试批量任务的失败项
private func retryFailedItems(batchId: UUID) {
    Task {
        guard let result = await batchManager.retryFailedItems(batchId: batchId) else {
            showAlert(title: "重试失败", message: "无法找到批量任务或没有失败项")
            return
        }

        if result.hasFailures {
            showAlert(title: "重试完成（仍有失败）", message: result.summary)
        } else {
            showAlert(title: "重试成功", message: "所有失败项已重新添加并开始下载")
        }

        await loadBatchTasks()
    }
}
```

3. **新增批量任务详情展示方法**：

在 `retryFailedItems` 后添加：

```swift
/// 显示批量任务详情（含失败项）
private func showBatchTaskDetail(_ batchTask: BatchDownloadManager.BatchDownloadTask) {
    let alertController = UIAlertController(
        title: batchTask.name,
        message: "成功项: \(batchTask.taskItems.count)\n失败项: \(batchTask.failedItems.count)",
        preferredStyle: .actionSheet
    )

    // 如果有失败项，显示重试选项
    if !batchTask.failedItems.isEmpty {
        alertController.addAction(UIAlertAction(title: "重试失败项", style: .default) { [weak self] _ in
            self?.retryFailedItems(batchId: batchTask.id)
        })

        alertController.addAction(UIAlertAction(title: "查看失败详情", style: .default) { [weak self] _ in
            self?.showFailedItemsDetail(batchTask.failedItems)
        })
    }

    alertController.addAction(UIAlertAction(title: "取消", style: .cancel))
    present(alertController, animated: true)
}

/// 显示失败项详情
private func showFailedItemsDetail(_ failedItems: [BatchDownloadManager.BatchFailedItem]) {
    var message = ""
    for (index, item) in failedItems.enumerated() {
        message += "\(index + 1). \(item.fileName)\n   原因: \(item.errorDescription)\n\n"
    }

    let alertController = UIAlertController(
        title: "失败详情",
        message: message,
        preferredStyle: .alert
    )
    alertController.addAction(UIAlertAction(title: "确定", style: .default))
    present(alertController, animated: true)
}
```

4. **修改 `didSelectRowAt`**，非编辑模式下显示详情：

将第357-369行替换为：

```swift
func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    if isEditMode {
        let batchTask = batchTasks[indexPath.row]
        if selectedTaskIds.contains(batchTask.id) {
            selectedTaskIds.remove(batchTask.id)
        } else {
            selectedTaskIds.insert(batchTask.id)
        }
        updateSelectionBar()
        updateDeleteButton()
    } else {
        tableView.deselectRow(at: indexPath, animated: true)
        let batchTask = batchTasks[indexPath.row]
        showBatchTaskDetail(batchTask)
    }
}
```

---

### Task 5: 更新缺陷修复优先级排序文档

**Files:**
- Modify: `/Users/hubin/Desktop/MutiDownload/缺陷修复优先级排序.md`

**修改内容：**

将问题20的行替换为：

```markdown
| 20 | ~~批量创建时单个 URL 失败中断整个批量任务~~ ✅ 已修复 (2026-06-20) | `BatchDownloadManager.swift`、`VideoDownloadEngine.swift`、`BatchDownloadViewController.swift`、`BatchDownloadCell.swift` | 引入 `BatchFailedItem` 记录失败项，`BatchDownloadResult` 封装创建结果，`createBatchDownload` 改为返回结果对象而非抛出异常。扩展 `BatchState` 新增 `.partiallyFailed`。新增 `retryFailedItems` 支持重试失败项。UI 展示失败数量和重试入口。编译通过。 |
```

---

## Assumptions & Decisions

1. **失败项不加入 Engine 队列**：创建失败的URL不会生成 `DownloadTask`，因此不会加入 `VideoDownloadEngine` 的队列。这避免了孤儿任务问题。
2. **重试使用默认配置**：`retryFailedItems` 使用 `.default` 配置重新创建任务。若需要保留原始配置，需扩展 `BatchFailedItem` 存储配置信息。
3. **状态颜色复用**：`partiallyFailed` 使用橙色（与 `paused` 相同），表示警告而非严重错误。
4. **UI 使用 ActionSheet**：批量任务详情使用 ActionSheet 展示，符合 iOS 交互规范。
5. **向后兼容**：`BatchDownloadTask` 的 `failedItems` 有默认值 `[]`，不影响已有代码。

---

## Verification Steps

### 编译验证

```bash
cd /Users/hubin/Desktop/MutiDownload/DownLoad
xcodebuild -scheme DownLoad -destination 'platform=iOS Simulator,name=iPhone 15' build
```

### 功能验证

1. **全部成功场景**
   - 输入3个有效URL
   - 验证 `BatchDownloadResult.hasFailures == false`
   - 验证 `batchTask.state == .pending`

2. **部分失败场景**
   - 输入3个URL，其中1个无效（如 `https://invalid-url-test.com/video.mp4`）
   - 验证 `hasFailures == true`，`state == .partiallyFailed`
   - 验证成功项已加入 Engine 队列，失败项未加入
   - 验证UI显示失败数量

3. **全部失败场景**
   - 输入3个无效URL
   - 验证 `state == .failed`，`taskItems` 为空

4. **重试功能**
   - 创建部分失败的批量任务
   - 点击"重试失败项"
   - 验证失败项被重新尝试
   - 验证UI自动刷新

5. **无孤儿任务**
   - 创建部分失败的批量任务后删除
   - 验证 Engine 队列中无残留任务
