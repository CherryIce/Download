# 修复 P1 问题 12、13、14 实施计划

> **目标：** 修复 `NetworkClient.swift` 中 `downloadFileWithResumeCancellable` 缺少重试机制和 resumeData 提取的问题，以及 `SceneDelegate.swift` 中未请求通知权限的问题。

**涉及文件：**
- `/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/Network/NetworkClient.swift`
- `/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/SceneDelegate.swift`

---

## 当前状态分析

### Issue 12 & 13：NetworkClient.swift

`downloadFileWithResumeCancellable`（第 266-309 行）当前实现存在两个问题：
1. **无重试机制**：`downloadString` 和 `downloadData` 都有 `for attempt in 0..<retryCount` 循环 + 指数退避，但 `downloadFileWithResumeCancellable` 没有。
2. **失败时未提取 resumeData**：`downloadFileWithResume` 通过 `delegate.resumeDataHandler` 捕获 resumeData 并包装为 `NetworkError.resumeError`，但 `downloadFileWithResumeCancellable` 直接 `continuation.resume(throwing: error)`。

### Issue 14：SceneDelegate.swift

`SceneDelegate.scene(_:willConnectTo:options:)` 只设置 UI 窗口，从未调用 `UNUserNotificationCenter.requestAuthorization`。`DownloadNotifications.swift` 中的 `sendLocalNotification` 直接调用 `UNUserNotificationCenter.current().add(request)`，没有权限时通知不会显示。

---

## 拟议变更

### 变更 1：NetworkClient.swift — 提取单次下载 + 添加重试循环

**修改范围：** 第 266-309 行整体替换，并在其前添加新的 `performSingleDownload` 私有方法。

**具体修改：**

将原 `downloadFileWithResumeCancellable` 方法（第 266-309 行）的内核逻辑提取为私有方法 `performSingleDownload`，并为其添加 `resumeDataHandler`：

```swift
    /// 单次下载尝试（支持断点续传 + 可取消句柄）
    private func performSingleDownload(
        from url: URL,
        to destinationURL: URL,
        resumeData: Data?,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws -> (URL, ResumableDownloadHandle) {
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(progress: progress)
            let downloadSession = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)

            var savedResumeData: Data?

            delegate.resumeDataHandler = { data in
                savedResumeData = data
            }

            let downloadTask: URLSessionDownloadTask
            if let resumeData = resumeData {
                downloadTask = downloadSession.downloadTask(withResumeData: resumeData)
            } else {
                let request = makeRequest(for: url)
                downloadTask = downloadSession.downloadTask(with: request)
            }

            let handle = ResumableDownloadHandle(urlSessionTask: downloadTask)

            delegate.completionHandler = { result in
                switch result {
                case .success(let tempURL):
                    do {
                        let dir = destinationURL.deletingLastPathComponent()
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        if FileManager.default.fileExists(atPath: destinationURL.path) {
                            try FileManager.default.removeItem(at: destinationURL)
                        }
                        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                        let size = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0
                        progress(size, size)
                        continuation.resume(returning: (destinationURL, handle))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                case .failure(let error):
                    let wrappedError = NetworkError.resumeError(
                        underlying: error,
                        resumeData: savedResumeData
                    )
                    continuation.resume(throwing: wrappedError)
                }
            }

            downloadTask.resume()
        }
    }
```

将 `downloadFileWithResumeCancellable` 改为外层重试循环：

```swift
    /// 下载文件（支持断点续传 + 可取消句柄，用于 MP4DownloadTask 暂停/恢复场景）
    func downloadFileWithResumeCancellable(
        from url: URL,
        to destinationURL: URL,
        resumeData: Data? = nil,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws -> (URL, ResumableDownloadHandle) {
        var lastError: Error?

        for attempt in 0..<retryCount {
            do {
                return try await performSingleDownload(
                    from: url,
                    to: destinationURL,
                    resumeData: resumeData,
                    progress: progress
                )
            } catch {
                lastError = error
                Logger.error("Download cancellable attempt \(attempt + 1) failed: \(error.localizedDescription)")

                if attempt < retryCount - 1 {
                    let delay = pow(2.0, Double(attempt))
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        throw lastError ?? NetworkError.connectionError(NSError(domain: "NetworkClient", code: -1))
    }
```

**为什么：**
- 重试循环必须在 `withCheckedThrowingContinuation` 外部，否则每次重试需要重新创建全新的 `URLSession`、`DownloadDelegate` 和 `URLSessionDownloadTask`。
- 提取 `performSingleDownload` 避免在重试循环中嵌套 continuation，保持代码清晰。
- `resumeDataHandler` 在 `urlSession(_:task:didCompleteWithError:)` 触发时捕获 `NSURLSessionDownloadTaskResumeData`，失败时包装为 `NetworkError.resumeError`，与 `downloadFileWithResume` 保持一致。

### 变更 2：SceneDelegate.swift — 添加通知权限请求

**修改范围：** 第 8 行（添加 import）和第 15-28 行（scene 方法末尾添加请求代码）。

**具体修改：**

在第 8 行 `import UIKit` 下方添加：
```swift
import UserNotifications
```

在 `scene(_:willConnectTo:options:)` 方法末尾（`self.window = window` 之后）添加：
```swift
        // 请求本地通知授权（不阻塞 UI）
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                Logger.info("Notification authorization granted: \(granted)")
            } catch {
                Logger.error("Notification authorization request failed: \(error)")
            }
        }
```

**为什么：**
- `scene(_:willConnectTo:options:)` 是应用启动时 UI 场景建立的生命周期方法，适合在此处请求权限。
- 使用 `Task { ... }` 包装异步调用，不阻塞同步方法中的 UI 初始化。
- 无论授权结果如何都不影响窗口展示。
- `requestAuthorization` 重复调用是安全的，系统不会重复弹窗。

---

## 假设与决策

1. **重试间不传递更新的 resumeData**：当前每次重试使用传入的 `resumeData` 参数。若某次尝试失败后获取了新的 resumeData，不会自动用于下一次重试。这与 `downloadFileWithResume` 的行为保持一致，满足当前需求。
2. **actor 隔离安全**：`NetworkClient` 是 `actor`，`performSingleDownload` 作为 `private` 方法在 actor 内部调用，自动串行化，无需额外隔离处理。
3. **通知授权选项**：使用 `[.alert, .sound, .badge]`，覆盖下载完成/失败通知所需的弹窗、声音和角标能力。

---

## 验证步骤

1. **编译检查**：在项目目录执行 `xcodebuild -scheme DownLoad -destination 'platform=iOS Simulator,name=iPhone 15' clean build`，确认无编译错误。
2. **Issue 12 验证**：模拟网络不稳定环境，调用 `downloadFileWithResumeCancellable`，观察日志是否打印多次 `Download cancellable attempt X failed` 及重试延迟。
3. **Issue 13 验证**：在下载中途强制断开网络，检查抛出的错误是否为 `NetworkError.resumeError`，且 `error.resumeData` 不为 nil。
4. **Issue 14 验证**：首次安装应用启动时，确认出现系统通知授权弹窗；在设置中关闭通知后，确认应用不崩溃且日志打印 `granted: false`。
