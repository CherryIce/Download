# P2 问题16修复计划：支持 WebM/MKV/FLV/MOV 等常见视频格式的正确文件扩展名

## 概述

P2 问题16描述为"仅支持 MP4/M3U8，不支持 WebM/MKV/FLV/MOV 等常见格式"。经过代码分析，格式检测和路由已由问题15修复完成，但存在**格式信息传递断裂**：`MP4DownloadHandler` 始终生成 `.mp4` 扩展名的文件名，`MP4DownloadTask` 硬编码 `format = .mp4`，导致 WebM/MKV/FLV/MOV 文件被保存为 `.mp4` 扩展名，播放器无法正确识别。

## 当前状态分析

**已就绪的部分（问题15完成）：**
- `VideoFormat` 枚举已包含 `.webm`/`.mkv`/`.flv`/`.mov`
- `VideoFormatDetector` 已支持从 URL 和 Content-Type 检测这些格式
- `VideoDownloadEngine.createHandler` 已将它们路由到 `MP4DownloadHandler`
- `restoreTasksFromDatabase` 的 switch-case 已处理这些格式
- 数据库 `format` 字段已支持存储任意格式字符串

**断裂点（本次修复）：**
1. `MP4DownloadHandler.createTask` 硬编码默认文件名 `.mp4`（第42行）
2. `MP4DownloadTask.format` 硬编码为 `.mp4`（第69行）
3. `DownloadHandlerProtocol.createTask` 无 `format` 参数，格式信息无法从 Engine 传递到 Handler
4. `VideoDownloadEngine.restoreTasksFromDatabase` 恢复 MP4 类任务时未传入实际格式

## 修改方案

### Step 1: 修改 `DownloadHandlerProtocol.swift`
- `createTask` 方法新增 `format: VideoFormat` 参数

### Step 2: 修改 `MP4DownloadHandler.swift`（核心修复）
- `createTask` 接收 `format` 参数
- 默认文件名使用 `format.fileExtension` 替代硬编码 `.mp4`
- `MP4DownloadTask` 的 `format` 属性改为可注入（非硬编码）
- `MP4DownloadTask.init` 新增 `format` 参数（默认值 `.mp4` 保持向后兼容）

### Step 3: 修改 `VideoDownloadEngine.swift`
- `createDownloadTask` 将检测到的 `format` 传递给 `handler.createTask`
- `restoreTasksFromDatabase` 恢复 MP4 类任务时传入 `item.format`

### Step 4: 适配 `M3U8DownloadHandler.swift` 和 `ThunderDownloadHandler.swift`
- `createTask` 签名添加 `format` 参数（满足协议要求，内部不使用）

### Step 5: 更新 `缺陷修复优先级排序.md`
- 标记问题16为已修复

## 涉及文件

| 文件 | 操作 | 说明 |
|------|------|------|
| `Handlers/DownloadHandlerProtocol.swift` | 修改 | 协议新增 `format` 参数 |
| `Handlers/MP4DownloadHandler.swift` | 修改 | 核心修复：format 传递 + 正确文件扩展名 |
| `Core/VideoDownloadEngine.swift` | 修改 | 传递 format 给 handler + 恢复时传入 format |
| `Handlers/M3U8DownloadHandler.swift` | 修改 | 适配协议签名 |
| `Handlers/ThunderDownloadHandler.swift` | 修改 | 适配协议签名 |
| `缺陷修复优先级排序.md` | 修改 | 标记已修复 |

## 假设与决策

- 用户自定义 `fileName` 时直接使用，不自动追加扩展名（当前逻辑 `fileName ??` 已保证）
- 旧数据库中 format 均为 "mp4"，恢复为 `.mp4` 是正确行为（当时确实只支持 MP4）
- M3U8 handler 不使用传入的 format 参数（M3U8 固定输出 MP4）

## 验证步骤

1. 确认所有修改文件编译通过
2. 验证 WebM/MKV/FLV/MOV URL 下载后文件扩展名正确
3. 验证 MP4 下载行为不受影响（向后兼容）
4. 验证数据库恢复后格式信息正确
5. 更新缺陷跟踪文件
