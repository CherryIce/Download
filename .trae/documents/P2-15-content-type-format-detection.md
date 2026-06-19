# P2 问题15 修复计划：视频格式检测增强 — Content-Type 智能识别

## 摘要

修复 `VideoDownloadEngine.swift` 中 `detectVideoFormat` 方法仅靠 URL 字符串匹配的问题。当 URL 无扩展名（短链接、CDN 链接）时，通过 HEAD 请求获取 Content-Type 进行二次检测，避免误判为 MP4。同时扩展 `VideoFormat` 枚举支持更多格式，消除重复代码。

## 当前状态分析

**问题代码** (`VideoDownloadEngine.swift` 第431-444行)：
```swift
private func detectVideoFormat(from url: String) throws -> VideoFormat {
    let lowercased = url.lowercased()
    if lowercased.hasPrefix("thunder://") { return .thunder }
    else if lowercased.contains(".m3u8") { return .m3u8 }
    else if lowercased.contains(".mp4") { return .mp4 }
    else { return .mp4 }  // 所有无法识别的URL都默认为mp4
}
```

**缺陷**：
- CDN 短链接如 `https://cdn.example.com/v/abc123` 无扩展名，总是被误判为 MP4
- 实际可能是 M3U8 (HLS) 流媒体，导致用 MP4 下载器去下载 M3U8 内容
- `ThunderDownloadHandler.swift` 第61-72行存在完全重复的 `detectVideoFormat` 方法
- `VideoFormat` 枚举仅支持 mp4/m3u8/thunder 三种格式

**已有基础设施**：
- `NetworkClient.fetchRemoteFileSize(from:)` 已有 HEAD 请求能力（第250-263行），但只读 Content-Length
- 数据库 `VideoFormat(rawValue:) ?? .mp4` 的 fallback 机制天然兼容新增枚举值

## 检测策略：三级优先级

```
输入 URL
  ├─ 第一级：URL 字符串快速匹配（无网络开销）
  │    thunder:// → .thunder, .m3u8 → .m3u8, .mp4 → .mp4, .webm → .webm 等
  │
  ├─ 第二级：HEAD 请求 Content-Type（一次网络往返）
  │    application/vnd.apple.mpegurl → .m3u8, video/mp4 → .mp4, video/webm → .webm 等
  │
  └─ 第三级：兜底 .mp4（HEAD 请求失败时）
```

## 变更清单

### 1. 扩展 `VideoFormat` 枚举
**文件**: `DownLoad/DownLoad/Models/VideoFormat.swift`
- 新增 `.webm`, `.mkv`, `.flv`, `.mov` 四个枚举值
- 更新 `fileExtension` 计算属性，返回对应扩展名
- 新增 `isStreamingFormat` 计算属性

### 2. 新建 `VideoFormatDetector` 工具类
**文件**: `DownLoad/DownLoad/Utilities/VideoFormatDetector.swift`（新建）
- `detectFromURLString(_:)` — 静态方法，通过 URL 路径扩展名快速匹配
- `detectFromContentType(_:)` — 静态方法，通过 MIME 类型映射格式
- Content-Type 映射表覆盖 HLS/MP4/WebM/MKV/FLV/MOV
- 正确处理 Content-Type 带参数的情况（如 `video/mp4; charset=binary`）
- 使用 `URL.pathExtension` 替代简单 `contains` 避免误匹配

### 3. NetworkClient 新增 HEAD 请求方法
**文件**: `DownLoad/DownLoad/Network/NetworkClient.swift`
- 新增 `ResponseHeaders` 结构体（contentType/contentLength/statusCode）
- 新增 `fetchResponseHeaders(from:)` 方法，复用 `makeRequest` 和重试机制
- URLSession 默认跟随重定向，获取最终 URL 的 Content-Type

### 4. 重构 `VideoDownloadEngine.detectVideoFormat`
**文件**: `DownLoad/DownLoad/Core/VideoDownloadEngine.swift`
- 方法改为 `async`，集成三级检测策略
- 第一级调用 `VideoFormatDetector.detectFromURLString`
- 第二级调用 `networkClient.fetchResponseHeaders` + `VideoFormatDetector.detectFromContentType`
- 第三级 fallback 到 `.mp4`
- 更新 `createHandler` 的 switch，新增 `.webm/.mkv/.flv/.mov` case（走 MP4 下载器）
- 更新 `restoreTasksFromDatabase` 的 switch，同上

### 5. 修复 `ThunderDownloadHandler` 重复代码
**文件**: `DownLoad/DownLoad/Handlers/ThunderDownloadHandler.swift`
- 删除第61-72行的重复 `detectVideoFormat` 方法
- 新增 `networkClient` 属性
- 使用共享的 `VideoFormatDetector` + HEAD 请求检测逻辑
- 更新 switch 新增 `.webm/.mkv/.flv/.mov` case（委托给 mp4Handler）

### 6. 更新 `BatchDownloadManager.getFileExtension`
**文件**: `DownLoad/DownLoad/Core/BatchDownloadManager.swift`
- 改用 `VideoFormatDetector.detectFromURLString` 替代硬编码逻辑

## Content-Type 映射表

| Content-Type (MIME) | 映射到 |
|---|---|
| `application/vnd.apple.mpegurl` / `application/x-mpegurl` / `audio/mpegurl` | `.m3u8` |
| `video/mp4` / `video/mpeg` / `application/mp4` / `application/octet-stream` | `.mp4` |
| `video/webm` / `audio/webm` | `.webm` |
| `video/x-matroska` / `video/matroska` | `.mkv` |
| `video/x-flv` / `video/flv` | `.flv` |
| `video/quicktime` / `video/x-quicktime` | `.mov` |

## 边缘情况处理

| 场景 | 策略 |
|---|---|
| URL 无扩展名 + HEAD 超时 | 捕获异常，fallback `.mp4`，记录 warning 日志 |
| HEAD 返回 403/404 | 捕获 httpError，fallback `.mp4` |
| 301/302 重定向 | URLSession 自动跟随，获取最终 Content-Type |
| Content-Type 为空/缺失 | fallback `.mp4` |
| Content-Type 带参数 | 取分号前的 MIME 部分 |
| 数据库旧数据 | `VideoFormat(rawValue:) ?? .mp4` 天然兼容 |

## 实施顺序

1. `VideoFormat.swift` — 扩展枚举（基础依赖）
2. `VideoFormatDetector.swift` — 新建工具类（无外部依赖）
3. `NetworkClient.swift` — 新增 fetchResponseHeaders
4. `VideoDownloadEngine.swift` — 重构检测逻辑 + 更新 switch
5. `ThunderDownloadHandler.swift` — 消除重复代码
6. `BatchDownloadManager.swift` — 更新 getFileExtension

## 验证步骤

1. 编译通过：`xcodebuild build -scheme DownLoad -destination 'platform=iOS Simulator,name=iPhone 16'`
2. 检查所有 switch 对 `VideoFormat` 的 exhaustive 匹配（Swift 编译器强制）
3. 确认 `VideoFormatDetector.detectFromURLString` 对各种 URL 的返回值正确
4. 确认 HEAD 请求失败时 graceful fallback
5. 更新缺陷修复优先级排序.md，标记问题15为已修复
