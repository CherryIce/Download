# P0 任务5和任务6修复实施计划

> **目标：** 修复 `BatchDownloadManager` 双队列并发控制失效问题，以及集成 `DownloadTaskDatabase` 实现任务持久化。

**涉及文件：**
- `BatchDownloadManager.swift`
- `VideoDownloadEngine.swift`
- `DownloadQueueManager.swift`
- `DownloadTaskProtocol.swift`
- `MP4DownloadHandler.swift`
- `M3U8DownloadHandler.swift`
- `AppDelegate.swift`

---

## 当前状态分析

### 任务5：双队列并发控制失效
- `BatchDownloadManager` 内部持有独立的 `queueManager = DownloadQueueManager()`
- `createBatchDownload` 调用 `VideoDownloadEngine.createDownloadTask`，任务被添加到 Engine 的 queueManager
- `startBatchDownload` 又将同一批任务添加到 BatchManager 自己的 queueManager
- 结果：同一任务被两个独立管理器管理，实际并发数翻倍（3+3=6）

### 任务6：数据库是死代码
- `DownloadTaskDatabase` 已实现完整的 SQLite CRUD，但从未被实例化或调用
- 任务仅保存在内存中，App 杀死后全部丢失
- `DownloadTask` 协议缺少数据库持久化所需的字段（format、totalSize、downloadedSize 等）

---

## 任务5修复：统一队列管理器

### 修改1：`BatchDownloadManager.swift`

**移除私有 queueManager 属性（第17行）：**
```swift
// 删除：private let queueManager = DownloadQueueManager()
```

**修改 `startBatchDownload` 方法（第115-128行）：**
```swift
/// 开始批量下载
func startBatchDownload(batchId: UUID) async throws {
    guard let batchTask = batchTasks[batchId] else {
        throw BatchDownloadError.invalidBatchId
    }

    Logger.info("Starting batch download: \(batchTask.name)")
    batchTasks[batchId]?.state = .downloading

    // 任务已在 Engine 的 queueManager 中，只需确保状态正确
    for item in batchTask.taskItems {
        if await VideoDownloadEngine.shared.getTask(by: item.task.id) == nil {
            await VideoDownloadEngine.shared.startDownload(task: item.task)
        }
    }
}
```

**修改 `getBatchProgress` 为 async（第187-215行）：**
```swift
func getBatchProgress(batchId: UUID) async -> (total: Int, completed: Int, downloading: Int, paused: Int, failed: Int)? {
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
        case .completed: completed += 1
        case .downloading: downloading += 1
        case .paused: paused += 1
        case .failed: failed += 1
        case .cancelled, .pending: break
        }
    }

    return (total: batchTask.taskItems.count, completed: completed, downloading: downloading, paused: paused, failed: failed)
}
```

### 修改2：`VideoDownloadEngine.swift`

**同步 `getBatchProgress` 代理方法签名（第192-195行）：**
```swift
public func getBatchProgress(batchId: UUID) async -> (total: Int, completed: Int, downloading: Int, paused: Int, failed: Int)? {
    return await BatchDownloadManager.shared.getBatchProgress(batchId: batchId)
}
```

---

## 任务6修复：集成 DownloadTaskDatabase

### 修改3：`DownloadTaskProtocol.swift` — 扩展协议字段

**将第12-24行替换为：**
```swift
/// 下载任务协议
protocol DownloadTask: AnyObject {
    var id: UUID { get }
    var url: String { get }
    var fileName: String { get }
    var format: VideoFormat { get }
    var totalSize: Int64? { get }
    var downloadedSize: Int64 { get }
    let createdAt: Date { get }
    var completedAt: Date? { get }
    var resumeData: Data? { get }
    var configuration: DownloadConfiguration { get }
    var state: CurrentValueSubject<DownloadState, Never> { get }
    var progress: CurrentValueSubject<DownloadProgress, Never> { get }
    var completedURL: URL? { get }

    func resume() async throws
    func pause() async
    func cancel() async
}
```

### 修改4：`MP4DownloadHandler.swift` — 添加缺失属性

**在 `MP4DownloadTask` 第63行后添加：**
```swift
let format: VideoFormat = .mp4
var totalSize: Int64?
var downloadedSize: Int64 = 0
let createdAt: Date = Date()
var completedAt: Date?
```

**在下载进度回调中更新字段（第130行后）：**
```swift
self.totalSize = total
self.downloadedSize = downloaded
```

**在下载完成时设置 completedAt（第146行前）：**
```swift
self.completedAt = Date()
```

**在类结束后添加 `toDownloadItem()` 扩展：**
```swift
extension MP4DownloadTask {
    func toDownloadItem() -> DownloadItem {
        return DownloadItem(
            id: id,
            url: url,
            format: format,
            fileName: fileName,
            totalSize: totalSize,
            downloadedSize: downloadedSize,
            state: state.value,
            createdAt: createdAt,
            completedAt: completedAt,
            resumeData: resumeData
        )
    }
}
```

### 修改5：`M3U8DownloadHandler.swift` — 添加缺失属性

**在 `M3U8DownloadTask` 第85行后添加：**
```swift
let format: VideoFormat = .m3u8
var totalSize: Int64?
var downloadedSize: Int64 = 0
let createdAt: Date = Date()
var completedAt: Date?
var resumeData: Data?
```

**在 `updateProgress` 中更新字段（第238行前）：**
```swift
self.totalSize = Int64(total)
self.downloadedSize = Int64(completed)
```

**在下载完成时设置 completedAt（第167行前）：**
```swift
self.completedAt = Date()
```

**在类结束后添加 `toDownloadItem()` 扩展：**
```swift
extension M3U8DownloadTask {
    func toDownloadItem() -> DownloadItem {
        return DownloadItem(
            id: id,
            url: url,
            format: format,
            fileName: fileName,
            totalSize: totalSize,
            downloadedSize: downloadedSize,
            state: state.value,
            createdAt: createdAt,
            completedAt: completedAt,
            resumeData: resumeData
        )
    }
}
```

### 修改6：`VideoDownloadEngine.swift` — 集成数据库

**添加数据库属性（第18行后）：**
```swift
private let database: DownloadTaskDatabase
private var databaseCancellables: [UUID: AnyCancellable] = [:]
private var hasRestoredTasks = false
```

**修改初始化方法（第20-24行）：**
```swift
private init() {
    self.queueManager = DownloadQueueManager()
    self.storageManager = FileStorageManager()
    self.networkClient = NetworkClient()
    do {
        self.database = try DownloadTaskDatabase()
    } catch {
        fatalError("Failed to initialize download task database: \(error)")
    }
}
```

**在 `createDownloadTask` 中保存任务并启动监听（第63行前）：**
```swift
// 保存到数据库并监听状态变化
persistTask(task)
observeTaskForDatabase(task)
```

**添加持久化相关方法（在 `clearAllDownloads` 后）：**
```swift
/// 监听任务状态变化并同步到数据库
private func observeTaskForDatabase(_ task: any DownloadTask) {
    let taskId = task.id

    let cancellable = task.state
        .dropFirst()
        .debounce(for: .seconds(0.5), scheduler: DispatchQueue.global(qos: .utility))
        .sink { [weak self] newState in
            guard let self = self else { return }
            Task {
                await self.persistTask(task)
                if newState == .completed || newState == .failed || newState == .cancelled {
                    self.databaseCancellables.removeValue(forKey: taskId)
                }
            }
        }

    databaseCancellables[taskId] = cancellable
}

/// 将任务持久化到数据库
private func persistTask(_ task: any DownloadTask) {
    if let mp4Task = task as? MP4DownloadTask {
        let record = DownloadTaskRecord(from: mp4Task.toDownloadItem())
        try? database.saveRecord(record)
    } else if let m3u8Task = task as? M3U8DownloadTask {
        let record = DownloadTaskRecord(from: m3u8Task.toDownloadItem())
        try? database.saveRecord(record)
    }
}

/// 从数据库删除任务记录
private func deleteTaskRecord(_ taskId: UUID) {
    try? database.deleteRecord(byId: taskId)
}
```

**修改 `cancelDownload`（第91-95行）：**
```swift
func cancelDownload(task: any DownloadTask) async {
    Logger.info("Cancelling download: \(task.id)")
    await task.cancel()
    await queueManager.removeTask(task.id)
    deleteTaskRecord(task.id)
}
```

**修改 `deleteDownloadTask`（在末尾添加）：**
```swift
// 删除数据库记录
deleteTaskRecord(task.id)
```

**修改 `clearAllDownloads`（在末尾添加）：**
```swift
// 清空数据库
try? database.deleteAllRecords()
```

**添加任务恢复方法：**
```swift
/// 从数据库恢复未完成的任务
func restoreTasksFromDatabase() async {
    guard !hasRestoredTasks else { return }
    hasRestoredTasks = true

    Logger.info("Restoring tasks from database...")

    do {
        let records = try database.loadAllRecords()
        let incompleteRecords = records.filter { record in
            let state = DownloadState(rawValue: record.state) ?? .pending
            return state != .completed && state != .cancelled
        }

        Logger.info("Found \(incompleteRecords.count) incomplete tasks to restore")

        for record in incompleteRecords {
            // 避免重复添加
            if await queueManager.getTask(by: record.id) != nil {
                continue
            }

            let item = record.toDownloadItem()

            // 根据格式创建对应的任务
            let task: any DownloadTask
            switch item.format {
            case .mp4:
                let mp4Task = MP4DownloadTask(
                    id: item.id,
                    url: item.url,
                    fileName: item.fileName,
                    configuration: .default,
                    networkClient: networkClient,
                    storageManager: storageManager
                )
                mp4Task.totalSize = item.totalSize
                mp4Task.downloadedSize = item.downloadedSize
                mp4Task.completedAt = item.completedAt
                if let resumeData = item.resumeData {
                    mp4Task.resumeData = resumeData
                }
                task = mp4Task
            case .m3u8:
                Logger.warning("M3U8 task restoration not fully supported yet, skipping: \(item.id)")
                continue
            case .thunder:
                Logger.warning("Thunder task restoration not fully supported yet, skipping: \(item.id)")
                continue
            }

            // 添加到队列
            await queueManager.addTask(task)
            observeTaskForDatabase(task)

            // 如果之前是下载中状态，设置为暂停
            if item.state == .downloading {
                task.state.send(.paused)
            } else {
                task.state.send(item.state)
            }
        }

        Logger.info("Restored tasks from database")
    } catch {
        Logger.error("Failed to restore tasks from database: \(error)")
    }
}
```

### 修改7：`AppDelegate.swift` — App 启动时恢复任务

**在 `didFinishLaunchingWithOptions` 中添加：**
```swift
func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    // 恢复下载任务
    Task {
        await VideoDownloadEngine.shared.restoreTasksFromDatabase()
    }
    return true
}
```

---

## 验证步骤

### 任务5验证
1. 创建批量下载任务（5个URL）
2. 验证 `VideoDownloadEngine.shared.getAllTasks()` 返回的任务数等于5（不是10）
3. 验证同时运行的任务数不超过3个
4. 检查日志确认只进入一个 queueManager 的调度逻辑

### 任务6验证
1. 创建下载任务后，检查 `Documents/DownloadTasks.sqlite3` 中是否有记录
2. 开始下载、暂停，观察数据库中 `state` 字段是否正确更新
3. 强制停止 App，重新启动，验证未完成任务是否恢复
4. 验证恢复后的任务状态是否正确（之前 downloading 的应变为 paused）

---

## 假设与决策

1. **M3U8/Thunder 任务恢复暂不实现**：M3U8 任务依赖 playlist 和 encryptionKey，无法从简单记录恢复，当前方案跳过
2. **数据库初始化失败使用 fatalError**：数据库是核心功能，初始化失败不应静默降级
3. **状态变更使用 debounce 0.5秒**：避免频繁写入数据库，同时保证状态最终一致性
4. **恢复的任务状态设为 paused**：App 重启后网络连接已断开，不应自动开始下载
5. **BatchDownloadManager 的 `getBatchProgress` 改为 async**：需要跨 actor 边界从 Engine 获取任务状态
