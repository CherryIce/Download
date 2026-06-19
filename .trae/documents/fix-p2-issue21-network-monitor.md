# P2 问题21：网络切换（WiFi/蜂窝）处理完全缺失 -- 修复计划

## 摘要

当前项目完全没有网络状态监控能力。网络断开时下载直接失败，WiFi/蜂窝切换无任何处理。本方案引入 `NWPathMonitor` 实现网络状态实时监控，网络断开时自动暂停所有下载任务并标记暂停原因，网络恢复时自动恢复因网络原因暂停的任务（用户手动暂停的不受影响）。同时支持蜂窝下载策略配置。

## 当前状态分析

- **无任何网络监控代码**：项目中没有 `NWPathMonitor`、`Reachability` 或任何网络状态检测
- **网络断开直接失败**：下载任务遇到网络错误后状态变为 `.failed`，不会自动暂停
- **无暂停原因区分**：`DownloadTask` 协议没有暂停原因字段，无法区分"用户暂停"和"系统暂停"
- **无蜂窝策略**：`DownloadConfiguration` 没有蜂窝下载开关

## 变更方案

### 1. 新建 `Network/NetworkMonitor.swift`

新建网络监控器单例，封装 `NWPathMonitor`：

- `NetworkStatus` 枚举：`.unavailable` / `.wifi` / `.cellular` / `.unknown`
- `NetworkMonitor` 单例类：
  - `currentStatus: CurrentValueSubject<NetworkStatus, Never>` 发布当前真实网络状态
  - `statusChanged: PassthroughSubject<NetworkStatus, Never>` 发布状态变更事件
  - `isCellularAllowed: Bool` 控制是否允许蜂窝下载（默认 `true`）
  - `isNetworkAvailableForDownload: Bool` 综合判断（有网络 + 蜂窝策略）
  - `NWPathMonitor` 在专用串行队列 `com.video.downloader.network.monitor` 上运行
  - 回调中切换到主线程发布 Combine 事件

### 2. 修改 `Utilities/Constants.swift`

新增 `NetworkMonitor` 常量子结构体：

```swift
struct NetworkMonitor {
    static let networkRestoreDelay: TimeInterval = 2.0    // 网络恢复后延迟恢复（防抖）
    static let networkLostDelay: TimeInterval = 0.5       // 网络断开后延迟暂停（防抖）
    static let defaultAllowCellularDownload = true         // 默认允许蜂窝下载
}
```

### 3. 修改 `Utilities/DownloadConfiguration.swift`

新增 `allowCellularDownload` 属性：

- 在 `DownloadConfiguration` struct 中新增 `let allowCellularDownload: Bool`
- 默认值从 `Constants.NetworkMonitor.defaultAllowCellularDownload` 读取
- `init` 方法新增同名参数（默认值同上）

### 4. 修改 `Core/DownloadTaskProtocol.swift`

新增暂停原因机制：

- 新增 `PauseReason` 枚举：`.userInitiated` / `.networkLost` / `.cellularRestricted`
- 协议新增 `var pauseReason: PauseReason? { get set }`
- 协议新增 `func pause(reason: PauseReason) async`

### 5. 修改 `Handlers/MP4DownloadHandler.swift`（MP4DownloadTask）

- 新增 `var pauseReason: PauseReason? = nil` 属性
- 新增 `pause(reason:)` 方法：设置 `pauseReason` 后委托给 `pause()`
- 修改 `resume()`：恢复时清除 `pauseReason = nil`
- 修改 `pause()`：若 `pauseReason == nil` 则默认设为 `.userInitiated`
- 修改 `cancel()`：清除 `pauseReason = nil`

### 6. 修改 `Handlers/M3U8DownloadHandler.swift`（M3U8DownloadTask）

与 MP4DownloadTask 对称的修改：

- 新增 `var pauseReason: PauseReason? = nil`
- 新增 `pause(reason:)` 方法
- 修改 `resume()` 清除 pauseReason
- 修改 `pause()` 默认标记 `.userInitiated`
- 修改 `cancel()` 清除 pauseReason

### 7. 修改 `Core/ResumableDownloadTask.swift`

与上述两个 Task 类保持一致：

- 新增 `var pauseReason: PauseReason? = nil`
- 新增 `pause(reason:)` 方法
- 修改 `resume()` / `pause()` / `cancel()`

### 8. 修改 `Core/VideoDownloadEngine.swift`

核心变更，新增网络监控集成：

- 新增 `import Network`
- 新增属性：`networkCancellables: Set<AnyCancellable>`、`networkRestoreWorkItem`、`networkLostWorkItem`
- `init()` 中调用 `setupNetworkMonitoring()`
- 新增 `setupNetworkMonitoring()`：订阅 `NetworkMonitor.shared.statusChanged`
- 新增 `handleNetworkStatusChange(_:)`：
  - `.unavailable` -> 延迟 0.5s 后调用 `pauseAllDownloadingTasks(reason: .networkLost)`
  - `.cellular` + 不允许蜂窝 -> 延迟 0.5s 后调用 `pauseAllDownloadingTasks(reason: .cellularRestricted)`
  - 其他（WiFi 或允许的蜂窝）-> 延迟 2s 后调用 `resumeNetworkPausedTasks()`
  - 每次状态变化取消前一个延迟任务（防抖）
- 新增 `pauseAllDownloadingTasks(reason:)`：遍历所有任务，只暂停 `state == .downloading` 的
- 新增 `resumeNetworkPausedTasks()`：只恢复 `pauseReason == .networkLost || .cellularRestricted` 的暂停任务
- 修改 `createDownloadTask()`：创建前检查 `NetworkMonitor.shared.isNetworkAvailableForDownload`
- 修改 `startDownload()`：启动前检查网络可用性

### 9. 修改 `AppDelegate.swift`

- 在 `didFinishLaunchingWithOptions` 中新增 `_ = NetworkMonitor.shared` 初始化

## 假设与决策

1. **不持久化 pauseReason**：App 重启后网络状态重新评估，恢复的任务没有 pauseReason（nil），不会被自动恢复，用户需手动恢复。这是合理行为。
2. **防抖延迟**：网络恢复 2s 延迟、网络断开 0.5s 延迟，避免频繁切换导致状态抖动。
3. **不修改数据库 schema**：pauseReason 仅在内存中，不需要 V4 迁移。
4. **蜂窝策略全局生效**：`NetworkMonitor.isCellularAllowed` 是全局设置，`DownloadConfiguration.allowCellularDownload` 是 per-task 配置（预留，当前未在创建任务时使用，未来可用于设置页面）。

## 验证步骤

1. **编译验证**：修改完成后执行 `xcodebuild` 确认编译通过
2. **功能验证**：
   - 开启下载任务 -> 开启飞行模式 -> 任务自动暂停（pauseReason == .networkLost）
   - 关闭飞行模式 -> 2s 后任务自动恢复
   - 用户手动暂停任务 -> 网络断开再恢复 -> 手动暂停的任务不自动恢复
3. **记录验证**：修复完成后在 `缺陷修复优先级排序.md` 中将问题21标记为已修复
