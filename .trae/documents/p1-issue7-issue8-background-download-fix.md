# P1 问题 #7 和 #8 修复计划：后台下载集成 + UIBackgroundModes 配置

## 摘要

修复 P1 优先级中的两个问题：
- **问题 #7**：`BackgroundDownloadSession` 已完整实现但从未被 `MP4DownloadHandler` 使用，导致 App 进入后台时 MP4 下载会暂停
- **问题 #8**：`Info.plist` 的 `UIBackgroundModes` 仅声明了 `fetch`，缺少 `download` 模式，后台下载无法获得系统授权

## 当前状态分析

### 问题 #7 — 后台下载未集成

**现有架构**：
- `BackgroundDownloadSession.swift`（单例）已完整实现：background URLSession、创建/恢复任务、取消获取 resumeData、delegate 回调
- `AppDelegate.swift` 已初始化 `BackgroundDownloadSession.shared` 并设置了 `handleEventsForBackgroundURLSession` 回调
- `MP4DownloadHandler.swift` 中的 `MP4DownloadTask` 使用 `NetworkClient.downloadFileWithResumeCancellable()` 进行前台下载
- `DownloadConfiguration` 已有 `enableBackgroundDownload: Bool = true` 字段，但从未被读取

**下载链路**：
```
VideoDownloadEngine → MP4DownloadHandler → MP4DownloadTask → NetworkClient (前台 URLSession)
（BackgroundDownloadSession 完全被绕过）
```

**关键差异**：
- `NetworkClient` 使用 `URLSessionConfiguration.default`（前台），App 后台时下载暂停
- `BackgroundDownloadSession` 使用 `URLSessionConfiguration.background(withIdentifier:)`，系统会在后台继续下载
- `BackgroundDownloadSession` 的 API 是回调式的（closure），而 `MP4DownloadTask` 使用 Swift Concurrency（async/await）

### 问题 #8 — UIBackgroundModes 缺少 download

**当前 `Info.plist`**：
```xml
<key>UIBackgroundModes</key>
<array>
    <string>fetch</string>
</array>
```

**需要**：添加 `<string>download</string>` 以授权后台 URL 会话下载。

## 修复方案

### 修复 #8（Info.plist）— 简单，先做

**文件**：`DownLoad/DownLoad/Info.plist`

**修改内容**：
```xml
<key>UIBackgroundModes</key>
<array>
    <string>fetch</string>
    <string>download</string>
</array>
```

在 `UIBackgroundModes` 数组中添加 `download` 字符串。这是后台下载正常工作的前提条件。

---

### 修复 #7（集成 BackgroundDownloadSession）— 核心修改

**策略**：修改 `MP4DownloadTask`，当 `configuration.enableBackgroundDownload == true` 时使用 `BackgroundDownloadSession`，否则回退到 `NetworkClient` 前台下载。这样保持向后兼容。

#### 步骤 1：修改 `MP4DownloadTask`

**文件**：`DownLoad/DownLoad/Handlers/MP4DownloadHandler.swift`

**修改 `resume()` 方法**：
- 检查 `configuration.enableBackgroundDownload`
- 如果为 `true`：使用 `BackgroundDownloadSession.shared.createDownloadTask(url:taskId:progress:completion:)` 创建后台下载任务，调用 `task.resume()` 启动
- 如果为 `false`：保持现有 `NetworkClient` 逻辑不变
- 将 BackgroundDownloadSession 的回调式 API 桥接为 async/await（使用 `withCheckedContinuation`）
- 进度回调逻辑保持不变（`SpeedCalculator` + `CurrentValueSubject`）
- 下载完成后文件移动逻辑保持不变（从 temp 目录移到 completed 目录）

**修改 `pause()` 方法**：
- 后台模式：调用 `BackgroundDownloadSession.shared.cancelTask(_:completion:)` 获取 resumeData
- 前台模式：保持现有 `ResumableDownloadHandle.cancelWithResumeData()` 逻辑

**修改 `cancel()` 方法**：
- 后台模式：调用 `BackgroundDownloadSession.shared.cancelTask()` 不保留 resumeData
- 前台模式：保持现有逻辑

**新增属性**：
- `private var backgroundDownloadTask: URLSessionDownloadTask?` — 保存后台下载任务引用

#### 步骤 2：处理自定义请求头兼容

**分析**：`BackgroundDownloadSession` 当前使用 `session.downloadTask(with: url)` 创建任务，不支持自定义请求头。当 `configuration.customHeaders` 非空时，需要使用 `session.downloadTask(with: URLRequest)` 创建任务。

**修改 `BackgroundDownloadSession.swift`**：
- 新增 `createDownloadTask(request:taskId:progress:completion:)` 方法，接受 `URLRequest` 参数
- 新增 `createDownloadTask(resumeData:request:taskId:progress:completion:)` 方法，支持从 resumeData 恢复并带自定义请求头

#### 步骤 3：处理后台下载完成时的文件路径

**分析**：`BackgroundDownloadSession` 的 delegate 在下载完成时将文件移动到 `Documents/Temp_{taskId}.tmp`。但 `MP4DownloadTask` 期望文件在 `storageManager.createTaskDirectory(taskId:)` 创建的临时目录中。

**方案**：修改 `BackgroundDownloadSession` 的 `didFinishDownloadingTo` 回调，不再自动移动文件，而是直接返回系统临时路径。由 `MP4DownloadTask` 负责文件移动（与前台模式一致）。

**修改 `BackgroundDownloadSession.swift`**：
- `didFinishDownloadingTo`：直接将 `location` URL 传给 completion handler，不再自行移动文件
- 这样 `MP4DownloadTask` 的文件移动逻辑（`storageManager.moveFile(from:to:)`）可以统一处理

#### 步骤 4：处理 App 被系统终止后恢复

**分析**：当 App 在后台被系统杀死后重新启动，`BackgroundDownloadSession` 的内存中的 `downloadTasks`/`taskProgressHandlers`/`taskCompletionHandlers` 字典会丢失。需要从 `VideoDownloadEngine.restoreTasksFromDatabase()` 恢复时，重新关联后台任务。

**方案**：
- 在 `restoreTasksFromDatabase()` 中，对于 MP4 任务，调用 `BackgroundDownloadSession.shared.getAllTasks()` 获取仍在运行的后台任务
- 通过某种映射（如 taskIdentifier 或 URL）匹配数据库记录
- 重新注册 progress/completion handler

**注意**：这需要 `BackgroundDownloadSession` 支持通过 taskIdentifier 查找和重新注册 handler。新增方法：
- `func registerHandler(for taskIdentifier: Int, taskId: UUID, progress:completion:)` — 为已存在的后台任务重新注册回调

#### 步骤 5：线程安全

**分析**：`BackgroundDownloadSession` 是 `NSObject` 子类（非 actor），其字典属性（`downloadTasks`/`taskProgressHandlers`/`taskCompletionHandlers`）可能被并发访问。

**方案**：为 `BackgroundDownloadSession` 添加串行队列保护字典访问，或将其改为 actor。考虑到它继承 `NSObject`（URLSessionDelegate 要求），使用串行队列更合适。

---

## 涉及文件清单

| 文件 | 修改类型 | 说明 |
|------|----------|------|
| `DownLoad/DownLoad/Info.plist` | 修改 | 添加 `download` 到 `UIBackgroundModes` |
| `DownLoad/DownLoad/Handlers/MP4DownloadHandler.swift` | 修改 | `MP4DownloadTask` 集成后台下载 |
| `DownLoad/DownLoad/Network/BackgroundDownloadSession.swift` | 修改 | 支持 URLRequest、移除自动文件移动、添加 handler 重新注册、线程安全 |
| `DownLoad/DownLoad/Core/VideoDownloadEngine.swift` | 修改 | `restoreTasksFromDatabase` 中恢复后台下载任务关联 |
| `DownLoad/DownLoad/缺陷修复优先级排序.md` | 修改 | 记录 #7 和 #8 已修复 |

## 假设与决策

1. **仅对 MP4 格式启用后台下载**：M3U8 是多片段下载，后台 URLSession 不适合；Thunder 有自己的机制
2. **保持 `enableBackgroundDownload` 开关**：默认 `true`，允许用户/配置关闭
3. **前台下载作为 fallback**：当后台下载不可用时（如自定义请求头场景的兼容），回退到前台下载
4. **不修改 `NetworkClient`**：保持其职责不变，仅修改 `MP4DownloadTask` 的下载方式选择

## 验证步骤

1. **编译验证**：`xcodebuild build` 确保无编译错误
2. **Info.plist 验证**：确认 `UIBackgroundModes` 包含 `fetch` 和 `download`
3. **后台下载功能验证**：
   - 启动 MP4 下载 → 将 App 切到后台 → 确认下载继续
   - App 从后台恢复 → 确认进度正确更新
4. **前台下载回退验证**：设置 `enableBackgroundDownload = false` → 确认使用 NetworkClient 前台下载
5. **暂停/恢复验证**：后台下载模式下暂停 → 获取 resumeData → 恢复后继续下载
6. **取消验证**：后台下载模式下取消 → 确认临时文件清理
7. **更新缺陷文档**：在 `缺陷修复优先级排序.md` 中标记 #7 和 #8 为已修复
