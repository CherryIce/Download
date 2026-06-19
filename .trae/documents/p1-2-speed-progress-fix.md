# P1-2 修复计划：速度/剩余时间始终为0 + NetworkClient进度回调缺失

> **目标**：修复 NetworkClient 进度回调缺失（#3）和 SpeedCalculator 未被调用（#2），使下载过程中实时显示速度和剩余时间。

---

## 当前状态分析

### 问题根因

进度回调链路存在 **3处断裂**：

| # | 断裂位置 | 问题 |
|---|---------|------|
| 1 | `NetworkClient.downloadFile` | 使用 `completionHandler` API，下载过程中**不触发任何进度回调**，只在完成时调用 `progress(size, size)` |
| 2 | `MP4DownloadTask` / `M3U8DownloadTask` | **没有 SpeedCalculator 实例**，即使收到进度数据也无法计算速度 |
| 3 | `ResumableDownloadTask` | 虽然通过 `URLSessionDownloadDelegate` 正确接收了 `didWriteData`，但**没有 SpeedCalculator** |

### 完整链路（修复后目标）

```
URLSession delegate (didWriteData)
  → NetworkClient progress 回调（实时触发）
    → DownloadTask 中 SpeedCalculator.addSample()
      → calculateSpeed() + calculateRemainingTime()
        → DownloadProgress(speed, remainingTime)（真实值）
          → UI 显示
```

---

## 修改文件清单

### 1. `Network/NetworkClient.swift` — 添加 URLSessionDelegate 实时进度

**修改内容**：
- 让 `NetworkClient` 遵循 `URLSessionDownloadDelegate` 协议
- 创建一个使用 `self` 作为 delegate 的专用 `URLSession`（用于下载任务）
- 在 `downloadFile` 和 `downloadFileWithResume` 中，使用 delegate session 创建下载任务
- 在 `urlSession(_:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:)` 中调用 progress 回调
- 使用 `withCheckedContinuation` + `AsyncStream` 或回调变量桥接 delegate 回调与 async 接口

**关键设计**：
- `NetworkClient` 是 `actor`，但 `URLSessionDownloadDelegate` 是 `NSObjectProtocol`。解决方案：创建内部辅助类 `DownloadDelegate` 继承 `NSObject` 并实现 `URLSessionDownloadDelegate`，持有 progress 回调和 continuation
- `downloadFile` 方法为每次下载创建独立的 `DownloadDelegate` 实例和独立的 `URLSession`
- delegate 在 `didFinishDownloadingTo` 中 resume continuation，在 `didCompleteWithError` 中处理错误

### 2. `Handlers/MP4DownloadHandler.swift` — MP4DownloadTask 接入 SpeedCalculator

**修改内容**：
- `MP4DownloadTask` 新增 `private let speedCalculator = SpeedCalculator()` 属性
- 在 `resume()` 的 progress 回调闭包中：
  - 调用 `speedCalculator.addSample(bytes: downloaded, timestamp: Date().timeIntervalSince1970)`
  - 调用 `speedCalculator.calculateSpeed()` 获取速度
  - 调用 `speedCalculator.calculateRemainingTime(totalBytes: total, downloadedBytes: downloaded)` 获取剩余时间
  - 将真实值填入 `DownloadProgress(speed: speed, remainingTime: remaining)`
- 在 `pause()` / `cancel()` 中调用 `speedCalculator.reset()`

### 3. `Core/ResumableDownloadTask.swift` — 接入 SpeedCalculator

**修改内容**：
- 新增 `private let speedCalculator = SpeedCalculator()` 属性
- 在 `urlSession(_:downloadTask:didWriteData:...)` delegate 方法中：
  - 调用 `speedCalculator.addSample(bytes: totalBytesWritten, timestamp: Date().timeIntervalSince1970)`
  - 调用 `speedCalculator.calculateSpeed()` 和 `calculateRemainingTime()`
  - 填入真实值

### 4. `Handlers/M3U8DownloadHandler.swift` — M3U8DownloadTask 接入 SpeedCalculator

**修改内容**：
- `M3U8DownloadTask` 新增 `private let speedCalculator = SpeedCalculator()` 属性
- 在 `updateProgress(index:)` 中：
  - 调用 `speedCalculator.addSample(bytes: Int64(completed), timestamp: Date().timeIntervalSince1970)`
  - 计算速度和剩余时间
  - 填入真实值
- 注意：M3U8 的 totalBytes 和 downloadedBytes 单位是"片段数"而非字节数，速度单位变为"片段/秒"，remainingTime 仍然有意义

### 5. `DownLoadTests/SpeedCalculatorTests.swift` — 新增 SpeedCalculator 单元测试

**新增文件**，测试内容：
- `testAddSampleAndCalculateSpeed` — 添加样本后速度计算正确
- `testSingleSampleReturnsZero` — 单个样本返回0
- `testCalculateRemainingTime` — 剩余时间计算正确
- `testResetClearsSamples` — 重置后样本清空
- `testFormatSpeed` — 格式化输出正确
- `testFormatTime` — 时间格式化正确

### 6. `DownLoadTests/NetworkClientProgressTests.swift` — 新增进度回调测试

**新增文件**，测试内容：
- `testDownloadFileReportsProgress` — 验证 progress 回调在下载过程中被多次调用（downloadedBytes 递增）
- `testDownloadFileCompletionReportsFullProgress` — 完成时 progress(downloaded, total) 且 downloaded == total

### 7. `缺陷修复优先级排序.md` — 更新修复记录

**修改内容**：
- 将缺陷 #2 和 #3 标记为 ✅ 已修复
- 添加修复日期、修复内容、验证结果

---

## 详细实现方案

### NetworkClient 改造（核心难点）

当前 `NetworkClient` 是 `actor`，不能直接继承 `NSObject`。采用**内部委托类**模式：

```swift
// 内部委托类
private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progressHandler: (Int64, Int64) -> Void
    let completionHandler: (Result<URL, Error>) -> Void

    init(progress: @escaping (Int64, Int64) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        self.progressHandler = progress
        self.completionHandler = completion
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progressHandler(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        completionHandler(.success(location))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            completionHandler(.failure(error))
        }
    }
}
```

`downloadFile` 方法改造：
- 创建 `DownloadDelegate` 实例
- 创建使用该 delegate 的 `URLSession`
- 使用 `withCheckedThrowingContinuation` 桥接 async
- delegate 的 `didFinishDownloadingTo` 中处理文件移动（或返回 tempURL 让调用方处理）
- 注意：文件移动逻辑保持在 NetworkClient 中（与当前行为一致），delegate 只负责传递 tempURL

### MP4DownloadTask 改造

```swift
// 新增属性
private let speedCalculator = SpeedCalculator()

// resume() 中 progress 回调改为：
) { [weak self] downloaded, total in
    guard let self = self else { return }
    let now = Date().timeIntervalSince1970
    self.speedCalculator.addSample(bytes: downloaded, timestamp: now)
    let speed = self.speedCalculator.calculateSpeed()
    let remaining = self.speedCalculator.calculateRemainingTime(totalBytes: total, downloadedBytes: downloaded)

    let progressInfo = DownloadProgress(
        taskId: self.id,
        totalBytes: total,
        downloadedBytes: downloaded,
        progress: total > 0 ? Float(downloaded) / Float(total) : 0,
        speed: speed,
        remainingTime: remaining
    )
    self.progress.send(progressInfo)
}
```

---

## 假设与决策

1. **NetworkClient 使用内部委托类而非改造为 NSObject 子类** — actor 不能继承 NSObject，内部类是最干净的解决方案
2. **每个下载任务创建独立 URLSession** — 避免多个下载共享 delegate 时的状态混淆
3. **SpeedCalculator 实例由各 DownloadTask 持有** — 每个任务独立计算速度，互不干扰
4. **M3U8 的速度单位保持"片段/秒"** — M3U8 下载以片段为单位，不转换为字节速度（因为每个片段大小不同，转换不准确）
5. **不修改 SpeedCalculator 本身** — 其实现已经正确，只需被正确调用
6. **文件移动逻辑保留在 NetworkClient** — 与当前行为一致，delegate 只负责进度和完成通知

---

## 验证步骤

1. **SpeedCalculator 单元测试**：验证速度计算、剩余时间计算、格式化输出
2. **NetworkClient 进度测试**：验证 progress 回调在下载过程中被多次调用
3. **集成验证**：
   - 下载一个 MP4 文件，观察进度条实时更新、速度显示非零、剩余时间倒计时
   - 下载一个 M3U8 视频，观察片段级进度和速度
   - 暂停后恢复，验证 SpeedCalculator.reset() 后速度重新计算
4. **编译验证**：`xcodebuild build` 确保无编译错误
5. **测试验证**：`xcodebuild test` 运行所有单元测试
