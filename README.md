# Swift 视频下载组件与 Demo App

这是一个原生 iOS Swift 视频下载项目，当前定位是“可复用下载能力 + Demo App”。核心下载能力可拷贝到业务项目中复用，Demo App 提供单任务下载、批量下载、已完成文件和设置四个入口。

## 功能特性

- ✅ **直链下载**：支持 MP4、WebM、MKV、FLV、MOV 等常见文件直链，支持断点续传
- ✅ **M3U8 下载**：支持 HLS VOD、Master/Media Playlist、AES-128、密钥轮换、fMP4、字节范围和分片合并
- ✅ **迅雷链接识别**：支持 `thunder://` 解析并委托真实 URL 下载；`thunderp2p://`、`magnet:` 会识别并返回“不支持 P2P/磁力下载”的明确错误
- ✅ **批量下载**：支持批量创建、部分失败不中断、失败项编辑后重试、批量状态自动推导和 SQLite 批量分组恢复
- ✅ **后台与恢复**：支持后台 URLSession 下载、任务数据库持久化、App 重启后的未完成任务恢复
- ✅ **网络策略**：支持网络状态监听、断网自动暂停/恢复、蜂窝下载开关和运行时并发数更新
- ✅ **文件管理**：提供已完成文件列表、搜索、排序、播放、分享、详情和删除
- ✅ **存储管理**：下载中空间检查、临时目录、缓存清理和完成文件目录管理
- ✅ **Swift Concurrency**：使用 async/await、actor 和 Combine 组织任务、队列与回调

## 架构设计

```
VideoDownloader
├── Core Layer         - 下载引擎和任务管理
├── Parser Layer       - URL和视频格式解析
├── Handler Layer      - 不同格式下载处理器
├── Network Layer      - 网络请求封装
├── Storage Layer      - 文件和缓存管理
├── Model Layer        - 数据模型
├── Utility Layer      - 工具类、配置、通知和日志
└── UI Layer           - Demo App 页面和可参考的 UIKit 实现
```

## 安装

无需第三方依赖。作为源码组件接入时，将 `DownLoad/DownLoad` 下需要的文件夹加入你的 App target：

- Core/
- Parsers/
- Handlers/
- Network/
- Storage/
- Models/
- Utilities/
- Protocols/
- UI/（可选，Demo App 页面；业务项目也可以只复用核心层并自建 UI）

工程使用 `sqlite3`、`Combine`、`Network`、`AVKit`、`QuickLook`、`UserNotifications` 等系统框架。若只接入核心下载层，可按实际使用页面裁剪 UI 相关 framework。

## 使用方法

### 1. 基本使用

```swift
import Combine

class ViewController: UIViewController {
    private let downloadEngine = VideoDownloadEngine.shared
    private var cancellables = Set<AnyCancellable>()

    func downloadVideo() {
        Task {
            do {
                // 创建下载任务
                let task = try await downloadEngine.createDownloadTask(
                    url: "https://example.com/video.mp4",
                    fileName: "my_video.mp4"
                )

                // 监听进度
                task.progress
                    .receive(on: DispatchQueue.main)
                    .sink { progress in
                        print("Progress: \(progress.percentage)")
                        print("Speed: \(progress.formattedSpeed)")
                    }
                    .store(in: &cancellables)

                // 监听状态
                task.state
                    .receive(on: DispatchQueue.main)
                    .sink { state in
                        print("State: \(state.displayText)")
                    }
                    .store(in: &cancellables)

                // 开始下载
                try await downloadEngine.startDownload(task: task)
            } catch {
                print("Error: \(error)")
            }
        }
    }
}
```

### 2. 下载直链视频

```swift
let task = try await VideoDownloadEngine.shared.createDownloadTask(
    url: "https://example.com/video.mp4",
    fileName: "my_video.mp4"
)
try await VideoDownloadEngine.shared.startDownload(task: task)
```

直链下载会根据 URL 和响应头识别格式，MP4、WebM、MKV、FLV、MOV 都走同一套二进制下载处理器。

### 3. 下载 M3U8 点播流

```swift
let task = try await VideoDownloadEngine.shared.createDownloadTask(
    url: "https://example.com/video.m3u8",
    fileName: "my_hls_video.mp4"
)
try await VideoDownloadEngine.shared.startDownload(task: task)
```

M3U8下载特性：
- 自动解析Master Playlist和Media Playlist
- 自动选择最佳码率/分辨率
- 支持 AES-128、密钥轮换、SAMPLE-AES 的本地处理
- 支持 fMP4 初始化片段和字节范围请求
- 并发下载TS片段（默认5个并发）
- 自动合并TS片段为完整视频
- 不支持直播流下载，检测到无 `#EXT-X-ENDLIST` 的 Live Playlist 会返回 `DownloadError.liveStreamNotSupported`

### 4. 下载迅雷链接

```swift
let task = try await VideoDownloadEngine.shared.createDownloadTask(
    url: "thunder://QUFodHRwOi8vZXhhbXBsZS5jb20vdmlkZW8ubXA0Wlo=",
    fileName: "thunder_video.mp4"
)
try await VideoDownloadEngine.shared.startDownload(task: task)
```

迅雷协议说明：
- 自动解析Base64编码的URL
- 自动识别真实URL格式（MP4/M3U8）
- 委托给对应的处理器下载
- `thunderp2p://` 和 `magnet:` 仅做识别并返回明确错误，当前不内置 P2P/BT 客户端能力

### 5. 暂停和恢复下载

```swift
// 暂停
await VideoDownloadEngine.shared.pauseDownload(task: task)

// 恢复
try await VideoDownloadEngine.shared.startDownload(task: task)
```

### 6. 取消下载

```swift
await VideoDownloadEngine.shared.cancelDownload(task: task)
```

### 7. 管理下载任务

```swift
// 获取所有任务
let tasks = await VideoDownloadEngine.shared.getAllTasks()

// 获取指定任务
if let task = await VideoDownloadEngine.shared.getTask(by: taskId) {
    print("Found task: \(task.fileName)")
}

// 清理所有下载
await VideoDownloadEngine.shared.clearAllDownloads()
```

### 8. 批量下载

```swift
let result = await BatchDownloadManager.shared.createBatchDownload(
    name: "课程视频",
    urls: [
        "https://example.com/lesson-01.mp4",
        "https://example.com/lesson-02.m3u8"
    ],
    fileNames: [
        "lesson-01.mp4",
        "lesson-02.mp4"
    ]
)

try await BatchDownloadManager.shared.startBatchDownload(batchId: result.batchTask.id)
print(result.summary)
```

批量创建时，单个 URL 创建失败不会中断其他任务。失败项会记录 URL、文件名和错误原因，可在批量详情中编辑后单独重试。

## 进度信息

`DownloadProgress` 提供以下信息：

```swift
struct DownloadProgress {
    let taskId: UUID              // 任务ID
    let totalBytes: Int64         // 总字节数
    let downloadedBytes: Int64    // 已下载字节数
    let progress: Float           // 进度 0.0-1.0
    let speed: Int64              // 下载速度（字节/秒）
    let remainingTime: TimeInterval? // 预计剩余时间

    var percentage: String        // "50.5%"
    var formattedSpeed: String    // "1.5 MB/s"
    var formattedDownloaded: String // "25.3 MB"
    var formattedTotal: String    // "50.0 MB"
}
```

## 下载状态

```swift
enum DownloadState {
    case pending      // 等待中
    case downloading  // 下载中
    case paused       // 已暂停
    case completed    // 已完成
    case failed       // 失败
    case cancelled    // 已取消
}
```

## 错误处理

组件提供完善的错误处理：

```swift
enum DownloadError: Error {
    case invalidURL(String)           // 无效URL
    case networkError(Error)          // 网络错误
    case parseError(String)           // 解析错误
    case fileSystemError(Error)       // 文件系统错误
    case insufficientStorage(required: Int64, available: Int64)
    case taskCancelled                // 任务已取消
    case taskFailed(Error)            // 任务失败
    case encryptionNotSupported       // 不支持的加密方式
    case invalidM3U8Format            // 无效的M3U8格式
    case thunderProtocolError         // 迅雷协议错误
    case liveStreamNotSupported       // 暂不支持直播 HLS 流
    case keyFormatNotSupported(format: String)
    case byteRangeRequestFailed(url: String)
    case p2pDownloadNotSupported(protocolType: String)
    case magnetLinkNotSupported
}
```

错误处理示例：

```swift
do {
    let task = try await downloadEngine.createDownloadTask(url: url)
    try await downloadEngine.startDownload(task: task)
} catch DownloadError.insufficientStorage(let required, let available) {
    print("存储空间不足。需要：\(required)字节，可用：\(available)字节")
} catch DownloadError.invalidURL(let url) {
    print("无效的URL: \(url)")
} catch {
    print("下载失败: \(error.localizedDescription)")
}
```

## 配置选项

```swift
struct DownloadConfiguration {
    let maxConcurrentDownloads: Int      // 最大并发下载数（默认5）
    let timeoutInterval: TimeInterval    // 超时时间（默认30秒）
    let retryCount: Int                  // 重试次数（默认3次）
    let enableBackgroundDownload: Bool   // 启用后台下载（默认true）
    let customHeaders: [String: String]  // 单任务自定义请求头
    let allowCellularDownload: Bool      // 是否允许蜂窝网络下载
}

// 使用自定义配置
let config = DownloadConfiguration(
    maxConcurrentDownloads: 3,
    timeoutInterval: 60,
    retryCount: 5,
    enableBackgroundDownload: false,
    customHeaders: ["Authorization": "Bearer token"],
    allowCellularDownload: false
)

let task = try await downloadEngine.createDownloadTask(
    url: url,
    fileName: "video.mp4",
    configuration: config
)
```

## 文件存储

下载的文件存储在以下目录：

```
Documents/
└── VideoDownloads/
    ├── Completed/    // 已完成的视频
    │   ├── video1.mp4
    │   └── video2.mp4
    ├── InProgress/   // 正在下载的临时文件
    └── Cache/        // 缓存文件
```

## 技术栈

- **Swift Concurrency**: async/await, Task, Actor
- **Combine**: 响应式进度回调
- **Foundation**: URLSession, FileManager, Codable
- **CommonCrypto**: AES-128解密

## 性能优化

1. **网络优化**
   - URLSession配置优化
   - 蜂窝和昂贵网络策略跟随配置
   - HTTP/2支持
   - 连接复用

2. **内存优化**
   - 流式下载，避免大文件加载到内存
   - 及时释放已处理的TS片段
   - autoreleasepool管理

3. **并发优化**
   - TS片段并发下载（控制并发数）
   - 下载队列支持动态并发数和任务优先级

4. **存储优化**
   - 定期清理临时文件
   - 自动删除已合并的TS片段
   - 下载过程中持续检查剩余空间

## 注意事项

1. **Info.plist配置**

当前工程的 ATS 配置默认不全局放开 HTTP，只允许本地网络，并开启后台下载模式：

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

如果业务必须下载 HTTP 明文资源，建议按域名配置 ATS 例外，不建议重新启用全局 `NSAllowsArbitraryLoads=true`。

2. **Demo App 页面**

Demo App 入口在 `MainTabBarController.swift`，包含：
- `ViewController.swift`：单任务下载
- `BatchDownloadViewController.swift`：批量下载
- `CompletedFilesViewController.swift`：已完成文件
- `SettingsViewController.swift`：设置

源码中没有 `DownloadManagerView.swift`；如果业务项目需要嵌入式下载管理组件，可以参考现有 ViewController 拆分自己的 View。

3. **存储权限**

确保应用有文件读写权限。

4. **网络权限**

确保应用有网络访问权限。

5. **测试URL**

使用真实的、可访问的视频URL进行测试。

## 已知限制

- M3U8 Live 流不支持下载；仅支持可结束的 VOD HLS。
- `magnet:` 和需要 P2P/BT 客户端的迅雷链接只识别并返回明确错误，不执行 P2P 下载。
- 后台下载、系统通知、蜂窝网络策略和批量恢复建议在真机或可用模拟器环境补充验证。
- 当前代码以 App 源码集成方式组织，未封装为 Swift Package 或二进制 SDK。

## 示例项目

查看 `ViewController.swift` 文件中的完整示例代码，演示了：
- 创建下载任务
- 监听进度和状态
- 暂停/恢复/取消下载
- 错误处理
- UI更新

更多批量下载、失败项处理和已完成文件管理示例可查看 `BatchDownloadViewController.swift`（包含 `BatchAddViewController`、`BatchTaskDetailViewController`）和 `CompletedFilesViewController.swift`。

## 许可证

MIT License

## 作者

hubin (2026/4/29)
