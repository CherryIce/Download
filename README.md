# Swift视频下载组件

一个功能强大的Swift视频下载组件，支持MP4、M3U8（HLS流媒体）和迅雷协议下载。

## 功能特性

- ✅ **MP4下载**：直接下载，支持断点续传
- ✅ **M3U8下载**：解析HLS流媒体，下载TS片段并合并
- ✅ **迅雷协议**：解析thunder://链接并下载
- ✅ **AES-128解密**：支持加密的M3U8视频
- ✅ **并发下载**：多个TS片段并发下载，提高速度
- ✅ **进度回调**：实时进度更新，显示下载速度
- ✅ **错误处理**：自动重试，完善的错误处理机制
- ✅ **存储管理**：自动清理临时文件，缓存管理
- ✅ **Swift Concurrency**：使用async/await现代异步编程

## 架构设计

```
VideoDownloader
├── Core Layer         - 下载引擎和任务管理
├── Parser Layer       - URL和视频格式解析
├── Handler Layer      - 不同格式下载处理器
├── Network Layer      - 网络请求封装
├── Storage Layer      - 文件和缓存管理
├── Model Layer        - 数据模型
└── Utility Layer      - 工具类和配置
```

## 安装

无需额外依赖，直接将以下文件夹添加到项目中：

- Core/
- Parsers/
- Handlers/
- Network/
- Storage/
- Models/
- Utilities/
- Protocols/

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
                        print("State: \(state)")
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

### 2. 下载MP4视频

```swift
let task = try await VideoDownloadEngine.shared.createDownloadTask(
    url: "https://example.com/video.mp4",
    fileName: "my_video.mp4"
)
try await VideoDownloadEngine.shared.startDownload(task: task)
```

### 3. 下载M3U8流媒体

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
- 支持AES-128加密视频
- 并发下载TS片段（默认5个并发）
- 自动合并TS片段为完整视频

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
    case insufficientStorage          // 存储空间不足
    case taskCancelled                // 任务已取消
    case taskFailed(Error)            // 任务失败
    case encryptionNotSupported       // 不支持的加密方式
    case invalidM3U8Format            // 无效的M3U8格式
    case thunderProtocolError         // 迅雷协议错误
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
}

// 使用自定义配置
let config = DownloadConfiguration(
    maxConcurrentDownloads: 3,
    timeoutInterval: 60,
    retryCount: 5,
    enableBackgroundDownload: false
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
   - HTTP/2支持
   - 连接复用

2. **内存优化**
   - 流式下载，避免大文件加载到内存
   - 及时释放已处理的TS片段
   - autoreleasepool管理

3. **并发优化**
   - TS片段并发下载（控制并发数）
   - OperationQueue优先级控制

4. **存储优化**
   - 定期清理临时文件
   - 自动删除已合并的TS片段

## 注意事项

1. **Info.plist配置**

需要添加以下配置以支持HTTP请求和后台下载：

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>

<key>UIBackgroundModes</key>
<array>
    <string>fetch</string>
</array>
```

2. **存储权限**

确保应用有文件读写权限。

3. **网络权限**

确保应用有网络访问权限。

4. **测试URL**

使用真实的、可访问的视频URL进行测试。

## 示例项目

查看 `ViewController.swift` 文件中的完整示例代码，演示了：
- 创建下载任务
- 监听进度和状态
- 暂停/恢复/取消下载
- 错误处理
- UI更新

## 许可证

MIT License

## 作者

hubin (2026/4/29)

