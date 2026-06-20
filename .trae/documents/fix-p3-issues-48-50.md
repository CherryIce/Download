# P3 问题 48-50 修复计划

## 摘要

修复 `FileStorageManager.createDirectoryIfNeeded` 错误静默吞掉（#48）、数据库未开启 WAL 模式且无事务保护（#49）、数据库迁移缺乏幂等性保护（#50）三个 P3 级别缺陷。

## 当前状态分析

### 问题 48: `createDirectoryIfNeeded` 失败被静默吞掉
- `FileStorageManager.swift` 第152-161行：`private func createDirectoryIfNeeded(at url: URL)` 无 `throws`，catch 块仅 `AppLogger.error`
- 5 个目录访问方法（`downloadsDirectory`/`inProgressDirectory`/`completedDirectory`/`cacheDirectory`/`createTaskDirectory`）和 `moveFile` 均调用此方法但无法感知失败
- `StorageError.directoryCreationFailed(String)` 已定义但从未使用

### 问题 49: 数据库未开启 WAL 模式，无事务保护
- `DownloadTaskDatabase.swift` 第52-65行：`sqlite3_open` 后无 `PRAGMA journal_mode=WAL`
- `createTables()`（73-99行）、`migrateIfNeeded()`（101-111行）、`migrateV1ToV2()`（138-155行）均无事务包裹
- 多步操作中间失败会导致 schema 不一致

### 问题 50: 数据库迁移缺乏幂等性保护
- `migrateV1ToV2()`（138-155行）：6 条 `ALTER TABLE ADD COLUMN` 在列已存在时报错
- `migrateV2ToV3()`（157-160行）：同样问题
- 版本号更新与迁移非原子，崩溃后重试会因列已存在而失败

## 修改方案

### 实施顺序：问题 50 → 问题 49 → 问题 48

---

### 问题 50：数据库迁移幂等性保护

**文件**: `DownLoad/DownLoad/Storage/DownloadTaskDatabase.swift`

#### 1. 添加 `columnExists` 辅助方法（在 `exec(_:)` 方法之后）

```swift
private func columnExists(_ columnName: String, in table: String) -> Bool {
    let sql = "PRAGMA table_info(\(table))"
    var stmt: OpaquePointer?
    var exists = false
    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1) {
                if String(cString: name) == columnName {
                    exists = true
                    break
                }
            }
        }
    }
    sqlite3_finalize(stmt)
    return exists
}
```

#### 2. 改造 `migrateV1ToV2()` 为幂等（第138-155行）

每条 ALTER 前先检查列是否存在，不存在才执行：

```swift
private func migrateV1ToV2() throws {
    let migrations: [(column: String, sql: String)] = [
        ("totalSize",      "ALTER TABLE tasks ADD COLUMN totalSize INTEGER;"),
        ("format",         "ALTER TABLE tasks ADD COLUMN format TEXT NOT NULL DEFAULT 'mp4';"),
        ("resumeData",     "ALTER TABLE tasks ADD COLUMN resumeData BLOB;"),
        ("downloadedSize", "ALTER TABLE tasks ADD COLUMN downloadedSize INTEGER NOT NULL DEFAULT 0;"),
        ("createdAt",      "ALTER TABLE tasks ADD COLUMN createdAt REAL NOT NULL DEFAULT 0;"),
        ("completedAt",    "ALTER TABLE tasks ADD COLUMN completedAt REAL;")
    ]
    for migration in migrations {
        if !columnExists(migration.column, in: "tasks") {
            try exec(migration.sql)
        }
    }
}
```

#### 3. 改造 `migrateV2ToV3()` 为幂等（第157-160行）

```swift
private func migrateV2ToV3() throws {
    if !columnExists("m3u8ResumeData", in: "tasks") {
        try exec("ALTER TABLE tasks ADD COLUMN m3u8ResumeData TEXT;")
    }
}
```

---

### 问题 49：WAL 模式 + 事务保护

**文件**: `DownLoad/DownLoad/Storage/DownloadTaskDatabase.swift`

#### 1. 添加事务辅助方法（在 `exec(_:)` 方法之后）

```swift
private func beginTransaction() throws {
    try exec("BEGIN TRANSACTION;")
}

private func commit() throws {
    try exec("COMMIT;")
}

private func rollback() {
    try? exec("ROLLBACK;")
}
```

#### 2. 在 `init()` 中开启 WAL 模式（第57-65行，`sqlite3_open` 成功后、`createTables()` 之前）

```swift
try exec("PRAGMA journal_mode=WAL;")
try exec("PRAGMA busy_timeout=5000;")
```

#### 3. 为 `createTables()` 添加事务包裹（第73-99行）

```swift
private func createTables() throws {
    try beginTransaction()
    do {
        try exec(createTableSQL)
        try exec(createVersionTableSQL)
        try commit()
    } catch {
        rollback()
        throw error
    }
}
```

#### 4. 为 `migrateIfNeeded()` 添加事务包裹（第101-111行）

将迁移和版本更新包裹在同一事务中：

```swift
private func migrateIfNeeded() throws {
    let version = try currentVersion()
    if version < currentSchemaVersion {
        try beginTransaction()
        do {
            if version < 2 {
                try migrateV1ToV2()
                try setVersion(2)
            }
            if version < 3 {
                try migrateV2ToV3()
                try setVersion(3)
            }
            try commit()
        } catch {
            rollback()
            throw error
        }
    }
}
```

---

### 问题 48：`createDirectoryIfNeeded` 改为 throws

**文件**: `DownLoad/DownLoad/Storage/FileStorageManager.swift`

#### 1. 修改 `createDirectoryIfNeeded` 签名（第152-161行）

```swift
private func createDirectoryIfNeeded(at url: URL) throws {
    if !fileManager.fileExists(atPath: url.path) {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            AppLogger.debug("Directory created at \(url.path)")
        } catch {
            throw StorageError.directoryCreationFailed(url.path)
        }
    }
}
```

#### 2. 5 个目录方法添加 `throws`

- `downloadsDirectory()` → `func downloadsDirectory() throws -> URL`
- `inProgressDirectory()` → `func inProgressDirectory() throws -> URL`
- `completedDirectory()` → `func completedDirectory() throws -> URL`
- `cacheDirectory()` → `func cacheDirectory() throws -> URL`
- `createTaskDirectory(taskId:)` → `func createTaskDirectory(taskId: UUID) throws -> URL`

#### 3. `moveFile` 中添加 `try`（第86行）

`moveFile` 已经是 `throws`，只需将 `createDirectoryIfNeeded` 调用改为 `try`。

#### 4. 缓存管理方法适配（`getCacheSize`/`cleanExpiredCache`/`enforceCacheSizeLimit`/`enumerateCompletedFiles`/`completedFileCount`）

这些方法内部用 `try?` 包裹目录调用，失败时安全降级（返回 0 或空结果）。

#### 5. 调用方连锁修改

| 文件 | 处理策略 |
|------|---------|
| `MP4DownloadHandler.swift` | 已在 throws 上下文中的 5 处调用添加 `try` |
| `M3U8DownloadHandler.swift` | 已在 throws 上下文中的 4 处调用添加 `try`；`stateFileURL` 计算属性改为方法 |
| `VideoDownloadEngine.swift` | 2 处调用用 `try?` + guard 安全处理 |

## 涉及文件汇总

| 文件 | 问题 | 修改类型 |
|------|------|---------|
| `Storage/DownloadTaskDatabase.swift` | 49, 50 | 添加 WAL/事务/幂等方法 |
| `Storage/FileStorageManager.swift` | 48 | throws 传播 + 缓存方法适配 |
| `Handlers/MP4DownloadHandler.swift` | 48 | 调用点添加 try |
| `Handlers/M3U8DownloadHandler.swift` | 48 | 调用点添加 try + stateFileURL 改方法 |
| `Core/VideoDownloadEngine.swift` | 48 | 调用点适配 |

## 验证步骤

1. 编译项目，确认无编译错误
2. 搜索 `createDirectoryIfNeeded` 确认所有调用点已正确处理 throws
3. 搜索 `BEGIN TRANSACTION`/`COMMIT`/`ROLLBACK` 确认事务已添加
4. 搜索 `columnExists` 确认幂等检查已就位
5. 搜索 `PRAGMA journal_mode=WAL` 确认 WAL 已开启
6. 更新 `缺陷修复优先级排序.md` 中问题 48-50 的状态为 ✅ 已修复
