# P3-问题41：中英文国际化修复计划

## 摘要
修复 UI 层全局中英文混用问题，统一为用户可见的中文界面。保持代码内部（rawValue、日志、通知名、注释）英文不变。

## 当前状态分析
- `ViewController.swift` 按钮标题为英文：`"Start Download"`、`"Pause"`、`"Cancel"`、`"Retry"`、`"Play"`
- `BatchDownloadViewController.swift` / `BatchDownloadCell.swift` / `SettingsViewController.swift` / `CompletedFilesViewController.swift` / `CompletedFileDetailViewController.swift` / `MainTabBarController.swift` / `EmptyStateView.swift` 已是中文，无需修改
- `VideoPlayerViewController.swift` 播放失败错误消息含英文拼接
- `DownloadError.swift`、`NetworkError.swift`、`StorageError.swift` 的 `errorDescription` 全为英文，直接展示给用户
- `CompletedFileCell.swift` 无扩展名时回退显示 `"FILE"`
- `DownloadNotifier` 通知标题/正文已是中文，但依赖 `error.localizedDescription`

## 拟议变更

### 1. 新建 `Utilities/Strings.swift`
创建集中式中文字符串常量，按功能分组（Button、Alert、Notification、Placeholder 等）。

### 2. `ViewController.swift`
- 5 个按钮 `setTitle` 改为中文：开始下载、暂停、取消、重试、播放
- `urlTextField.placeholder` 改为 `"请输入下载链接"`
- 日志消息保持英文

### 3. `VideoPlayerViewController.swift`
- 播放失败 `errorMessage` 拼接改为中文格式：`"播放失败：..."`

### 4. `CompletedFileCell.swift`
- 回退标签 `"FILE"` -> `"文件"`

### 5. `Protocols/DownloadError.swift`
- `errorDescription` 全部中文化（rawValue 保持英文）

### 6. `Network/NetworkError.swift`
- `errorDescription` 全部中文化

### 7. `Storage/StorageError.swift`
- `errorDescription` 全部中文化

### 8. `Models/DownloadState.swift`
- `displayText` 已是中文，确认无需修改

### 9. `Core/BatchDownloadManager.swift`
- `BatchState.displayText` 已是中文，确认无需修改

## 假设与决策
- 项目当前不需要多语言切换，因此不引入 `.strings` 文件和 `NSLocalizedString`，直接硬编码中文常量
- 所有 `rawValue`（数据库/JSON 序列化用）保持英文不变
- `Logger` 日志消息保持英文（面向开发者）
- `Notification.Name` 字符串保持英文
- 代码注释保持现状

## 验证步骤
1. 编译通过
2. 全局搜索 `setTitle("[A-Za-z]`、`title = "[A-Za-z]`、`placeholder = "[A-Za-z]`、`UIAlertAction(title: "[A-Za-z]`，确认无用户可见英文 UI 字符串残留
3. 检查 `CompletedFileCell` 无扩展名时显示 `"文件"`
4. 触发网络错误/存储错误，确认 Alert 消息为中文
5. 更新 `缺陷修复优先级排序.md`，标记问题 41 为已修复
