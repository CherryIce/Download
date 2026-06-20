# Issue #47 修复计划：`Logger` 命名与 `os.Logger` 冲突

## 摘要

将自定义 `struct Logger` 重命名为 `struct AppLogger`，消除与 Apple `os.Logger` 的命名冲突。`warning` 级别已存在，无需新增。修改涉及 1 个定义文件 + 18 个调用文件，共约 129 处调用点。

## 当前状态分析

- `Logger.swift` 定义了 `struct Logger`，同时 `import os.log` 引入了 `os.Logger`，存在命名空间冲突
- 已有 `info`、`error`、`debug`、`warning` 四个日志级别，功能完整
- 全项目约 129 处 `Logger.xxx` 调用分布在 18 个文件中

## 修改方案

### 第 1 步：重命名 Logger 定义

**文件**: `DownLoad/DownLoad/Utilities/Logger.swift`

- 第 11 行 `struct Logger` → `struct AppLogger`
- 文件重命名为 `AppLogger.swift`（保持文件名与类型名一致）

### 第 2 步：批量更新所有调用点（Logger. → AppLogger.）

**Core 层**:
- `VideoDownloadEngine.swift` — 39 处
- `BatchDownloadManager.swift` — 12 处
- `DownloadQueueManager.swift` — 9 处

**Storage 层**:
- `FileStorageManager.swift` — 16 处

**Handlers 层**:
- `M3U8DownloadHandler.swift` — 10 处
- `MP4DownloadHandler.swift` — 8 处
- `ThunderDownloadHandler.swift` — 6 处

**Parsers 层**:
- `ThunderParser.swift` — 4 处

**Network 层**:
- `NetworkMonitor.swift` — 3 处
- `NetworkClient.swift` — 4 处
- `BackgroundDownloadSession.swift` — 1 处

**UI 层**:
- `BatchDownloadViewController.swift` — 8 处
- `VideoPlayerViewController.swift` — 3 处
- `CompletedFilesViewController.swift` — 1 处
- `CompletedFileDetailViewController.swift` — 1 处

**Application 层**:
- `AppDelegate.swift` — 1 处
- `SceneDelegate.swift` — 2 处

**Utilities 层**:
- `DownloadNotifications.swift` — 1 处

### 第 3 步：验证

1. 全局搜索 `\bLogger\.` 确认无残留调用（排除注释）
2. 全局搜索 `struct Logger` 确认定義已移除
3. 执行 `xcodebuild` 编译验证零错误
4. 更新 `缺陷修复优先级排序.md` 中 Issue #47 的状态

## 假设与决策

- 选择 `AppLogger` 作为新名称：简洁、明确、符合 Swift 命名惯例
- 文件同步重命名为 `AppLogger.swift`
- 纯重命名重构，不修改任何日志逻辑

## 风险评估

- 风险极低：纯类型重命名，无逻辑变更
- 回退方案：全局替换 `AppLogger.` 回 `Logger.` 即可
