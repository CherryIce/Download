# P1 Issue 9 + Issue 10 修复实现计划

> **目标：** 修复 M3U8 断点续传状态不持久化（Issue 9）和 M3U8 进度/速度计算使用片段数而非字节数（Issue 10）两个问题。

**架构：** 通过将 `M3U8DownloadState` 序列化为 JSON 文件持久化到任务临时目录，实现 App 重启后的断点续传；通过跟踪每个 TS 片段的实际文件大小，将进度和速度计算从片段计数改为字节计数。

**技术栈：** Swift, Combine, SQLite3, Foundation

---

## 当前状态分析

### Issue 9: M3U8 断点续传状态不持久化
- `M3U8DownloadState` 仅存在于内存中，App 重启后 `completedSegments` 丢失
- `VideoDownloadEngine.restoreTasksFromDatabase()` 中 M3U8 任务被直接跳过（`continue`）
- 数据库 `DownloadTaskRecord` 没有存储 M3U8 特有的恢复数据字段
- 临时目录中的 TS 片段在重启后仍保留，但 `M3U8DownloadTask` 不知道哪些已下载

### Issue 10: M3U8 进度/速度计算使用片段计数而非字节数
- `updateProgress()` 中 `totalSize = Int64(totalSegments)`，`downloadedSize = Int64(completedSegments)`
- `SpeedCalculator.addSample(bytes: Int64(completed))` 传入的是片段数量，导致速度显示为 "5 B/s"
- 未跟踪每个 TS 片段的实际文件大小
- 总大小估算不准确（当前用 `totalDuration * 500000` 粗略估算）

---

## 文件结构变更

| 文件 | 操作 | 说明 |
|------|------|------|
| `DownLoad/Parsers/M3U8Models.swift` | 修改 | 扩展 `M3U8DownloadState` 增加字节跟踪字段 |
| `DownLoad/Utilities/Constants.swift` | 修改 | 新增状态文件名常量 |
| `DownLoad/Storage/DownloadTaskDatabase.swift` | 修改 | schema 升级到 v3，新增 `m3u8ResumeData` 列 |
| `DownLoad/Storage/FileStorageManager.swift` | 修改 | 新增 JSON 文件读写辅助方法 |
| `DownLoad/Handlers/M3U8DownloadHandler.swift` | 修改 | 核心修改：持久化、字节跟踪、恢复逻辑 |
| `DownLoad/Core/VideoDownloadEngine.swift` | 修改 | 支持 M3U8 数据库恢复，保存 m3u8ResumeData |
| `DownLoadTests/SpeedCalculatorTests.swift` | 新增测试 | M3U8 字节级进度场景测试 |

---

## Task 1: 扩展 `M3U8DownloadState` 支持字节跟踪

**文件：**
- 修改: `DownLoad/DownLoad/Parsers/M3U8Models.swift`

- [ ] **Step 1: 修改 `M3U8DownloadState` 结构体**

```swift
/// M3U8下载状态
struct M3U8DownloadState: Codable {
    let totalSegments: Int
    var completedSegments: Set<Int>
    var failedSegments: Set<Int>
    var segmentURLs: [String]

    // 新增：字节级跟踪
    var segmentByteSizes: [Int: Int64]  // index -> 文件大小（字节）
    var totalEstimatedBytes: Int64?     // 估算总字节数

    // 新增：用于恢复时识别 playlist 是否变化
    var playlistIdentifier: String?     // 存储 playlist URL

    init(totalSegments: Int, segmentURLs: [String] = [], playlistIdentifier: String? = nil) {
        self.totalSegments = totalSegments
        self.completedSegments = []
        self.failedSegments = []
        self.segmentURLs = segmentURLs
        self.segmentByteSizes = [:]
        self.totalEstimatedBytes = nil
        self.playlistIdentifier = playlistIdentifier
    }

    var progress: Float {
        guard totalSegments > 0 else { return 0 }
        return Float(completedSegments.count) / Float(totalSegments)
    }

    /// 已下载字节总数
    var downloadedBytes: Int64 {
        return segmentByteSizes.values.reduce(0, +)
    }
}
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project DownLoad/DownLoad.xcodeproj -scheme DownLoad -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: 编译通过

---

## Task 2: 新增常量

**文件：**
- 修改: `DownLoad/DownLoad/Utilities/Constants.swift`

- [ ] **Step 1: 在 `Constants.M3U8` 中新增状态文件名**

```swift
struct Constants {
    // ... 现有内容保持不变 ...

    struct M3U8 {
        static let maxConcurrentSegmentDownloads = 6
        static let mergeBufferSize = 256 * 1024
        static let stateFileName = "download_state.json"  // 新增
    }
}
```

---

## Task 3: 数据库 Schema 升级（v2 -> v3）

**文件：**
- 修改: `DownLoad/DownLoad/Storage/DownloadTaskDatabase.swift`

- [ ] **Step 1: 升级 `DownloadTaskRecord` 新增 `m3u8ResumeData` 字段**

在 `DownloadTaskRecord` 结构体中新增字段：
```swift
public let m3u8ResumeData: String?  // 新增：存储状态文件路径
```

并在 `init` 方法中新增参数：
```swift
public init(
    id: UUID,
    url: String,
    fileName: String,
    state: String,
    progress: Float,
    totalSize: Int64? = nil,
    format: String = "mp4",
    resumeData: Data? = nil,
    downloadedSize: Int64 = 0,
    createdAt: Date = Date(),
    completedAt: Date? = nil,
    m3u8ResumeData: String? = nil  // 新增
) {
    // ... 现有赋值 ...
    self.m3u8ResumeData = m3u8ResumeData
}
```

- [ ] **Step 2: 升级数据库 schema**

将 `currentSchemaVersion` 从 2 改为 3：
```swift
private let currentSchemaVersion = 3
```

修改 `createTables()` 中的 CREATE TABLE 语句，新增 `m3u8ResumeData TEXT` 列：
```swift
let createTable = """
CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,
    url TEXT NOT NULL,
    fileName TEXT NOT NULL,
    state TEXT NOT NULL,
    progress REAL NOT NULL,
    totalSize INTEGER,
    format TEXT NOT NULL DEFAULT 'mp4',
    resumeData BLOB,
    downloadedSize INTEGER NOT NULL DEFAULT 0,
    createdAt REAL NOT NULL,
    completedAt REAL,
    m3u8ResumeData TEXT  -- 新增
);
"""
```

修改 `migrateIfNeeded()`：
```swift
private func migrateIfNeeded() throws {
    let version = try currentVersion()
    if version < 2 {
        try migrateV1ToV2()
        try setVersion(2)
    }
    if version < 3 {
        try migrateV2ToV3()
        try setVersion(3)
    }
}
```

新增 `migrateV2ToV3()`：
```swift
private func migrateV2ToV3() throws {
    let sql = "ALTER TABLE tasks ADD COLUMN m3u8ResumeData TEXT;"
    try exec(sql)
}
```

- [ ] **Step 3: 更新 `saveRecord` 方法**

修改 SQL 语句增加第 12 列：
```swift
let sql = """
INSERT OR REPLACE INTO tasks (
    id, url, fileName, state, progress,
    totalSize, format, resumeData, downloadedSize, createdAt, completedAt, m3u8ResumeData
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
"""
```

在绑定参数部分新增第 12 个参数（在 completedAt 绑定之后）：
```swift
if let completedAt = record.completedAt {
    sqlite3_bind_double(stmt, 11, completedAt.timeIntervalSince1970)
} else {
    sqlite3_bind_null(stmt, 11)
}
// 新增：
sqlite3_bind_text(stmt, 12, record.m3u8ResumeData, -1, nil)
```

- [ ] **Step 4: 更新 `queryRecords` 方法**

在读取列数据部分，在 `completedAt` 读取之后新增：
```swift
var m3u8ResumeData: String?
if sqlite3_column_type(stmt, 11) != SQLITE_NULL {
    m3u8ResumeData = String(cString: sqlite3_column_text(stmt, 11))
}
```

在 `DownloadTaskRecord` 初始化时传入：
```swift
let record = DownloadTaskRecord(
    id: id,
    url: url,
    fileName: fileName,
    state: state,
    progress: progress,
    totalSize: totalSize > 0 ? totalSize : nil,
    format: format,
    resumeData: resumeData,
    downloadedSize: downloadedSize,
    createdAt: createdAt,
    completedAt: completedAt,
    m3u8ResumeData: m3u8ResumeData  // 新增
)
```

- [ ] **Step 5: 更新 `DownloadTaskRecord` 扩展的 `init(from:)` 和 `toDownloadItem()`**

修改 `init(from:)`：
```swift
extension DownloadTaskRecord {
    init(from item: DownloadItem, m3u8ResumeData: String? = nil) {
        self.init(
            id: item.id,
            url: item.url,
            fileName: item.fileName,
            state: item.state.rawValue,
            progress: item.totalSize.map { Float(item.downloadedSize) / Float($0) } ?? 0,
            totalSize: item.totalSize,
            format: item.format.rawValue,
            resumeData: item.resumeData,
            downloadedSize: item.downloadedSize,
            createdAt: item.createdAt,
            completedAt: item.completedAt,
            m3u8ResumeData: m3u8ResumeData  // 新增
        )
    }
    // toDownloadItem() 保持不变
}
```

---

## Task 4: `FileStorageManager` 新增 JSON 读写辅助方法

**文件：**
- 修改: `DownLoad/DownLoad/Storage/FileStorageManager.swift`

- [ ] **Step 1: 在 `FileStorageManager` 类末尾新增扩展**

```swift
// MARK: - JSON Persistence Helpers

extension FileStorageManager {
    /// 保存 Codable 对象为 JSON 文件
    func saveJSON<T: Codable>(_ object: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(object)
        try data.write(to: url, options: .atomic)
    }

    /// 从 JSON 文件加载 Codable 对象
    func loadJSON<T: Codable>(from url: URL, as type: T.Type) throws -> T {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
```

---

## Task 5: 重构 `M3U8DownloadHandler.swift`（核心修改）

**文件：**
- 修改: `DownLoad/DownLoad/Handlers/M3U8DownloadHandler.swift`

- [ ] **Step 1: 修改 `M3U8DownloadTask` 初始化，传入 playlistIdentifier**

在 `init` 中修改 `downloadState` 初始化：
```swift
self.downloadState = M3U8DownloadState(
    totalSegments: playlist.segments.count,
    segmentURLs: playlist.segments.map { $0.url.absoluteString },
    playlistIdentifier: playlist.segments.first?.url.absoluteString ?? url
)
```

- [ ] **Step 2: 新增状态文件 URL 和持久化方法**

在 `M3U8DownloadTask` 中新增属性：
```swift
var stateFileURL: URL? {
    let tempDir = storageManager.createTaskDirectory(taskId: id)
    return tempDir.appendingPathComponent(Constants.M3U8.stateFileName)
}

private func saveDownloadState() {
    guard let url = stateFileURL else { return }
    do {
        try storageManager.saveJSON(downloadState, to: url)
    } catch {
        Logger.error("Failed to save M3U8 download state: \(error)")
    }
}

private func loadDownloadState() -> M3U8DownloadState? {
    guard let url = stateFileURL,
          FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
        return try storageManager.loadJSON(from: url, as: M3U8DownloadState.self)
    } catch {
        Logger.error("Failed to load M3U8 download state: \(error)")
        return nil
    }
}
```

- [ ] **Step 3: 修改 `resume()` 支持状态恢复和字节校准**

将 `resume()` 方法替换为：
```swift
func resume() async throws {
    guard state.value != .downloading else { return }

    // 尝试恢复之前保存的状态
    if let savedState = loadDownloadState(),
       savedState.totalSegments == playlist.segments.count,
       savedState.playlistIdentifier == (playlist.segments.first?.url.absoluteString ?? url) {
        self.downloadState = savedState
        Logger.info("Restored M3U8 download state: \(savedState.completedSegments.count)/\(savedState.totalSegments) segments")
    }

    state.send(.downloading)

    task = Task {
        do {
            // 创建临时目录
            let tempDir = storageManager.createTaskDirectory(taskId: id)
            let segmentsDir = tempDir.appendingPathComponent("segments")
            try FileManager.default.createDirectory(at: segmentsDir, withIntermediateDirectories: true)

            // 预扫描已存在的片段，校准字节大小和 completedSegments
            await calibrateDownloadedBytes(segmentsDir: segmentsDir)

            // 并发下载TS片段
            let semaphore = AsyncSemaphore(limit: maxConcurrentSegments)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (index, segment) in playlist.segments.enumerated() {
                    // 跳过已完成的片段
                    if downloadState.completedSegments.contains(index) {
                        continue
                    }

                    await semaphore.wait()
                    group.addTask {
                        defer { Task { await semaphore.signal() } }

                        let segmentSize = try await self.downloadSegment(
                            segment,
                            index: index,
                            to: segmentsDir
                        )

                        // 记录实际字节大小
                        await self.recordSegmentSize(index: index, size: segmentSize)
                        await self.updateProgress()
                        self.saveDownloadState()
                    }
                }

                try await group.waitForAll()
            }

            // 合并TS片段
            let outputURL = try await mergeSegments(
                in: segmentsDir,
                to: storageManager.completedDirectory().appendingPathComponent(fileName)
            )

            // 清理临时文件
            try? storageManager.deleteFile(at: tempDir)

            self.completedURL = outputURL
            self.completedAt = Date()
            state.send(.completed)

        } catch is CancellationError {
            state.send(.paused)
            saveDownloadState()
        } catch {
            Logger.error("M3U8 download failed: \(error)")
            state.send(.failed)
            saveDownloadState()
            throw DownloadError.taskFailed(error)
        }
    }

    try await task?.value
}
```

- [ ] **Step 4: 修改 `downloadSegment` 返回实际字节数**

```swift
@discardableResult
private func downloadSegment(_ segment: M3U8Segment, index: Int, to directory: URL) async throws -> Int64 {
    // 下载数据
    var data = try await networkClient.downloadData(from: segment.url)

    // 解密（如果需要）
    if let encryption = segment.encryption, let key = encryptionKey {
        data = try decryptData(data, key: key, iv: encryption.iv)
    }

    // 保存片段
    let segmentURL = directory.appendingPathComponent("segment_\(String(format: "%05d", index)).ts")
    try data.write(to: segmentURL)

    return Int64(data.count)
}
```

- [ ] **Step 5: 新增字节跟踪和校准方法**

```swift
private func recordSegmentSize(index: Int, size: Int64) {
    downloadState.segmentByteSizes[index] = size

    // 渐进式估算总大小
    if downloadState.totalEstimatedBytes == nil,
       downloadState.segmentByteSizes.count >= 3 {
        let avgSize = downloadState.downloadedBytes / Int64(downloadState.segmentByteSizes.count)
        downloadState.totalEstimatedBytes = avgSize * Int64(downloadState.totalSegments)
    }
}

private func calibrateDownloadedBytes(segmentsDir: URL) async {
    for i in 0..<playlist.segments.count {
        let segmentURL = segmentsDir.appendingPathComponent("segment_\(String(format: "%05d", i)).ts")
        if FileManager.default.fileExists(atPath: segmentURL.path) {
            let size = storageManager.fileSize(at: segmentURL)
            if size > 0 {
                downloadState.segmentByteSizes[i] = size
                downloadState.completedSegments.insert(i)
            }
        }
    }

    // 校准总估算大小
    if !downloadState.segmentByteSizes.isEmpty {
        let avgSize = downloadState.downloadedBytes / Int64(downloadState.segmentByteSizes.count)
        downloadState.totalEstimatedBytes = avgSize * Int64(downloadState.totalSegments)
    }
}
```

- [ ] **Step 6: 重写 `updateProgress()` 使用字节数**

```swift
private func updateProgress() async {
    let completed = downloadState.completedSegments.count
    let total = downloadState.totalSegments
    let progressValue = Float(completed) / Float(total)

    let downloadedBytes = downloadState.downloadedBytes
    let totalBytes = downloadState.totalEstimatedBytes ?? Int64(total) * 1_000_000

    self.totalSize = totalBytes
    self.downloadedSize = downloadedBytes

    let now = Date().timeIntervalSince1970
    speedCalculator.addSample(bytes: downloadedBytes, timestamp: now)
    let speed = speedCalculator.calculateSpeed()
    let remaining = speedCalculator.calculateRemainingTime(totalBytes: totalBytes, downloadedBytes: downloadedBytes)

    let progressInfo = DownloadProgress(
        taskId: id,
        totalBytes: totalBytes,
        downloadedBytes: downloadedBytes,
        progress: progressValue,
        speed: speed,
        remainingTime: remaining
    )

    progress.send(progressInfo)
}
```

- [ ] **Step 7: 修改 `pause()` 和 `cancel()`**

```swift
func pause() async {
    task?.cancel()
    saveDownloadState()
    state.send(.paused)
}

func cancel() async {
    task?.cancel()

    // 清理临时文件
    let tempDir = storageManager.createTaskDirectory(taskId: id)
    try? storageManager.deleteFile(at: tempDir)

    state.send(.cancelled)
}
```

---

## Task 6: 支持 M3U8 数据库恢复

**文件：**
- 修改: `DownLoad/DownLoad/Core/VideoDownloadEngine.swift`

- [ ] **Step 1: 修改 `persistTask` 保存 M3U8 状态路径**

```swift
private func persistTask(_ task: any DownloadTask) {
    if let mp4Task = task as? MP4DownloadTask {
        let record = DownloadTaskRecord(from: mp4Task.toDownloadItem())
        try? database.saveRecord(record)
    } else if let m3u8Task = task as? M3U8DownloadTask {
        let record = DownloadTaskRecord(
            from: m3u8Task.toDownloadItem(),
            m3u8ResumeData: m3u8Task.stateFileURL?.path
        )
        try? database.saveRecord(record)
    }
}
```

- [ ] **Step 2: 修改 `restoreTasksFromDatabase()` 支持 M3U8 恢复**

将 `.m3u8` case 的 `continue` 替换为恢复逻辑：
```swift
case .m3u8:
    do {
        guard let m3u8URL = URL(string: item.url) else {
            Logger.error("Invalid M3U8 URL for restored task: \(item.id)")
            continue
        }

        // 重新解析 M3U8
        let m3u8Content = try await networkClient.downloadString(from: m3u8URL)
        let playlist = try M3U8Parser().parse(content: m3u8Content, baseURL: m3u8URL)

        let mediaPlaylist: M3U8MediaPlaylist
        if let masterPlaylist = playlist as? M3U8MasterPlaylist {
            let variant = masterPlaylist.selectBestVariant()
            let variantContent = try await networkClient.downloadString(from: variant.url)
            mediaPlaylist = try M3U8Parser().parse(content: variantContent, baseURL: variant.url) as! M3U8MediaPlaylist
        } else {
            mediaPlaylist = playlist as! M3U8MediaPlaylist
        }

        // 恢复加密密钥
        var encryptionKey: Data?
        if mediaPlaylist.isEncrypted, let encryption = mediaPlaylist.segments.first?.encryption {
            encryptionKey = try await networkClient.downloadData(from: encryption.keyURL)
        }

        let task = M3U8DownloadTask(
            id: item.id,
            url: item.url,
            playlist: mediaPlaylist,
            encryptionKey: encryptionKey,
            fileName: item.fileName,
            configuration: .default,
            networkClient: networkClient,
            storageManager: storageManager
        )

        task.totalSize = item.totalSize
        task.downloadedSize = item.downloadedSize
        task.completedAt = item.completedAt

        restoredTask = task
    } catch {
        Logger.error("Failed to restore M3U8 task \(item.id): \(error)")
        continue
    }
```

---

## Task 7: 编译验证

- [ ] **Step 1: 编译项目**

Run: `xcodebuild -project DownLoad/DownLoad.xcodeproj -scheme DownLoad -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: 编译通过，无错误

---

## Task 8: 更新测试

**文件：**
- 修改: `DownLoad/DownLoadTests/SpeedCalculatorTests.swift`

- [ ] **Step 1: 新增 M3U8 字节级进度测试**

在 `SpeedCalculatorTests` 中新增：
```swift
@Test("M3U8 进度使用字节而非片段计数")
func testM3U8ByteProgress() {
    let calculator = SpeedCalculator()

    // 模拟下载 3 个片段，每个 1MB
    calculator.addSample(bytes: 0, timestamp: 0)
    calculator.addSample(bytes: 3_145_728, timestamp: 3)  // 3MB in 3s

    let speed = calculator.calculateSpeed()
    #expect(speed == 1_048_576, "速度应为 1MB/s，实际为 \(speed)")
}
```

- [ ] **Step 2: 运行测试**

Run: `xcodebuild -project DownLoad/DownLoad.xcodeproj -scheme DownLoad -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: 所有测试通过

---

## 验证清单

- [ ] `M3U8Models.swift` 编译通过，`M3U8DownloadState` 可正常 `JSONEncoder` 编解码
- [ ] `Constants.swift` 新增 `stateFileName`
- [ ] `DownloadTaskDatabase.swift` schema 升级到 v3，`m3u8ResumeData` 列可读写
- [ ] `FileStorageManager.swift` 新增 `saveJSON` / `loadJSON` 编译通过
- [ ] `M3U8DownloadHandler.swift`：
  - [ ] 暂停后 `download_state.json` 存在于任务目录
  - [ ] 恢复时正确加载 `completedSegments` 和 `segmentByteSizes`
  - [ ] `updateProgress()` 中 `speedCalculator.addSample(bytes:)` 传入字节数
  - [ ] 进度条显示正确百分比和 MB/s 速度
- [ ] `VideoDownloadEngine.swift`：
  - [ ] `restoreTasksFromDatabase()` 不再跳过 `.m3u8` 任务
  - [ ] 恢复后任务可正常 `resume()` 继续下载
- [ ] 所有单元测试通过
