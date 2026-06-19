# P0-1 & P0-2 缺陷修复计划：M3U8 并发限制 + 流式合并

> **目标**：修复 `缺陷修复优先级排序.md` 中 P0 的第 1 项和第 2 项缺陷：
> - **P0-1**：M3U8 并发下载无限制，可能导致内存溢出/App 崩溃
> - **P0-2**：M3U8 合并片段全部加载到内存，大文件会 OOM

---

## 当前状态分析

### P0-1：M3U8 并发下载无限制

**文件**：`DownLoad/DownLoad/Handlers/M3U8DownloadHandler.swift`

**问题代码**（第 130-149 行）：

```swift
try await withThrowingTaskGroup(of: Void.self) { group in
    for (index, segment) in playlist.segments.enumerated() {
        if downloadState.completedSegments.contains(index) { continue }
        group.addTask {
            try await self.downloadSegment(segment, index: index, to: segmentsDir)
            await self.updateProgress(index: index)
        }
    }
    try await group.waitForAll()
}
```

**问题**：`withThrowingTaskGroup` 会为所有片段同时创建并发任务。一个典型的 M3U8 视频可能有数百甚至数千个 TS 片段，每个片段下载都会占用内存和网络连接，导致：
- 大量并发网络请求，系统 socket 耗尽
- 所有片段的 `Data` 同时驻留内存
- 内存暴涨，App 被 iOS 系统杀掉（OOM）

### P0-2：合并片段全部加载到内存

**问题代码**（第 237-257 行）：

```swift
private func mergeSegments(in directory: URL, to outputURL: URL) async throws -> URL {
    FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: nil)
    let outputHandle = try FileHandle(forWritingTo: outputURL)
    defer { outputHandle.closeFile() }

    for i in 0..<playlist.segments.count {
        let segmentURL = directory.appendingPathComponent("segment_\(String(format: "%05d", i)).ts")
        if FileManager.default.fileExists(atPath: segmentURL.path) {
            let data = try Data(contentsOf: segmentURL)  // ← 整个片段加载到内存
            outputHandle.write(data)
        }
    }
    return outputURL
}
```

**问题**：`Data(contentsOf:)` 将每个 TS 片段完整加载到内存。一个 2GB 的视频可能有数千个片段，虽然单次只有一个片段在内存中，但 `FileHandle.write(data)` 在 Swift 中会复制 data，加上输出文件本身的缓冲，内存压力仍然很大。更关键的是，`outputHandle.write(_ data: Data)` 在写入大块数据时效率低，且 `Data(contentsOf:)` 对于大片段（有些 HLS 片段可达数 MB）会显著增加内存峰值。

**正确做法**：使用 `FileHandle` 读取源文件，通过固定大小的缓冲区流式复制到输出文件，避免将整个片段加载到内存。

---

## 修改文件清单

| 文件路径 | 操作 | 说明 |
|---------|------|------|
| `DownLoad/DownLoad/Handlers/M3U8DownloadHandler.swift` | 修改 | (1) 添加并发信号量控制 (2) 改用流式合并 |
| `DownLoad/DownLoad/Utilities/Constants.swift` | 修改 | 新增 M3U8 最大并发片段下载数常量 |
| `缺陷修复优先级排序.md` | 修改 | 记录 P0-1 和 P0-2 的修复状态 |

---

## Task 1：新增 M3U8 并发常量

### Step 1.1：修改 `Constants.swift`

在 `Constants` 结构体中新增 M3U8 相关常量：

```swift
struct M3U8 {
    static let maxConcurrentSegmentDownloads = 6  // M3U8片段最大并发下载数
    static let mergeBufferSize = 256 * 1024       // 流式合并缓冲区大小：256KB
}
```

**决策**：并发数设为 6，基于以下考虑：
- 太低（如 3）：下载速度慢，用户体验差
- 太高（如 20）：内存和网络压力大，可能触发系统限制
- 6 是一个平衡点，既保证下载速度，又控制资源消耗

---

## Task 2：修复 P0-1 — 添加并发信号量控制

### Step 2.1：修改 `M3U8DownloadHandler.swift` 的 `resume()` 方法

在 `M3U8DownloadTask` 类中添加信号量属性：

```swift
private let maxConcurrentSegments: Int
```

修改 `init` 方法，从 `configuration` 或 `Constants` 中获取并发限制值。

修改 `resume()` 方法中的 `withThrowingTaskGroup`，使用信号量限制并发：

```swift
try await withThrowingTaskGroup(of: Void.self) { group in
    let semaphore = AsyncSemaphore(limit: maxConcurrentSegments)

    for (index, segment) in playlist.segments.enumerated() {
        if downloadState.completedSegments.contains(index) { continue }

        await semaphore.wait()
        group.addTask {
            defer { semaphore.signal() }
            try await self.downloadSegment(segment, index: index, to: segmentsDir)
            await self.updateProgress(index: index)
        }
    }

    try await group.waitForAll()
}
```

### Step 2.2：实现 `AsyncSemaphore`

在 `M3U8DownloadHandler.swift` 文件底部（`AESDecryptor` 类之后）添加轻量级异步信号量：

```swift
/// 轻量级异步信号量，用于限制并发任务数
private actor AsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.count = limit
    }

    func wait() async {
        if count > 0 {
            count -= 1
        } else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    func signal() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            count += 1
        }
    }
}
```

**设计决策**：
- 使用 `actor` 保证线程安全，无需额外锁
- 使用 `CheckedContinuation` 实现异步等待，性能优于 `Task.sleep` 轮询
- `signal()` 优先唤醒等待者而非增加计数，避免饥饿

---

## Task 3：修复 P0-2 — 改用流式合并

### Step 3.1：重写 `mergeSegments` 方法

将 `Data(contentsOf:)` 替换为 `FileHandle` 流式读取：

```swift
private func mergeSegments(in directory: URL, to outputURL: URL) async throws -> URL {
    FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: nil)
    guard let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
        throw DownloadError.taskFailed(NSError(domain: "M3U8Merge", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法创建输出文件"]))
    }
    defer { outputHandle.closeFile() }

    let bufferSize = Constants.M3U8.mergeBufferSize

    for i in 0..<playlist.segments.count {
        let segmentURL = directory.appendingPathComponent("segment_\(String(format: "%05d", i)).ts")

        guard FileManager.default.fileExists(atPath: segmentURL.path) else { continue }
        guard let readHandle = try? FileHandle(forReadingFrom: segmentURL) else { continue }
        defer { readHandle.closeFile() }

        while true {
            guard let chunk = try? readHandle.read(upToCount: bufferSize) else { break }
            if chunk.isEmpty { break }
            outputHandle.write(chunk)
        }
    }

    return outputURL
}
```

**关键改进**：
- 使用 `FileHandle.read(upToCount:)` 按固定缓冲区大小（256KB）读取，内存峰值恒定
- 无论片段多大，内存使用量始终不超过 `bufferSize + 少量开销`
- 2GB 视频合并时内存峰值从可能的数百 MB 降至 ~256KB

---

## Task 4：验证

### 4.1 编译验证
- 执行 `xcodebuild build` 确保无编译错误

### 4.2 逻辑验证
- 确认 `AsyncSemaphore` 正确限制并发：同时运行的 `downloadSegment` 不超过 `maxConcurrentSegments`
- 确认 `mergeSegments` 使用流式读取：搜索代码中不再有 `Data(contentsOf:)` 调用
- 确认 `defer { semaphore.signal() }` 确保即使下载失败也会释放信号量

### 4.3 更新 `缺陷修复优先级排序.md`
- 为 P0-1 和 P0-2 添加修复记录（修复日期、修复内容、验证结果）

---

## 假设与决策

1. **并发数使用 `Constants.M3U8.maxConcurrentSegmentDownloads = 6`** — 平衡速度与资源消耗，未来可通过配置调整
2. **使用自定义 `AsyncSemaphore` 而非 `DispatchSemaphore`** — 避免在 async 上下文中使用同步阻塞原语导致的线程池耗尽
3. **缓冲区大小 256KB** — 足够大的 I/O 块保证吞吐量，足够小控制内存峰值
4. **`AsyncSemaphore` 定义为 `private actor`** — 仅在 `M3U8DownloadHandler.swift` 内部使用，不暴露给外部
5. **不修改 `downloadSegment` 方法本身** — 该方法逻辑正确（下载单个片段 + 解密 + 写入），问题在于并发控制层面
