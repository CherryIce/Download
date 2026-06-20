# P3 问题36 修复计划：扩展迅雷链接支持（thunderp2p:// 和 magnet:）

## 概要

当前 `ThunderParser` 仅支持经典 `thunder://` 格式（Base64 编码的 AA+URL+ZZ），不支持 `thunderp2p://` 和磁力链接。本次修复将扩展解析器支持 `thunderp2p://` 格式，识别磁力链接，并在检测到 P2P/磁力链接时给出明确的错误提示。

## 现状分析

当前迅雷链接处理链路：
1. `VideoFormatDetector.detectFromURLString()` 仅识别 `thunder://` 前缀 -> `.thunder`
2. `VideoDownloadEngine.createHandler(.thunder)` -> `ThunderDownloadHandler`
3. `ThunderParser.parse()` 仅接受 `thunder://` 前缀，Base64(AA+URL+ZZ) 解码
4. `ThunderDownloadHandler.createTask()` 解码后按格式委托给 MP4/M3U8 handler

**核心问题**：整条链路只认识 `thunder://`，对 `thunderp2p://` 和 `magnet:` 完全无法识别。

## 修改方案

### 文件 1：`VideoFormat.swift`（Models/VideoFormat.swift）
- 新增 `.thunderP2P` 和 `.magnet` 枚举值
- `fileExtension` 新增 `.thunderP2P`/`.magnet` -> `"torrent"` 占位
- `isDirectDownloadFormat` 新增 `.thunderP2P`/`.magnet` -> `false`

### 文件 2：`DownloadError.swift`（Protocols/DownloadError.swift）
- 新增 `p2pDownloadNotSupported(protocolType: String)` - P2P 下载不支持
- 新增 `magnetLinkNotSupported` - 磁力链接不支持
- 对应 `errorDescription` 返回中文提示信息

### 文件 3：`ThunderParser.swift`（Parsers/ThunderParser.swift）
- 引入 `ParseResult` 结构体（含 `url`/`isMagnetLink`/`isP2P`）
- 重构 `parse()` 方法支持 `thunder://` 和 `thunderp2p://` 两种前缀
- 拆分为 `parseClassicThunder()` 和 `parseThunderP2P()` 两个私有方法
- `thunderp2p://` 解码后判断内容类型：磁力链接 / AA+ZZ 包装 URL / 直接 URL / 无法识别
- 经典 `thunder://` 解码后也检查是否为磁力链接
- 新增 `isMagnetLink(_:)` 静态方法

### 文件 4：`VideoFormatDetector.swift`（Utilities/VideoFormatDetector.swift）
- `detectFromURLString()` 新增 `thunderp2p://` 前缀识别 -> `.thunderP2P`
- `detectFromURLString()` 新增 `magnet:` 前缀识别 -> `.magnet`

### 文件 5：`ThunderDownloadHandler.swift`（Handlers/ThunderDownloadHandler.swift）
- 重构 `createTask()` 按 format 分支处理（`.magnet`/`.thunderP2P`/`.thunder`）
- 新增 `handleClassicThunder()` - 解析经典链接，检测解码后是否为磁力链接
- 新增 `handleThunderP2P()` - 解析 P2P 链接，磁力链接抛错，普通 URL 委托
- 提取 `delegateToHandler()` 公共委托方法，避免重复代码

### 文件 6：`VideoDownloadEngine.swift`（Core/VideoDownloadEngine.swift）
- `createHandler()` 新增 `.thunderP2P` 和 `.magnet` case -> `ThunderDownloadHandler`
- `restoreTasksFromDatabase()` 扩展跳过 `.thunderP2P` 和 `.magnet` 格式

## 修改后数据流

| 输入 | 检测格式 | 解析结果 | 最终行为 |
|------|---------|---------|---------|
| `thunder://...`（HTTP URL） | `.thunder` | 解码为普通 URL | 委托 MP4/M3U8 下载（不变） |
| `thunder://...`（磁力链接） | `.thunder` | 解码为 magnet: | 抛出 `magnetLinkNotSupported` |
| `thunderp2p://...`（磁力链接） | `.thunderP2P` | 解码为 magnet: | 抛出 `magnetLinkNotSupported` |
| `thunderp2p://...`（普通 URL） | `.thunderP2P` | 解码为 HTTP URL | 委托 MP4/M3U8 下载 |
| `thunderp2p://...`（无法识别） | `.thunderP2P` | 解析失败 | 抛出 `thunderProtocolError` |
| `magnet:?xt=urn:btih:...` | `.magnet` | 无需解析 | 抛出 `magnetLinkNotSupported` |

## 假设与决策

- iOS App 无法实现真正的 P2P/BT 下载，因此对磁力链接和 P2P 链接触发明确错误提示而非静默失败
- `thunderp2p://` 内部格式无公开官方规范，采用防御性编程处理多种可能的编码内容
- `VideoFormat` 新增枚举值的 Codable rawValue 不影响已有数据库记录

## 验证步骤

1. 编译通过：`xcodebuild -project DownLoad.xcodeproj -scheme DownLoad -destination 'platform=iOS Simulator,name=iPhone 16' build`
2. 搜索验证：确认 `thunderp2p://` 和 `magnet:` 在 `VideoFormatDetector` 中被正确识别
3. 回归验证：经典 `thunder://` 链接的解析行为不变
4. 更新 `缺陷修复优先级排序.md` 中问题 36 的状态为已修复
