# Download 使用说明

## 功能特性
- 支持 MP4/WebM/MKV/FLV/MOV 直链、M3U8 HLS VOD、`thunder://` 解析下载
- 支持断点续传、后台 URLSession 下载、App 重启后任务恢复
- 支持 M3U8 AES-128、密钥轮换、SAMPLE-AES、fMP4、字节范围请求
- 支持批量下载、失败项保留、失败项编辑后重试、批量分组持久化
- 支持进度回调、状态通知、错误通知和已完成文件页自动刷新
- 支持 sqlite3 本地数据库、缓存清理、下载中存储空间检查
- Demo App 提供单任务下载、批量下载、已完成文件、设置四个 UIKit 页面

---

## 快速开始

### 1. 引入方式
将 `DownLoad/DownLoad` 下需要的源码文件夹加入你的 App target：

- `Core/`
- `Handlers/`
- `Parsers/`
- `Network/`
- `Storage/`
- `Models/`
- `Utilities/`
- `Protocols/`
- `UI/`（可选，Demo 页面；业务项目也可以只复用核心层并自建 UI）

### 2. 必备 Info.plist 配置
```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <false/>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
<key>UIBackgroundModes</key>
<array>
    <string>fetch</string>
    <string>download</string>
</array>
```

当前工程不建议全局开启 `NSAllowsArbitraryLoads=true`。如果业务需要下载 HTTP 明文资源，优先配置具体域名的 ATS 例外。

### 3. 下载直链视频
```swift
let task = try await VideoDownloadEngine.shared.createDownloadTask(
    url: "https://example.com/video.mp4",
    fileName: "my_video.mp4"
)
try await VideoDownloadEngine.shared.startDownload(task: task)
```

直链下载会根据 URL 和响应头识别格式，MP4、WebM、MKV、FLV、MOV 均走直接下载处理器。

### 4. 下载 M3U8 点播流
```swift
let task = try await VideoDownloadEngine.shared.createDownloadTask(
    url: "https://example.com/video.m3u8",
    fileName: "my_hls_video.mp4"
)
try await VideoDownloadEngine.shared.startDownload(task: task)
```

M3U8 Live 流暂不支持；检测到直播流会抛出 `DownloadError.liveStreamNotSupported`。

### 5. 下载迅雷链接
```swift
let task = try await VideoDownloadEngine.shared.createDownloadTask(
    url: "thunder://QUFodHRwOi8vZXhhbXBsZS5jb20vdmlkZW8ubXA0Wlo=",
    fileName: "thunder_video.mp4"
)
try await VideoDownloadEngine.shared.startDownload(task: task)
```

`thunder://` 会解析真实 URL 后下载。`thunderp2p://` 和 `magnet:` 只做识别并返回明确错误，当前不内置 P2P/BT 下载能力。

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
        print("State: \(state.displayText)")
    }
    .store(in: &cancellables)
```

### 8. 批量下载
```swift
let result = await BatchDownloadManager.shared.createBatchDownload(
    name: "批量任务",
    urls: [
        "https://example.com/a.mp4",
        "https://example.com/b.m3u8"
    ],
    fileNames: [
        "a.mp4",
        "b.mp4"
    ]
)

try await BatchDownloadManager.shared.startBatchDownload(batchId: result.batchTask.id)
```

### 9. 持久化数据库自动管理
- 任务自动保存在 DownLoad/DownLoad/Storage/DownloadTaskDatabase.swift 对应的数据库内
- 启动时可自动恢复未完成单任务和批量分组，实现断点续传与批量页恢复

### 10. 当前 Demo UI
- `MainTabBarController.swift`：四个 Tab 入口
- `ViewController.swift`：单任务下载页
- `BatchDownloadViewController.swift`：批量下载、批量添加、批量详情和失败项重试
- `CompletedFilesViewController.swift`：已完成文件列表、搜索、排序、播放、分享、删除
- `SettingsViewController.swift`：最大并发数、超时、重试、蜂窝下载、后台下载设置

源码中没有 `DownloadManagerView.swift`。如果需要嵌入式下载管理视图，请参考上述页面拆分业务自己的 View。

---

## 进阶用法与建议
- 支持多任务并发下载、队列优先级、运行时并发数更新
- 断点下载持久化采用 resumeData 和 Range Header, 可应对各种网络/进程中断
- Thunder 协议自动适配 mp4/m3u8，无需二次解码
- 所有异常和重试均有完整回调和日志
- UI 页面与核心下载解耦，可集成到任意页面或自定义管理下载队列
- 后台下载、系统通知、蜂窝网络策略和批量恢复建议在真机或可用模拟器补充验证

## 常见问题
- 文件读写/网络权限请严格依据 README 配置 Info.plist
- 测试时推荐使用高速直链/真实 m3u8 地址
- 若多任务切换建议加锁或主线程同步进度回调
- 下载引擎、UI、数据库接口均已兼容 Swift 5+
- M3U8 Live 流、磁力链接、需要 P2P/BT 客户端的链接当前不支持下载

## 联系作者
如需深入功能对接请联系 hubin@github

---

本组件完全开源，可用于一切 Swift 项目的视频下载、断点任务与 UI 集成需求。
