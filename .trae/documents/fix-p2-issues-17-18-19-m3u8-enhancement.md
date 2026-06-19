# 修复 P2 问题 17、18、19：M3U8 密钥轮换/SAMPLE-AES、fMP4 容器、VOD/Live 区分

## 摘要

修复 M3U8 解析和下载的三个 P2 级缺陷：
- **问题 17**：仅支持 AES-128 单密钥，不支持密钥轮换和 SAMPLE-AES
- **问题 18**：不支持 fMP4 容器（`#EXT-X-MAP`）和字节范围（`#EXT-X-BYTERANGE`）
- **问题 19**：不区分 VOD 和 Live 流，未检测 `#EXT-X-ENDLIST`

## 当前状态分析

### 问题 17 现状
- `M3U8Parser.parseEncryptionInfo()` 已能解析 `METHOD=SAMPLE-AES`，但 `M3U8Encryption` 缺少 `keyFormat` 字段
- `M3U8DownloadHandler.createTask()` 第 51 行只取第一个片段的密钥（`mediaPlaylist.segments.first?.encryption`）
- `M3U8DownloadTask` 只存储单个 `encryptionKey: Data?`
- `decryptData()` 仅支持 AES-128-CBC（PKCS7 填充），不支持 AES-128-CTR（SAMPLE-AES 所需）

### 问题 18 现状
- 解析器不识别 `#EXT-X-MAP`（fMP4 初始化片段）和 `#EXT-X-BYTERANGE`（子范围片段）
- 所有片段固定保存为 `.ts` 扩展名
- `mergeSegments()` 简单字节拼接，不支持 fMP4 的 init segment + media segments 合并

### 问题 19 现状
- 解析器不检查 `#EXT-X-ENDLIST` 标签
- `M3U8MediaPlaylist` 没有 `isLive` 属性
- 下载器假设所有播放列表都是 VOD（固定片段列表），直播流会静默失败

---

## 实施计划

### 步骤 1：扩展模型层 — `M3U8Models.swift`

**1.1 扩展 `M3U8Encryption`**，新增 `keyFormat` 字段：
```swift
struct M3U8Encryption {
    let method: M3U8EncryptionMethod
    let keyURL: URL
    let iv: Data?
    let keyFormat: String?          // 新增：密钥格式
}
```

**1.2 新增 `M3U8ByteRange` 结构体**：
```swift
struct M3U8ByteRange {
    let length: Int
    let offset: Int?  // nil 表示接续上一个范围末尾
}
```

**1.3 新增 `M3U8MapInfo` 结构体**：
```swift
struct M3U8MapInfo {
    let uri: URL
    let byteRange: M3U8ByteRange?
}
```

**1.4 扩展 `M3U8Segment`**，新增 `byteRange` 和 `map` 字段：
```swift
struct M3U8Segment {
    let url: URL
    let duration: Double
    let encryption: M3U8Encryption?
    let byteRange: M3U8ByteRange?   // 新增
    let map: M3U8MapInfo?            // 新增（片段级 MAP 覆盖，通常 nil）
}
```

**1.5 扩展 `M3U8MediaPlaylist`**，新增 `isLive`、`mediaSequence`、`map`、`isFMP4` 字段：
```swift
struct M3U8MediaPlaylist: M3U8Playlist {
    let segments: [M3U8Segment]
    let targetDuration: Double
    let isEncrypted: Bool
    let version: Int?
    let isLive: Bool                 // 新增
    let mediaSequence: Int?          // 新增
    let map: M3U8MapInfo?            // 新增
    let isFMP4: Bool                 // 新增
    // 保留现有计算属性
}
```

**1.6 扩展 `M3U8DownloadState`**，新增 fMP4 和密钥轮换支持字段：
```swift
struct M3U8DownloadState: Codable {
    // 保留现有字段...
    var isFMP4: Bool                           // 新增
    var encryptionKeys: [String: String]       // 新增：keyURL -> 缓存文件名
    var initSegmentDownloaded: Bool            // 新增
    // 注意：新字段需有默认值，保证旧状态文件可反序列化
}
```

### 步骤 2：扩展解析器 — `M3U8Parser.swift`

**2.1 在 `parseMediaPlaylist()` 中新增解析逻辑**：
- 检测 `#EXT-X-ENDLIST` → 设置 `hasEndList` 标志
- 解析 `#EXT-X-MEDIA-SEQUENCE` → `mediaSequence`
- 解析 `#EXT-X-MAP:URI="init.mp4",BYTERANGE="..."` → `currentMap`
- 解析 `#EXT-X-BYTERANGE:length[@offset]` → `pendingByteRange`（暂存，在下一个 URL 行赋给片段）
- 将 `currentMap` 和 `pendingByteRange` 赋给每个 `M3U8Segment`

**2.2 新增 `parseMapInfo(line:baseURL:)` 方法**：
- 提取 `URI` 和可选的 `BYTERANGE` 属性

**2.3 新增 `parseByteRange(_:)` 方法**：
- 解析 `length@offset` 或仅 `length` 格式

**2.4 扩展 `parseEncryptionInfo()`**：
- 新增提取 `KEYFORMAT` 属性
- 当 `KEYFORMAT="com.apple.streamingkeydelivery"` 时返回特殊标记（FairPlay DRM 不支持）

### 步骤 3：扩展错误处理 — `DownloadError.swift`

新增错误类型：
```swift
case liveStreamNotSupported           // 直播流暂不支持下载
case keyFormatNotSupported(format: String)  // 不支持的密钥格式（如 FairPlay）
case byteRangeRequestFailed(url: String)    // 字节范围请求失败
```

### 步骤 4：修复密钥轮换和 SAMPLE-AES — `M3U8DownloadHandler.swift`（问题 17）

**4.1 修改 `M3U8DownloadHandler.createTask()`**：
- 收集所有唯一密钥 URL：`Set(segments.compactMap { $0.encryption?.keyURL })`
- 检测 FairPlay DRM（`keyFormat == "com.apple.streamingkeydelivery"`），抛出 `keyFormatNotSupported`
- 批量下载所有密钥到缓存字典 `[URL: Data]`

**4.2 修改 `M3U8DownloadTask`**：
- 将 `let encryptionKey: Data?` 改为 `private var encryptionKeyCache: [URL: Data]`
- 更新 `init` 签名接收 `[URL: Data]` 参数

**4.3 修改 `downloadSegment()`**：
- 使用 `encryptionKeyCache[segment.encryption.keyURL]` 获取对应密钥
- 传递 `encryption.method` 给 `decryptData()`

**4.4 扩展 `decryptData()`**：
- 新增 `method` 参数
- `aes128` → 现有 AES-128-CBC 逻辑
- `sampleAES` → 新增 AES-128-CTR 解密（`kCCModeOptionCTR_BE`，无填充）
- `none` → 直接返回数据

**4.5 新增 `AESCTRDecryptor` 类**：
- 与 `AESDecryptor` 类似，但使用 `kCCModeOptionCTR_BE` 选项

### 步骤 5：支持 fMP4 和字节范围 — `M3U8DownloadHandler.swift`（问题 18）

**5.1 修改 `downloadSegment()`**：
- 支持字节范围下载：当 `segment.byteRange != nil` 时，使用 `URLRequest` 的 `Range` header 下载
- 根据 `playlist.isFMP4` 选择文件扩展名（`.m4s` 或 `.ts`）

**5.2 新增 `downloadByteRange(from:byteRange:)` 方法**：
- 构造 `Range: bytes=offset-end` header
- 使用 `URLSession.shared.data(for:)` 发起请求

**5.3 在 `resume()` 中下载初始化片段**：
- 当 `playlist.map != nil` 时，在并发下载片段之前先下载 init segment
- 保存为 `init_segment.mp4`

**5.4 修改 `mergeSegments()`**：
- 提取公共 `appendFile(_:to:bufferSize:)` 方法
- fMP4 分支：先写 `init_segment.mp4`，再按序写所有 `.m4s` 片段
- TS 分支：保持现有逻辑不变

**5.5 修改 `calibrateDownloadedBytes()`**：
- 根据 `playlist.isFMP4` 使用对应扩展名扫描已下载片段

### 步骤 6：VOD/Live 区分 — `M3U8DownloadHandler.swift`（问题 19）

**6.1 在 `createTask()` 中检测直播流**：
- 获取 `mediaPlaylist` 后检查 `isLive`
- 如果是直播流，抛出 `DownloadError.liveStreamNotSupported`，提供明确错误信息

**设计决策**：直播流下载需要持续轮询新片段，与当前有限任务架构差异较大。本次先实现检测和拒绝，避免静默失败。后续可迭代实现 `LiveM3U8DownloadTask`。

### 步骤 7：同步更新 `VideoDownloadEngine.swift` 恢复逻辑

**7.1 修改 `restoreTasksFromDatabase()` 中 M3U8 恢复部分**（第 302-347 行）：
- 收集所有唯一密钥 URL 并批量下载
- 传递 `encryptionKeyCache` 给 `M3U8DownloadTask` 初始化
- 同步更新 `init` 调用签名

### 步骤 8：更新 Constants

在 `Constants.M3U8` 中新增：
```swift
static let maxEncryptionKeys: Int = 10    // 密钥轮换数量上限
```

---

## 涉及文件汇总

| 文件 | 更改类型 | 涉及问题 |
|------|---------|---------|
| `M3U8Models.swift` | 修改 | 17, 18, 19 |
| `M3U8Parser.swift` | 修改 | 17, 18, 19 |
| `M3U8DownloadHandler.swift` | 修改 | 17, 18, 19 |
| `DownloadError.swift` | 修改 | 17, 19 |
| `Constants.swift` | 修改 | 17 |
| `VideoDownloadEngine.swift` | 修改 | 17 |

## 假设与决策

1. **SAMPLE-AES 实现策略**：实现 AES-128-CTR 全段解密作为基础支持。对于 `identity` keyFormat 的 SAMPLE-AES-CTR 流可正常工作。FairPlay DRM（`com.apple.streamingkeydelivery`）直接拒绝并报错。
2. **直播流策略**：本次仅实现检测和拒绝，不实现轮询下载。后续迭代可添加 `LiveM3U8DownloadTask`。
3. **字节范围请求**：直接使用 `URLSession.shared`，不修改 `NetworkClient` 接口。
4. **向后兼容**：所有新增模型字段均为 optional 或有默认值，不影响现有 TS-only 工作流。

## 验证步骤

1. 编译项目确保无错误：`xcodebuild -project DownLoad.xcodeproj -scheme DownLoad -destination 'platform=iOS Simulator,name=iPhone 16' build`
2. 检查 `缺陷修复优先级排序.md` 中问题 17、18、19 的状态标记更新为 ✅ 已修复
3. 验证 TS-only M3U8 下载流程不受影响（回归验证）
