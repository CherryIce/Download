# P3 问题33-34 修复计划

## 概述
修复 P3 优先级中的两个问题：
- **问题33**：`ResumableDownloadTask` 是死代码，从未被使用，需清理
- **问题34**：生产代码中存在大量 `print` 调试语句，应替换为统一 `Logger`

## 当前状态分析

### 问题33：`ResumableDownloadTask` 死代码
- 文件 `ResumableDownloadTask.swift` 定义了 `ResumableDownloadTask` 类，实现 `DownloadTask` 协议
- 全项目搜索 `ResumableDownloadTask` 仅在文件自身出现（类定义和 extension），无任何其他文件引用
- 该类未在 Xcode 项目文件 `project.pbxproj` 中注册（搜索 `Resumable` 无结果），说明可能根本未参与编译
- **决策**：直接删除 `ResumableDownloadTask.swift` 文件

### 问题34：`print` 调试语句
共 21 处 `print` 语句分布在 4 个文件中：

| 文件 | print 数量 | 类型 |
|------|-----------|------|
| `VideoDownloadEngine.swift` | 4 | 业务逻辑调试 |
| `BatchDownloadManager.swift` | 5 | 批量操作调试 |
| `BatchDownloadViewController.swift` | 7 | UI 操作调试 |
| `ViewController.swift` | 5 | 示例代码中的 print |

**替换策略**：
- `VideoDownloadEngine.swift`、`BatchDownloadManager.swift`、`BatchDownloadViewController.swift` 中的 `print` → `Logger.info()`
- `ViewController.swift` 中的 `print` 位于注释块（使用示例代码）中，属于文档示例，保留不动

## 修改方案

### 步骤1：删除死代码文件
- **文件**：`DownLoad/DownLoad/Core/ResumableDownloadTask.swift`
- **操作**：删除整个文件
- **原因**：全项目无引用，未参与编译，属于死代码

### 步骤2：替换 `VideoDownloadEngine.swift` 中的 print（4处）
- **文件**：`DownLoad/DownLoad/Core/VideoDownloadEngine.swift`
- **操作**：将 4 处 `print(...)` 替换为 `Logger.info(...)`
- 行177: `print("🔥 VideoDownloadEngine: 创建下载任务...")` → `Logger.info("创建下载任务，URL: \(url), 格式: \(format)")`
- 行189: `print("✅ Handler创建成功...")` → `Logger.info("Handler创建成功: \(type(of: handler))")`
- 行198: `print("✅ 下载任务创建成功...")` → `Logger.info("下载任务创建成功: \(task.fileName ?? "未知文件名")")`
- 行202: `print("✅ 任务已添加到队列")` → `Logger.info("任务已添加到队列")`

### 步骤3：替换 `BatchDownloadManager.swift` 中的 print（5处）
- **文件**：`DownLoad/DownLoad/Core/BatchDownloadManager.swift`
- **操作**：将 5 处 `print(...)` 替换为 `Logger.info(...)`
- 行127: 批量任务创建开始
- 行134: 处理 URL 进度
- 行143: 任务创建成功
- 行146: 任务创建失败 → `Logger.error(...)`
- 行166: 批量任务创建完成

### 步骤4：替换 `BatchDownloadViewController.swift` 中的 print（7处）
- **文件**：`DownLoad/DownLoad/UI/BatchDownloadViewController.swift`
- **操作**：将 7 处 `print(...)` 替换为 `Logger.info(...)`
- 行242: 开始创建批量下载
- 行248: 批量任务名称
- 行255: 批量任务创建完成
- 行256: 结果摘要
- 行265: 已开始下载
- 行268: 列表已刷新
- 行340: 获取到批量任务数量

### 步骤5：验证
- 确认所有 `print` 语句已替换（排除 `ViewController.swift` 注释中的示例代码）
- 确认 `ResumableDownloadTask.swift` 已删除
- 确认无编译引用断裂

### 步骤6：更新缺陷跟踪文档
- 在 `缺陷修复优先级排序.md` 中标记问题33和34为已修复

## 假设与决策
- `ViewController.swift` 中的 `print` 位于注释文档示例代码块中（行264-279），属于 API 使用说明，不替换
- `ResumableDownloadTask` 虽然实现了完整的断点续传逻辑，但与 `MP4DownloadTask`/`BackgroundDownloadSession` 功能重叠，且从未被集成，删除不会影响任何现有功能
- `print` 替换统一使用 `Logger.info()`，错误场景使用 `Logger.error()`
