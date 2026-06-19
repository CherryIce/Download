# P2-1 修复计划：MP4 断点续传集成

## 概述

**缺陷**: `MP4DownloadTask` 不支持断点续传，暂停后需从头下载。`ResumableDownloadTask` 已实现完整续传逻辑但未被 `VideoDownloadEngine` 使用。

**修复策略**: 改造 `MP4DownloadTask`，使其通过 `NetworkClient.downloadFileWithResume` 支持断点续传，同时新增 `ResumableDownloadHandle` 机制确保 `pause()` 时能正确获取 `resumeData`。

## 当前状态分析

| 组件 | 现状 | 问题 |
|------|------|------|
| `MP4DownloadTask` | 使用 `networkClient.downloadFile` | 不支持续传，pause 只是 cancel 不保存 resumeData |
| `NetworkClient.downloadFileWithResume` | 已实现，接受 resumeData 参数 | 返回 `(URL, Data?)`，但 pause 时无法通过 Task.cancel() 获取 resumeData |
| `ResumableDownloadTask` | 完整续传实现 | 未被 Engine 使用，直接操作 URLSessionTask |
| `DownloadTask` 协议 | 无 resumeData 属性 | 不影响本次修复，通过具体类属性实现 |

**核心难点**: `NetworkClient.downloadFileWithResume` 内部使用 `withCheckedThrowingContinuation`，当外部 `Task.cancel()` 时，continuation 收到 `CancellationError`，但 `URLSessionDownloadTask.cancel(byProducingResumeData:)` 不会被调用，导致 resumeData 丢失。

**解决方案**: 新增 `downloadFileWithResumeCancellable` 方法，返回 `ResumableDownloadHandle` 句柄，暴露底层 `URLSessionDownloadTask`，使 `MP4DownloadTask.pause()` 能调用 `cancel(byProducingResumeData:)` 正确保存 resumeData。

## 修改方案

### 1. NetworkClient.swift — 新增 ResumableDownloadHandle 和可取消下载方法

**文件**: `DownLoad/DownLoad/Network/NetworkClient.swift`

新增内容：
- `ResumableDownloadHandle` 类：包装 `URLSessionDownloadTask`，提供 `cancelWithResumeData()` 方法
- `downloadFileWithResumeCancellable()` 方法：与 `downloadFileWithResume` 逻辑相同，但返回 `(URL, ResumableDownloadHandle)` 元组

```swift
/// 可取消的下载任务句柄，支持暂停时获取 resumeData
class ResumableDownloadHandle {
    private let urlSessionTask: URLSessionDownloadTask
    private var _resumeData: Data?

    init(urlSessionTask: URLSessionDownloadTask) {
        self.urlSessionTask = urlSessionTask
    }

    /// 暂停下载并保存 resumeData
    func cancelWithResumeData() async -> Data? {
        await withCheckedContinuation { continuation in
            self.urlSessionTask.cancel(byProducingResumeData: { data in
                self._resumeData = data
                continuation.resume(returning: data)
            })
        }
    }

    var resumeData: Data? { _resumeData }
}
```

### 2. MP4DownloadHandler.swift — 改造 MP4DownloadTask 支持断点续传

**文件**: `DownLoad/DownLoad/Handlers/MP4DownloadHandler.swift`

改动：
- `MP4DownloadTask` 新增 `resumeData: Data?` 属性和 `downloadHandle: ResumableDownloadHandle?` 属性
- `resume()` 改用 `networkClient.downloadFileWithResumeCancellable`，传入已有 resumeData
- `pause()` 改用 `downloadHandle.cancelWithResumeData()` 保存 resumeData，状态设为 `.paused`
- `cancel()` 清除 resumeData，清理临时文件
- 成功完成后清除 resumeData

### 3. 缺陷修复优先级排序.md — 记录修复

**文件**: `/Users/hubin/Desktop/MutiDownload/缺陷修复优先级排序.md`

在 P2 #4 条目后追加修复记录。

## 验证步骤

1. **正常下载**: MP4 文件从头下载到完成，状态 pending -> downloading -> completed
2. **暂停+恢复**: 下载中暂停，确认 resumeData 非空；恢复后从断点继续
3. **多次暂停恢复**: 反复暂停/恢复多次，最终完成下载
4. **暂停后取消**: 暂停后取消，确认 resumeData 被清除，临时文件删除
5. **编译检查**: 项目编译无错误无警告
