# P2 问题 22/23 修复实现计划

> **目标：** 修复存储空间持续监控缺失和缓存清理机制未实现的问题

**涉及问题：**
- 问题 22：存储空间检查仅执行一次，下载过程中无持续监控
- 问题 23：缓存清理机制未实现（`maxCacheSize` 和 `cacheExpirationDays` 已定义但从未使用）

**架构：** 在 `FileStorageManager` 中新增存储空间监控和缓存清理能力；在 `MP4DownloadTask`/`M3U8DownloadTask` 下载过程中周期性检查空间；在 `VideoDownloadEngine` 和 `AppDelegate` 中集成自动缓存清理触发。

**技术栈：** Swift, Foundation, Combine

---

## 当前状态分析

### 问题 22 现状
- `FileStorageManager.checkAvailableSpace` 仅在 `MP4DownloadHandler.createTask`（第 40 行）和 `M3U8DownloadHandler.createTask`（第 69 行）中各调用一次
- 下载开始后，如果设备存储空间被其他应用占用导致不足，下载任务会继续执行直到系统层面写入失败
- 造成无效网络流量浪费、临时文件残留、用户体验差

### 问题 23 现状
- `Constants.Storage.maxCacheSize = 1GB` 和 `cacheExpirationDays = 30` 已定义但从未使用
- `FileStorageManager` 有 `cacheDirectory()` 方法但无任何缓存管理逻辑
- 缓存目录中的临时文件会无限累积

---

## 任务 1：FileStorageManager 新增存储空间监控和缓存清理能力

**文件：** `DownLoad/DownLoad/Storage/FileStorageManager.swift`

### Step 1.1：新增存储空间监控相关类型和方法

在 `FileStorageManager` 类中，在 `// MARK: - JSON Persistence Helpers` 之前添加：

```swift
// MARK: - Storage Space Monitoring

/// 检查是否有足够空间用于继续下载
/// - Parameters:
///   - requiredBytes: 还需要下载的字节数
///   - bufferRatio: 缓冲比例（默认10%）
/// - Returns: 是否有足够空间
func hasEnoughSpaceForContinue(requiredBytes: Int64, bufferRatio: Double = 0.1) -> Bool {
    let requiredWithBuffer = requiredBytes + Int64(Double(requiredBytes) * bufferRatio)
    let available = availableStorageSpace()
    return available >= requiredWithBuffer
}

/// 获取指定任务还需要的存储空间
func requiredSpaceForTask(totalSize: Int64?, downloadedSize: Int64) -> Int64 {
    guard let total = totalSize else {
        return Constants.Storage.defaultMP4SpaceRequirement
    }
    return max(0, total - downloadedSize)
}
```

### Step 1.2：新增缓存清理方法

在 `FileStorageManager` 类中，在 Step 1.1 代码之后继续添加：

```swift
// MARK: - Cache Management

/// 获取缓存目录总大小（字节）
func getCacheSize() -> Int64 {
    let cacheDir = cacheDirectory()
    return directorySize(at: cacheDir)
}

/// 获取缓存文件年龄（天数）
func getCacheFileAge(_ url: URL) -> Int? {
    do {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let modificationDate = attributes[.modificationDate] as? Date {
            let age = Date().timeIntervalSince(modificationDate)
            return Int(age / (24 * 60 * 60))
        }
    } catch {
        Logger.error("Failed to get cache file age: \(error)")
    }
    return nil
}

/// 清理过期缓存文件
/// - Returns: 清理的文件数量和释放的总字节数
func cleanExpiredCache() -> (deletedCount: Int, freedBytes: Int64) {
    let cacheDir = cacheDirectory()
    var deletedCount = 0
    var freedBytes: Int64 = 0

    guard fileManager.fileExists(atPath: cacheDir.path) else {
        return (0, 0)
    }

    let expirationInterval = TimeInterval(Constants.Storage.cacheExpirationDays * 24 * 60 * 60)
    let now = Date()

    let result = cleanExpiredCache(in: cacheDir, expirationInterval: expirationInterval, now: now)
    deletedCount += result.deletedCount
    freedBytes += result.freedBytes

    Logger.info("Cleaned expired cache: \(deletedCount) files, freed \(ByteCountFormatter.string(fromByteCount: freedBytes, countStyle: .file))")
    return (deletedCount, freedBytes)
}

/// 递归清理指定目录中的过期缓存
private func cleanExpiredCache(in directory: URL, expirationInterval: TimeInterval, now: Date) -> (deletedCount: Int, freedBytes: Int64) {
    var deletedCount = 0
    var freedBytes: Int64 = 0

    guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
        return (0, 0)
    }

    for fileURL in contents {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else { continue }

        if isDirectory.boolValue {
            let subResult = cleanExpiredCache(in: fileURL, expirationInterval: expirationInterval, now: now)
            deletedCount += subResult.deletedCount
            freedBytes += subResult.freedBytes

            // 删除空目录
            if let subContents = try? fileManager.contentsOfDirectory(at: fileURL, includingPropertiesForKeys: nil),
               subContents.isEmpty {
                try? fileManager.removeItem(at: fileURL)
            }
        } else {
            if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
               let modificationDate = attributes[.modificationDate] as? Date {
                if now.timeIntervalSince(modificationDate) > expirationInterval {
                    let fileSize = self.fileSize(at: fileURL)
                    try? fileManager.removeItem(at: fileURL)
                    freedBytes += fileSize
                    deletedCount += 1
                    Logger.info("Deleted expired cache file: \(fileURL.lastPathComponent)")
                }
            }
        }
    }

    return (deletedCount, freedBytes)
}

/// 强制缓存大小限制（LRU策略：按最久未访问顺序删除）
/// - Returns: 删除的文件数量和释放的总字节数
func enforceCacheSizeLimit() -> (deletedCount: Int, freedBytes: Int64) {
    let maxSize = Constants.Storage.maxCacheSize
    let currentSize = getCacheSize()

    guard currentSize > maxSize else {
        return (0, 0)
    }

    let targetSize = Int64(Double(maxSize) * 0.8) // 清理到80%阈值
    var bytesToFree = currentSize - targetSize
    var deletedCount = 0
    var freedBytes: Int64 = 0

    let cacheDir = cacheDirectory()

    // 收集所有缓存文件及其访问时间
    var files: [(url: URL, modificationDate: Date, size: Int64)] = []
    collectCacheFiles(in: cacheDir, into: &files)

    // 按修改时间排序（最久未访问的在前）
    files.sort { $0.modificationDate < $1.modificationDate }

    // 删除最久未访问的文件直到低于阈值
    for file in files {
        guard bytesToFree > 0 else { break }

        do {
            try fileManager.removeItem(at: file.url)
            freedBytes += file.size
            bytesToFree -= file.size
            deletedCount += 1
            Logger.info("Deleted cache file for size limit: \(file.url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)))")
        } catch {
            Logger.error("Failed to delete cache file \(file.url.path): \(error)")
        }
    }

    Logger.info("Enforced cache size limit: \(deletedCount) files deleted, \(ByteCountFormatter.string(fromByteCount: freedBytes, countStyle: .file)) freed")
    return (deletedCount, freedBytes)
}

/// 递归收集缓存文件信息
private func collectCacheFiles(in directory: URL, into files: inout [(url: URL, modificationDate: Date, size: Int64)]) {
    guard let contents = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else { return }

    for fileURL in contents {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else { continue }

        if isDirectory.boolValue {
            collectCacheFiles(in: fileURL, into: &files)
        } else {
            if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
               let modificationDate = attributes[.modificationDate] as? Date {
                let size = fileSize(at: fileURL)
                files.append((url: fileURL, modificationDate: modificationDate, size: size))
            }
        }
    }
}

/// 执行完整缓存清理（先清理过期，再强制大小限制）
/// - Returns: 清理结果汇总
func performFullCacheCleanup() -> (deletedCount: Int, freedBytes: Int64) {
    Logger.info("Starting full cache cleanup...")

    let expiredResult = cleanExpiredCache()
    let sizeResult = enforceCacheSizeLimit()

    let totalDeleted = expiredResult.deletedCount + sizeResult.deletedCount
    let totalFreed = expiredResult.freedBytes + sizeResult.freedBytes

    Logger.info("Full cache cleanup completed: \(totalDeleted) files deleted, \(ByteCountFormatter.string(fromByteCount: totalFreed, countStyle: .file)) freed")
    return (totalDeleted, totalFreed)
}
```

### Step 1.3：验证编译

运行 `xcodebuild` 或 Xcode 编译，确认 `FileStorageManager.swift` 无编译错误。

---

## 任务 2：MP4DownloadTask 添加下载中存储空间检查

**文件：** `DownLoad/DownLoad/Handlers/MP4DownloadHandler.swift`

### Step 2.1：新增存储空间检查辅助方法

在 `MP4DownloadTask` 类中，在 `// MARK: - 前台下载（原有逻辑）` 之前添加：

```swift
// MARK: - Storage Space Check During Download

/// 检查是否有足够空间继续下载，空间不足时自动暂停
private func checkStorageSpaceDuringDownload(downloaded: Int64, total: Int64) {
    let remainingBytes = total - downloaded
    if remainingBytes > 0,
       !storageManager.hasEnoughSpaceForContinue(requiredBytes: remainingBytes) {
        Logger.warning("Storage space insufficient during MP4 download, pausing task: \(id)")
        Task { [weak self] in
            guard let self = self else { return }
            await self.pause(reason: .insufficientStorage)
        }
    }
}
```

### Step 2.2：在前台下载进度回调中添加空间检查

修改 `resumeWithForegroundDownload()` 方法中的 progress 回调（约第 161 行）：

在 `guard let self = self else { return }` 之后，原有进度计算代码之前，插入：

```swift
// 存储空间持续监控
self.checkStorageSpaceDuringDownload(downloaded: downloaded, total: total)
```

修改后的 progress 回调结构：

```swift
progress: { [weak self] downloaded, total in
    guard let self = self else { return }

    // 存储空间持续监控
    self.checkStorageSpaceDuringDownload(downloaded: downloaded, total: total)

    let now = Date().timeIntervalSince1970
    self.speedCalculator.addSample(bytes: downloaded, timestamp: now)
    let speed = self.speedCalculator.calculateSpeed()
    let remaining = self.speedCalculator.calculateRemainingTime(totalBytes: total, downloadedBytes: downloaded)

    // ... 后续原有代码不变
```

### Step 2.3：在后台下载进度回调中添加空间检查

修改 `resumeWithBackgroundDownload()` 方法中的所有 progress 回调（共有 3 处，约第 248、284、320 行）。

在每处 progress 回调的 `guard let self = self else { return }` 之后，原有进度计算代码之前，插入：

```swift
// 存储空间持续监控
self.checkStorageSpaceDuringDownload(downloaded: downloaded, total: total)
```

### Step 2.4：验证编译

确认 `MP4DownloadHandler.swift` 无编译错误。

---

## 任务 3：M3U8DownloadTask 添加下载中存储空间检查

**文件：** `DownLoad/DownLoad/Handlers/M3U8DownloadHandler.swift`

### Step 3.1：新增估算剩余字节方法

在 `M3U8DownloadTask` 类的 `// MARK: - Private Methods` 区域中，在 `downloadMapSegment` 方法之前添加：

```swift
/// 估算还需要下载的字节数
private func estimateRemainingBytes() -> Int64 {
    let completedCount = downloadState.completedSegments.count
    let remainingCount = playlist.segments.count - completedCount

    if let totalEstimated = downloadState.totalEstimatedBytes,
       totalEstimated > 0,
       playlist.segments.count > 0 {
        let avgSize = totalEstimated / Int64(playlist.segments.count)
        return avgSize * Int64(remainingCount)
    } else {
        // 粗略估算：500KB/片段
        return Int64(remainingCount) * 500_000
    }
}
```

### Step 3.2：在片段下载前添加空间检查

修改 `downloadSegment` 方法（约第 328 行），在方法开头添加：

```swift
@discardableResult
private func downloadSegment(_ segment: M3U8Segment, index: Int, to directory: URL) async throws -> Int64 {
    // 下载前检查空间
    let estimatedRemaining = estimateRemainingBytes()
    if estimatedRemaining > 0,
       !storageManager.hasEnoughSpaceForContinue(requiredBytes: estimatedRemaining) {
        Logger.warning("Storage space insufficient before downloading segment \(index), pausing M3U8 task: \(id)")
        throw DownloadError.insufficientStorage(
            required: estimatedRemaining,
            available: storageManager.availableStorageSpace()
        )
    }

    var data: Data
    // ... 后续原有代码不变
```

### Step 3.3：在 resume 错误处理中区分存储空间不足

修改 `resume()` 方法的 catch 块（约第 250 行）：

将原有：

```swift
} catch is CancellationError {
    state.send(.paused)
    saveDownloadState()
} catch {
    Logger.error("M3U8 download failed: \(error)")
    state.send(.failed)
    saveDownloadState()
    throw DownloadError.taskFailed(error)
}
```

替换为：

```swift
} catch is CancellationError {
    state.send(.paused)
    saveDownloadState()
} catch let error as DownloadError {
    if case .insufficientStorage = error {
        Logger.error("M3U8 download paused due to insufficient storage: \(id)")
        // 清理临时文件
        let tempDir = storageManager.createTaskDirectory(taskId: id)
        try? storageManager.deleteFile(at: tempDir)
        state.send(.failed)
    } else {
        Logger.error("M3U8 download failed: \(error)")
        state.send(.failed)
    }
    saveDownloadState()
} catch {
    Logger.error("M3U8 download failed: \(error)")
    state.send(.failed)
    saveDownloadState()
    throw DownloadError.taskFailed(error)
}
```

### Step 3.4：验证编译

确认 `M3U8DownloadHandler.swift` 无编译错误。

---

## 任务 4：DownloadError 新增 insufficientStorage 错误类型

**文件：** `DownLoad/DownLoad/Errors/DownloadError.swift`

### Step 4.1：添加 insufficientStorage 错误 case

找到 `DownloadError` 枚举定义，添加新 case：

```swift
case insufficientStorage(required: Int64, available: Int64)
```

### Step 4.2：在 LocalizedError 实现中添加描述

在 `errorDescription` 的 switch 中添加：

```swift
case .insufficientStorage(let required, let available):
    return "存储空间不足。需要: \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)), 可用: \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))"
```

### Step 4.3：验证编译

确认 `DownloadError.swift` 无编译错误。

---

## 任务 5：PauseReason 新增 insufficientStorage

**文件：** `DownLoad/DownLoad/Protocols/DownloadTaskProtocol.swift`

### Step 5.1：添加新 case

找到 `PauseReason` 枚举定义，在 `cellularRestricted` 之后添加：

```swift
case insufficientStorage // 存储空间不足自动暂停
```

### Step 5.2：验证编译

确认 `DownloadTaskProtocol.swift` 无编译错误。

---

## 任务 6：VideoDownloadEngine 集成缓存清理触发

**文件：** `DownLoad/DownLoad/Core/VideoDownloadEngine.swift`

### Step 6.1：新增缓存清理触发方法

在 `VideoDownloadEngine` 类中，在 `// MARK: - Database Persistence` 之前添加：

```swift
// MARK: - Cache Cleanup

/// 触发缓存清理（在任务完成/取消/删除后调用）
private func triggerCacheCleanup() {
    Task(priority: .background) {
        let result = storageManager.performFullCacheCleanup()
        if result.deletedCount > 0 {
            Logger.info("Post-download cache cleanup: removed \(result.deletedCount) files, freed \(ByteCountFormatter.string(fromByteCount: result.freedBytes, countStyle: .file))")
        }
    }
}
```

### Step 6.2：在任务状态监听中触发缓存清理

修改 `observeTaskForDatabase` 方法（约第 310 行），在 `self.persistTask(task)` 之后、判断状态之前，添加缓存清理触发：

```swift
private func observeTaskForDatabase(_ task: any DownloadTask) {
    let taskId = task.id

    let cancellable = task.state
        .dropFirst()
        .debounce(for: .seconds(0.5), scheduler: DispatchQueue.global(qos: .utility))
        .sink { [weak self] newState in
            guard let self = self else { return }
            Task {
                self.persistTask(task)
                if newState == .completed || newState == .failed || newState == .cancelled {
                    self.databaseCancellables.removeValue(forKey: taskId)
                    // 任务结束（完成/失败/取消）后触发缓存清理
                    self.triggerCacheCleanup()
                }
            }
        }

    databaseCancellables[taskId] = cancellable
}
```

### Step 6.3：在删除任务和清空下载时触发缓存清理

修改 `deleteDownloadTask` 方法（约第 254 行），在 `deleteTaskRecord(task.id)` 之后添加：

```swift
// 清理临时文件（即使已完成也检查）
let tempDirectory = storageManager.createTaskDirectory(taskId: task.id)
try? storageManager.deleteFile(at: tempDirectory)

// 触发缓存清理
triggerCacheCleanup()
```

修改 `clearAllDownloads` 方法（约第 290 行），在 `try? database.deleteAllRecords()` 之后添加：

```swift
// 触发缓存清理
triggerCacheCleanup()
```

### Step 6.4：验证编译

确认 `VideoDownloadEngine.swift` 无编译错误。

---

## 任务 7：AppDelegate 启动时触发缓存清理

**文件：** `DownLoad/DownLoad/AppDelegate.swift`

### Step 7.1：在启动方法中添加缓存清理

找到 `application(_:didFinishLaunchingWithOptions:)` 方法，在 `await VideoDownloadEngine.shared.restoreTasksFromDatabase()` 之前添加：

```swift
// 启动时执行缓存清理
let cacheResult = FileStorageManager().performFullCacheCleanup()
if cacheResult.deletedCount > 0 {
    Logger.info("Startup cache cleanup: removed \(cacheResult.deletedCount) files, freed \(ByteCountFormatter.string(fromByteCount: cacheResult.freedBytes, countStyle: .file))")
}
```

### Step 7.2：验证编译

确认 `AppDelegate.swift` 无编译错误。

---

## 任务 8：更新缺陷修复优先级排序文档

**文件：** `/Users/hubin/Desktop/MutiDownload/缺陷修复优先级排序.md`

### Step 8.1：标记问题 22 和 23 为已修复

找到 P2 区域的问题 22 和 23，将行内容更新为：

```markdown
| 22 | ~~存储空间检查仅执行一次，下载过程中无持续监控~~ ✅ 已修复 (2026-06-20) | `FileStorageManager.swift`、`MP4DownloadHandler.swift`、`M3U8DownloadHandler.swift`、`DownloadError.swift`、`DownloadTaskProtocol.swift` | `FileStorageManager` 新增 `hasEnoughSpaceForContinue` 和 `requiredSpaceForTask`；`MP4DownloadTask` 在前后台下载进度回调中调用 `checkStorageSpaceDuringDownload`，空间不足时自动 `pause(reason: .insufficientStorage)`；`M3U8DownloadTask` 在 `downloadSegment` 前检查空间，不足时抛出 `DownloadError.insufficientStorage` 并清理临时文件；`PauseReason` 新增 `insufficientStorage`。编译通过。 |
| 23 | ~~缓存清理机制未实现~~ ✅ 已修复 (2026-06-20) | `FileStorageManager.swift`、`VideoDownloadEngine.swift`、`AppDelegate.swift` | `FileStorageManager` 新增 `getCacheSize()`、`getCacheFileAge()`、`cleanExpiredCache()`（按过期天数清理）、`enforceCacheSizeLimit()`（LRU 策略清理到 80% 阈值）、`performFullCacheCleanup()`（组合调用）；`VideoDownloadEngine` 在 `observeTaskForDatabase` 任务结束、删除任务、清空下载时调用 `triggerCacheCleanup()`；`AppDelegate` 启动时执行缓存清理。编译通过。 |
```

---

## 验证步骤

### 编译验证
1. 在 Xcode 中 Build 整个项目，确认无编译错误
2. 特别关注 `FileStorageManager.swift`、`MP4DownloadHandler.swift`、`M3U8DownloadHandler.swift`、`DownloadError.swift`、`DownloadTaskProtocol.swift`、`VideoDownloadEngine.swift`、`AppDelegate.swift`

### 功能验证 - 问题 22
1. **MP4 空间检查**：创建 MP4 下载任务，在下载过程中模拟存储空间不足（可通过在设备上安装大应用填充空间），验证任务自动暂停，`pauseReason` 为 `.insufficientStorage`
2. **M3U8 空间检查**：创建 M3U8 下载任务，在片段下载过程中模拟空间不足，验证任务失败并清理临时文件
3. **临时文件清理**：验证空间不足后，对应任务的临时目录被清理

### 功能验证 - 问题 23
1. **过期缓存清理**：在缓存目录中创建修改日期超过 30 天的文件，调用 `cleanExpiredCache()`，验证过期文件被删除
2. **缓存大小限制**：在缓存目录中创建总大小超过 1GB 的文件，调用 `enforceCacheSizeLimit()`，验证按 LRU 顺序删除至 800MB 以下
3. **启动清理**：启动 App，验证 `performFullCacheCleanup()` 被自动调用
4. **任务结束后清理**：完成/取消/删除下载任务后，验证缓存清理被触发

---

## 文件修改清单

| 文件 | 修改类型 | 修改内容 |
|------|----------|----------|
| `FileStorageManager.swift` | 新增 | `hasEnoughSpaceForContinue`、`requiredSpaceForTask` |
| `FileStorageManager.swift` | 新增 | `getCacheSize()`、`getCacheFileAge(_:)`、`cleanExpiredCache()`、`enforceCacheSizeLimit()`、`performFullCacheCleanup()` 及相关私有辅助方法 |
| `MP4DownloadHandler.swift` | 新增 | `checkStorageSpaceDuringDownload(downloaded:total:)` |
| `MP4DownloadHandler.swift` | 修改 | 前台/后台下载 progress 回调中添加空间检查 |
| `M3U8DownloadHandler.swift` | 新增 | `estimateRemainingBytes()` |
| `M3U8DownloadHandler.swift` | 修改 | `downloadSegment` 开头添加空间检查 |
| `M3U8DownloadHandler.swift` | 修改 | `resume()` 错误处理中区分 `insufficientStorage` |
| `DownloadError.swift` | 新增 | `insufficientStorage(required:available:)` case 及描述 |
| `DownloadTaskProtocol.swift` | 新增 | `PauseReason.insufficientStorage` |
| `VideoDownloadEngine.swift` | 新增 | `triggerCacheCleanup()` |
| `VideoDownloadEngine.swift` | 修改 | `observeTaskForDatabase` 任务结束时触发缓存清理 |
| `VideoDownloadEngine.swift` | 修改 | `deleteDownloadTask`、`clearAllDownloads` 中调用缓存清理和临时文件清理 |
| `AppDelegate.swift` | 修改 | `didFinishLaunchingWithOptions` 中调用启动缓存清理 |
| `缺陷修复优先级排序.md` | 修改 | 标记问题 22、23 为已修复 |
