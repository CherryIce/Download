# 批量下载功能使用说明

## 概述

此Swift视频下载组件现已支持批量下载功能，可以同时管理和下载多个视频文件，支持MP4、M3U8和迅雷协议。

## 功能特性

### 1. 批量下载管理
- 创建多个下载任务组成的批量任务
- 独立管理每个批量任务的进度和状态
- 支持批量操作（开始、暂停、取消、删除）

### 2. 实时进度监控
- 显示每个批量任务的总体进度
- 实时更新任务状态（等待中、下载中、暂停、完成、失败、已取消）
- 显示完成数量/总数量

### 3. 多格式支持
- MP4视频文件
- M3U8流媒体文件
- 迅雷协议链接

### 4. 用户界面
- 标签栏界面，单任务下载和批量下载分离
- 批量任务列表显示
- 批量操作按钮（开始、暂停、取消、删除）
- 添加新批量任务的便捷界面

## 使用方法

### 1. 创建批量下载任务

```swift
// 创建批量下载
let batchTask = try await VideoDownloadEngine.shared.createBatchDownload(
    name: "我的视频合集",
    urls: [
        "https://example.com/video1.mp4",
        "https://example.com/video2.m3u8",
        "thunder://QUFodHRwOi8vZXhhbXBsZS5jb20vdmlkZW8ubXA0Wlo="
    ]
)
// 文件名会自动从URL中生成
```

### 2. 管理批量任务

```swift
// 获取所有批量任务
let allTasks = await VideoDownloadEngine.shared.getAllBatchTasks()

// 开始批量下载
try await VideoDownloadEngine.shared.startBatchDownload(batchId: batchTask.id)

// 暂停批量下载
await VideoDownloadEngine.shared.pauseBatchDownload(batchId: batchTask.id)

// 取消批量下载
await VideoDownloadEngine.shared.cancelBatchDownload(batchId: batchTask.id)

// 删除批量下载
await VideoDownloadEngine.shared.deleteBatchDownload(batchId: batchTask.id)
```

### 3. 监听批量任务进度

```swift
// 获取批量任务进度
if let progress = VideoDownloadEngine.shared.getBatchProgress(batchId: batchTask.id) {
    print("总任务数: \(progress.total)")
    print("已完成: \(progress.completed)")
    print("下载中: \(progress.downloading)")
    print("暂停中: \(progress.paused)")
    print("失败: \(progress.failed)")
}
```

### 4. 监听单个任务状态

```swift
// 批量任务中的每个任务都可以单独监听
for item in batchTask.taskItems {
    item.task.state
        .receive(on: DispatchQueue.main)
        .sink { state in
            switch state {
            case .completed(let url):
                print("任务 \(item.fileName) 完成: \(url)")
            case .failed:
                print("任务 \(item.fileName) 失败")
            case .paused:
                print("任务 \(item.fileName) 暂停")
            default:
                break
            }
        }
        .store(in: &cancellables)
}
```

## 界面操作

### 1. 添加新批量任务
- 点击右上角的"新增批量下载"按钮
- 输入多个URL，每行一个（支持混合格式）
- 任务名称会自动生成（格式：批量下载_日期时间）
- 点击"确定"创建

### 2. 批量操作
- 选择一个批量任务
- 使用底部的操作按钮：
  - **开始**: 开始选中的批量任务
  - **暂停**: 暂停选中的批量任务
  - **取消**: 取消选中的批量任务
  - **删除**: 删除选中的批量任务

### 3. 状态查看
- 任务列表显示任务名称和当前状态
- 进度条显示整体完成度
- 状态颜色：
  - 灰色：等待中
  - 蓝色：下载中
  - 橙色：暂停中
  - 绿色：已完成
  - 红色：失败

## 注意事项

1. **并发限制**：每个批量任务最多同时下载3个文件（可在DownloadQueueManager中调整）
2. **内存使用**：大量并发下载会增加内存使用，建议合理控制任务数量
3. **错误处理**：单个任务失败不会影响其他任务的下载
4. **存储空间**：确保有足够的存储空间来保存所有下载的文件
5. **网络稳定性**：批量下载对网络稳定性要求较高，建议在良好网络环境下使用

## 代码示例

完整的使用示例可以在 `ViewController.swift` 的注释中找到。