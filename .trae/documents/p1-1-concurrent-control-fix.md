# P1-1 并发控制未生效缺陷修复计划

> **目标**：修复 `DownloadQueueManager` 并发控制未生效的问题，限制同时运行的下载任务数量为3个，防止内存暴涨、网络拥塞和OOM崩溃。

**当前状态分析：**
- `DownloadQueueManager` 声明了 `maxConcurrentTasks: Int = 3`，但 `addTask` 方法仅将任务存入字典，没有任何并发控制逻辑
- `VideoDownloadEngine.startDownload(task:)` 直接调用 `task.resume()`，导致所有任务同时运行
- `BatchDownloadManager.startBatchDownload(batchId:)` 循环调用 `startDownload`，批量任务全部并发
- 后果：用户可无限制并发下载，内存暴涨、网络拥塞、系统卡顿甚至OOM崩溃

**修复方案：**
采用 **"运行槽位 + 等待队列"** 模型，在 `DownloadQueueManager` 内部实现自动调度：
- `runningTaskIds: Set<UUID>` 记录当前正在运行的任务，上限为 `maxConcurrentTasks`
- `pendingQueue: [UUID]` FIFO队列存储等待执行的任务
- 通过订阅 `DownloadTask.state`（Combine `CurrentValueSubject`）监听状态变化，自动触发调度
- 当任务完成/暂停/失败/取消时，自动从等待队列取出任务填充空槽位

**修改文件清单：**

| 文件路径 | 修改类型 | 修改内容 |
|---------|---------|---------|
| `DownLoad/DownLoad/Core/DownloadQueueManager.swift` | 修改 | 添加并发控制逻辑：运行槽位、等待队列、状态订阅、自动调度 |
| `DownLoad/DownLoad/Core/VideoDownloadEngine.swift` | 修改 | 调整 `startDownload` 方法，避免与队列管理器的自动调度冲突 |
| `DownLoad/DownLoad/Core/BatchDownloadManager.swift` | 修改 | 调整 `startBatchDownload` 方法，移除循环 `startDownload` 调用 |
| `DownLoad/DownLoadTests/DownloadQueueManagerTests.swift` | 新增 | 单元测试覆盖并发控制核心逻辑 |

**关键设计决策：**
1. 使用 `Set<UUID>` 记录运行中任务（精确追踪、防重复启动、安全移除）
2. 使用 `[UUID]` 数组作为等待队列（FIFO顺序保证）
3. 状态订阅使用 `receive(on: DispatchQueue.global(qos: .utility))` + `Task { @MainActor in await ... }` 确保线程安全
4. `startTask` 内部创建独立 `Task` 调用 `resume()`，避免阻塞actor消息队列
5. 保持 `addTask` 同步签名，与现有调用方兼容

**验证步骤：**
1. 单元测试：验证不超过并发上限、任务完成后自动调度、等待队列FIFO行为
2. 集成测试：批量下载10个任务，验证同时运行不超过3个
3. 手动验证：观察日志确认任务调度行为正确，使用Xcode Debug Navigator监控内存和网络

**潜在风险与应对：**
- 状态订阅回调延迟 → 使用 `.receive(on:)` 确保及时；添加防御性检查
- 任务重复调度 → `Set` 去重 + `contains` 检查
- 内存泄漏 → `removeTask` 和 `clearAll` 中显式取消订阅
- Actor死锁 → `startTask` 中创建独立 `Task` 执行 `resume()`
