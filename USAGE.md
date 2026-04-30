# Download 使用说明

## 功能特性
- 支持 MP4 直链、M3U8 HLS、迅雷协议（thunder://）视频下载
- 断点续传下载（支持应用多次重启、进程杀死恢复下载）
- AES-128 解密（M3U8 HLS）
- 并发下载、支持自动重试
- 自动进度回调、错误处理、任务持久化
- sqlite3 本地数据库，自动保存任务记录
- 易用 UI 组件 DownloadManagerView.swift 可直接复用

---

## 快速开始

### 1. 引入方式
拷贝 Download 主目录下的 Core/、Handlers/、Storage/、UI/、Models/ 等文件夹到你的 Swift 项目。

### 2. 必备 Info.plist 配置
```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key><true/>
</dict>
<key>UIBackgroundModes</key>
<array>
    <string>fetch</string>
</array>
```

### 3. 下载 MP4 视频
```swift
let task = try await VideoDownloadEngine.shared.createDownloadTask(
    url: "https://example.com/video.mp4",
    fileName: "my_video.mp4"
)
try await VideoDownloadEngine.shared.startDownload(task: task)
```

### 4. 下载 M3U8 流媒体
```swift
let task = try await VideoDownloadEngine.shared.createDownloadTask(
    url: "https://example.com/video.m3u8",
    fileName: "my_hls_video.mp4"
)
try await VideoDownloadEngine.shared.startDownload(task: task)
```

### 5. 下载迅雷链接
```swift
let task = try await VideoDownloadEngine.shared.createDownloadTask(
    url: "thunder://QUFodHRwOi8vZXhhbXBsZS5jb20vdmlkZW8ubXA0Wlo=",
    fileName: "thunder_video.mp4"
)
try await VideoDownloadEngine.shared.startDownload(task: task)
```

### 6. 暂停、恢复、取消下载
```swift
await VideoDownloadEngine.shared.pauseDownload(task: task) // 暂停
try await VideoDownloadEngine.shared.startDownload(task: task) // 恢复
await VideoDownloadEngine.shared.cancelDownload(task: task) // 取消
```

### 7. 进度与状态回调
```swift
task.progress
    .receive(on: DispatchQueue.main)
    .sink { progress in
        print("Progress: \(progress.percentage)")
    }
    .store(in: &cancellables)

task.state
    .receive(on: DispatchQueue.main)
    .sink { state in
        print("State: \(state)")
    }
    .store(in: &cancellables)
```

### 8. 封装可复用下载管理 UI
在项目页面添加：
```swift
let managerView = DownloadManagerView(frame: .zero)
view.addSubview(managerView)
```

### 9. 持久化数据库自动管理
- 任务自动保存在 DownLoad/DownLoad/Storage/DownloadTaskDatabase.swift 对应的数据库内
- 启动时可自动恢复所有未完成任务，实现断点续传

---

## 进阶用法与建议
- 支持多任务并发下载/队列管理
- 断点下载持久化采用 resumeData 和 Range Header, 可应对各种网络/进程中断
- Thunder 协议自动适配 mp4/m3u8，无需二次解码
- 所有异常和重试均有完整回调和日志
- UI 组件与核心下载解耦，可集成到任意页面或自定义管理下载队列

## 常见问题
- 文件读写/网络权限请严格依据 README 配置 Info.plist
- 测试时推荐使用高速直链/真实 m3u8 地址
- 若多任务切换建议加锁或主线程同步进度回调
- 下载引擎、UI、数据库接口均已兼容 Swift 5+

## 联系作者
如需深入功能对接请联系 hubin@github

---

本组件完全开源，可用于一切 Swift 项目的视频下载、断点任务与 UI 集成需求。