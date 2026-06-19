# P2 缺陷修复计划

> **目标:** 修复 `缺陷修复优先级排序.md` 中 P2 剩余未修复的两项缺陷：
> - **#5** NetworkClient 断点续传空壳
> - **#6** 数据库字段缺失与操作不全

**架构:** 基于现有 Swift 下载框架，修复 NetworkClient 的 resumeData 处理逻辑，并扩展数据库层以支持完整的任务持久化。

**技术栈:** Swift, SQLite3, Combine, URLSession

---

## 当前状态分析

### 已修复（P1 + P2 #4）
- 并发控制、速度计算、NetworkClient 进度回调、MP4 断点续传已修复

### 待修复（P2 剩余）

#### 缺陷 #5: NetworkClient 断点续传空壳
- **文件:** `Network/NetworkClient.swift`
- **问题:** `downloadFileWithResume` 方法返回 `(URL, Data?)`，但 `Data?` 语义混乱。成功时返回 `nil` 是合理的，但**失败时 resumeData 可能因回调时序问题丢失**。此外，该方法在项目中无调用方，实际使用的是 `downloadFileWithResumeCancellable`。但为保持 API 完整性，仍需修复此方法，使其在失败时正确传递 resumeData。
- **根因:** `resumeDataHandler` 与 `completionHandler` 的回调时序不确定，continuation 可能在 resumeData 捕获前就已 resume。

#### 缺陷 #6: 数据库字段缺失与操作不全
- **文件:** `Storage/DownloadTaskDatabase.swift`
- **问题:**
  1. `DownloadTaskRecord` 仅含 `id, url, fileName, state, progress`，缺少 `totalSize, format, resumeData, downloadedSize, createdAt, completedAt`
  2. 无删除方法、无条件查询方法
  3. 错误处理仅用 `print`，未抛出错误
  4. 无表结构迁移机制，旧用户升级后数据丢失或结构不兼容
- **影响:** 应用重启后任务状态无法完整恢复，断点续传数据丢失，无法清理已完成记录。

---

## 修改文件清单

| 文件路径 | 操作 | 说明 |
|---------|------|------|
| `DownLoad/DownLoad/Network/NetworkError.swift` | 修改 | 新增 `resumeError` case |
| `DownLoad/DownLoad/Storage/StorageError.swift` | 修改 | 新增数据库相关错误 case |
| `DownLoad/DownLoad/Storage/DownloadTaskDatabase.swift` | 修改 | 扩展 Record、迁移策略、CRUD、错误抛出 |
| `DownLoad/DownLoad/Network/NetworkClient.swift` | 修改 | 修复 `downloadFileWithResume` resumeData 处理 |

---

## Task 1: 扩展错误类型

### Step 1.1: 修改 `NetworkError.swift`，新增 `resumeError`

**文件:** `DownLoad/DownLoad/Network/NetworkError.swift`

在现有 enum 中新增 case：

```swift
case resumeError(underlying: Error, resumeData: Data?)
```

在 `errorDescription` 中新增分支：

```swift
case .resumeError(let underlying, _):
    return "Download failed with resumable data: \(underlying.localizedDescription)"
```

新增计算属性用于提取 resumeData：

```swift
var resumeData: Data? {
    if case .resumeError(_, let data) = self { return data }
    return nil
}
```

### Step 1.2: 修改 `StorageError.swift`，新增数据库错误

**文件:** `DownLoad/DownLoad/Storage/StorageError.swift`

新增 cases：

```swift
case databaseOpenFailed(String)
case databaseQueryFailed(String)
case databaseMigrationFailed(String)
case recordNotFound(UUID)
```

新增对应 `errorDescription` 分支。

---

## Task 2: 重写 `DownloadTaskDatabase.swift`

### Step 2.1: 扩展 `DownloadTaskRecord` 结构体

新增字段：
- `totalSize: Int64?`
- `format: String`
- `resumeData: Data?`
- `downloadedSize: Int64`
- `createdAt: Date`
- `completedAt: Date?`

### Step 2.2: 实现数据库版本管理与迁移

- 新增 `schema_version` 表用于版本跟踪
- 当前版本设为 `2`
- `migrateV1ToV2()` 使用 `ALTER TABLE ADD COLUMN` 添加新列
- 初始化时自动检测并执行迁移

### Step 2.3: 重写所有 CRUD 方法（全部抛出错误）

- `init()` 改为 `throws`
- `saveRecord(_:)` 改为 `throws`
- `loadAllRecords()` 改为 `throws`
- 新增 `loadRecords(byState:)` 按状态查询
- 新增 `deleteRecord(byId:)` 按 ID 删除
- 新增 `deleteRecords(byState:)` 按状态批量删除
- 新增 `deleteAllRecords()` 清空所有记录

### Step 2.4: 添加 `DownloadItem` 转换扩展

在 `DownloadTaskDatabase.swift` 中添加：

```swift
extension DownloadTaskRecord {
    init(from item: DownloadItem) { ... }
    func toDownloadItem() -> DownloadItem { ... }
}
```

---

## Task 3: 修复 `NetworkClient.swift` 的 `downloadFileWithResume`

### Step 3.1: 修改方法签名与实现

将返回类型从 `(URL, Data?)` 改为 `URL`，失败时通过 `NetworkError.resumeError` 传递 resumeData。

关键修改点：
- 保留 `resumeData` 参数的使用逻辑（已正确）
- 在 `completionHandler` 的 `.failure` 分支中，将 `savedResumeData` 包装到 `NetworkError.resumeError` 中抛出
- 确保 `resumeDataHandler` 在 `completionHandler` 之前被调用（利用闭包捕获顺序保证）

---

## Task 4: 验证

### 4.1 编译验证
- 修复后执行 `xcodebuild` 或 Xcode 编译，确保无编译错误

### 4.2 单元测试（如测试文件存在）
- 运行现有 `DownLoadTests` 确保无回归
- 新增/验证数据库 CRUD 测试

### 4.3 更新 `缺陷修复优先级排序.md`
- 为 #5、#6 添加修复记录（修复日期、修复内容、验证结果）

---

## 假设与决策

1. **数据库迁移策略:** 使用 SQLite `ALTER TABLE ADD COLUMN` 进行增量迁移，不删除旧数据。若 ALTER TABLE 失败（极端情况），接受重新创建表（数据丢失）作为降级方案。
2. **NetworkClient `downloadFileWithResume` 的调用方:** 当前无直接调用方，修复目的是保持 API 语义正确性和完整性。未来如有调用方可直接使用。
3. **`totalSize` 为 0 的处理:** 数据库中 `totalSize` 用 `INTEGER` 存储，Swift 端用 `Int64?`。查询时若值为 0 且语义上应表示 `nil`，在 `toDownloadItem()` 中处理为 `nil`（因为下载任务创建时可能未知总大小）。
4. **错误处理统一:** 数据库层所有错误统一抛出 `StorageError`，不再使用 `print`。
