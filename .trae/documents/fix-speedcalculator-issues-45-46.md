# 修复 SpeedCalculator 问题 45-46

## 摘要
修复 P3 优先级中的两个问题：
- **问题 45**：`SpeedCalculator` 的 `calculateSpeed()` 和 `calculateAverageSpeed()` 两个方法逻辑完全重复
- **问题 46**：`SpeedCalculator` 的 `samples` 数组无线程安全保护，可能被并发访问导致数据竞争

## 当前状态分析

### 问题 45：逻辑重复
`SpeedCalculator.swift` 中 `calculateSpeed()`（第 32-45 行）和 `calculateAverageSpeed()`（第 48-57 行）代码几乎一模一样：
- 都取 `samples.first` 和 `samples.last`
- 都计算 `(last.bytes - first.bytes) / (last.timestamp - first.timestamp)`
- 唯一区别：`calculateSpeed()` 多了 `max(0, speed)` 负值保护，`calculateAverageSpeed()` 没有
- 两者返回值在正常情况下完全相同

### 问题 46：线程安全
- `SpeedCalculator` 是普通 `class`，不是 `actor`，无锁保护
- `samples` 是普通 `private var` 数组
- `MP4DownloadTask` 中：`addSample()` 在 URLSession progress 回调（后台线程）调用，`reset()` 在 `pause()`/`cancel()` async 方法中调用，存在并发风险
- `M3U8DownloadTask` 中：`updateProgress()` 是 async 方法，在 `withThrowingTaskGroup` 子任务中被调用，同样存在竞争风险

### 引用关系
| 文件 | 引用方式 |
|------|----------|
| `MP4DownloadHandler.swift` | 实例化并调用 `addSample`/`calculateSpeed`/`calculateRemainingTime`/`reset` |
| `M3U8DownloadHandler.swift` | 实例化并调用 `addSample`/`calculateSpeed`/`calculateRemainingTime` |
| `DownloadProgress.swift` | 调用静态方法 `formatSpeed()`/`formatTime()` |
| `SpeedCalculatorTests.swift` | 完整单元测试覆盖 |

## 修复方案

### 修改文件：`SpeedCalculator.swift`

**问题 45 修复 — 消除重复逻辑：**
- 将 `calculateAverageSpeed()` 改为直接调用 `calculateSpeed()`（两者逻辑完全相同，`calculateSpeed()` 包含更完善的负值保护）
- 保持 `calculateAverageSpeed()` 方法签名不变，避免破坏外部调用

**问题 46 修复 — 添加线程安全保护：**
- 将 `class SpeedCalculator` 改为 `final class SpeedCalculator`（防止子类化带来的额外并发风险）
- 添加 `private let lock = NSLock()` 私有锁
- 在 `addSample()`、`calculateSpeed()`、`calculateAverageSpeed()`、`calculateRemainingTime()`、`reset()` 所有方法中使用 `lock.lock()` / `lock.unlock()` 保护 `samples`、`lastBytes`、`lastTimestamp` 的读写
- 使用 `defer { lock.unlock() }` 确保异常时也能释放锁

### 修改文件：`SpeedCalculatorTests.swift`

- 新增线程安全测试：在多个并发 Task 中同时调用 `addSample` 和 `calculateSpeed`，验证不崩溃且结果一致

### 修改文件：`缺陷修复优先级排序.md`

- 将问题 45 和 46 标记为 ✅ 已修复，添加修复日期和修复说明

## 验证步骤

1. 搜索项目中所有 `calculateAverageSpeed` 调用，确认方法签名未变
2. 搜索项目中所有 `SpeedCalculator` 实例化，确认 `final class` 不影响外部使用
3. 确认 `MP4DownloadHandler.swift` 和 `M3U8DownloadHandler.swift` 无需修改（方法签名不变）
4. 编译项目确认无编译错误
