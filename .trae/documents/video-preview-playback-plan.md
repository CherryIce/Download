# P3问题39 - App内视频预览/播放功能 实施计划

## 目标
为已完成文件页面添加视频预览/播放功能，使用户在下载完成后可直接在App内播放视频，无需跳转到系统应用。

## 现状分析
- 已完成文件页面（`CompletedFilesViewController`）已使用 `QLPreviewController` 实现文件预览（QuickLook 框架）
- QuickLook 对视频格式支持有限，且体验不如原生视频播放器
- 单任务下载页（`ViewController`）下载完成后仅显示文件路径，无播放入口
- 项目未引入 `AVKit` 框架

## 方案设计
采用 `AVPlayerViewController`（AVKit 框架）实现原生视频播放体验：
1. 在 `CompletedFilesViewController` 中添加"播放"操作（长按菜单 + 详情页操作）
2. 在 `CompletedFileDetailViewController` 详情页操作区添加"播放视频"按钮
3. 在 `ViewController` 单任务下载完成时，显示"播放"按钮
4. 新建 `VideoPlayerViewController` 封装 `AVPlayerViewController`，支持全屏播放、播放控制、错误处理

## 具体修改

### 1. 新建 `VideoPlayerViewController.swift`
**文件路径：** `DownLoad/DownLoad/UI/VideoPlayerViewController.swift`

封装 `AVPlayerViewController`，提供：
- 传入 `URL` 初始化并自动播放
- 播放失败时显示错误提示（如格式不支持、文件损坏）
- 支持关闭/返回操作
- 监听播放状态，播放完成后自动退出或循环播放

### 2. 修改 `CompletedFilesViewController.swift`
**文件路径：** `DownLoad/DownLoad/UI/CompletedFilesViewController.swift`

- 在 `import QuickLook` 下方添加 `import AVKit`
- 在长按上下文菜单（`contextMenuConfigurationForRowAt`）中添加"播放"选项（排在"预览"之前）
- 新增 `playVideo(at:)` 方法，创建并 present `VideoPlayerViewController`
- 修改 `tableView(_:didSelectRowAt:)`：点击行时优先播放视频（替代原来的预览文件）

### 3. 修改 `CompletedFileDetailViewController.swift`
**文件路径：** `DownLoad/DownLoad/UI/CompletedFileDetailViewController.swift`

- 在 `import QuickLook` 下方添加 `import AVKit`
- 在 `actionRows` 数组开头添加 ("播放视频", "play.circle")
- 在 `tableView(_:didSelectRowAt:)` 的 `.actions` 分支中，case 0 改为调用 `playVideo()`
- 新增 `playVideo()` 方法，创建并 present `VideoPlayerViewController`
- 原 `previewFile()` 和 `shareFile()` 的 case 索引相应后移

### 4. 修改 `ViewController.swift`
**文件路径：** `DownLoad/DownLoad/ViewController.swift`

- 添加 `import AVKit`
- 添加 `playButton: UIButton` 属性（默认隐藏）
- 将 `playButton` 加入 `stackView`
- 在 `startDownload()` 的状态监听 `.completed` 分支中，显示 `playButton` 并记录 `completedURL`
- 在 `.cancelled` 和 `.failed` 分支中隐藏 `playButton`
- 新增 `@objc private func playDownloadedVideo()` 方法，使用 `completedURL` 创建 `VideoPlayerViewController` 并 present
- 添加 `playButton` 的 target-action

## 验证步骤
1. 编译项目，确认无编译错误
2. 检查 `VideoPlayerViewController` 是否正确引入 `AVKit`
3. 确认所有修改文件的 `import AVKit` 已添加
4. 在缺陷修复文档中标记问题39为已修复
