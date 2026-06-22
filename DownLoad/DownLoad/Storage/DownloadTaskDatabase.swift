import Foundation
import SQLite3

public struct DownloadTaskRecord: Codable {
    public let id: UUID
    public let url: String
    public let fileName: String
    public let state: String
    public let progress: Float
    public let totalSize: Int64?
    public let format: String
    public let resumeData: Data?
    public let downloadedSize: Int64
    public let createdAt: Date
    public let completedAt: Date?
    public let m3u8ResumeData: String?  // 新增：存储 M3U8 状态文件路径

    public init(
        id: UUID,
        url: String,
        fileName: String,
        state: String,
        progress: Float,
        totalSize: Int64? = nil,
        format: String = "mp4",
        resumeData: Data? = nil,
        downloadedSize: Int64 = 0,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        m3u8ResumeData: String? = nil  // 新增
    ) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.state = state
        self.progress = progress
        self.totalSize = totalSize
        self.format = format
        self.resumeData = resumeData
        self.downloadedSize = downloadedSize
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.m3u8ResumeData = m3u8ResumeData
    }
}

public struct BatchDownloadFailedItemRecord: Codable, Equatable {
    public let id: UUID
    public let url: String
    public let fileName: String
    public let errorDescription: String
    public let failedAt: Date

    public init(
        id: UUID,
        url: String,
        fileName: String,
        errorDescription: String,
        failedAt: Date
    ) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.errorDescription = errorDescription
        self.failedAt = failedAt
    }
}

public struct BatchDownloadRecord: Codable, Equatable {
    public let id: UUID
    public let name: String
    public let createdAt: Date
    public let state: String
    public let taskIds: [UUID]
    public let failedItems: [BatchDownloadFailedItemRecord]

    public init(
        id: UUID,
        name: String,
        createdAt: Date,
        state: String,
        taskIds: [UUID],
        failedItems: [BatchDownloadFailedItemRecord]
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.state = state
        self.taskIds = taskIds
        self.failedItems = failedItems
    }
}

public class DownloadTaskDatabase {
    private var db: OpaquePointer?
    private let dbPath: String
    private let currentSchemaVersion = 4

    public init() throws {
        let dbURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DownloadTasks.sqlite3")
        self.dbPath = dbURL.path

        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            let msgPtr = sqlite3_errmsg(db)
            let message = msgPtr != nil ? String(cString: msgPtr!) : "Unknown error"
            throw StorageError.databaseOpenFailed(message)
        }

        // 开启 WAL 模式，提升并发读写性能
        try exec("PRAGMA journal_mode=WAL;")
        // 设置 busy timeout，避免并发时立即失败
        try exec("PRAGMA busy_timeout=5000;")

        try createTables()
        try migrateIfNeeded()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Schema & Migration

    private func createTables() throws {
        try beginTransaction()
        do {
            let createTable = """
            CREATE TABLE IF NOT EXISTS tasks (
                id TEXT PRIMARY KEY,
                url TEXT NOT NULL,
                fileName TEXT NOT NULL,
                state TEXT NOT NULL,
                progress REAL NOT NULL,
                totalSize INTEGER,
                format TEXT NOT NULL DEFAULT 'mp4',
                resumeData BLOB,
                downloadedSize INTEGER NOT NULL DEFAULT 0,
                createdAt REAL NOT NULL,
                completedAt REAL,
                m3u8ResumeData TEXT  -- 新增
            );
            """

            let createVersionTable = """
            CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER PRIMARY KEY
            );
            """

            let createBatchTable = """
            CREATE TABLE IF NOT EXISTS batch_downloads (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                createdAt REAL NOT NULL,
                state TEXT NOT NULL,
                taskIds TEXT NOT NULL
            );
            """

            let createBatchFailedItemsTable = """
            CREATE TABLE IF NOT EXISTS batch_failed_items (
                id TEXT PRIMARY KEY,
                batchId TEXT NOT NULL,
                url TEXT NOT NULL,
                fileName TEXT NOT NULL,
                errorDescription TEXT NOT NULL,
                failedAt REAL NOT NULL
            );
            """

            try exec(createTable)
            try exec(createVersionTable)
            try exec(createBatchTable)
            try exec(createBatchFailedItemsTable)
            try commit()
        } catch {
            rollback()
            throw error
        }
    }

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
                if version < 4 {
                    try migrateV3ToV4()
                    try setVersion(4)
                }
                try commit()
            } catch {
                rollback()
                throw error
            }
        }
    }

    private func currentVersion() throws -> Int {
        let query = "SELECT version FROM schema_version LIMIT 1"
        var stmt: OpaquePointer?
        var version = 1

        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                version = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return version
    }

    private func setVersion(_ version: Int) throws {
        let sql = "INSERT OR REPLACE INTO schema_version (version) VALUES (?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.databaseMigrationFailed("Failed to set version")
        }
        sqlite3_bind_int(stmt, 1, Int32(version))
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

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

    private func migrateV2ToV3() throws {
        if !columnExists("m3u8ResumeData", in: "tasks") {
            try exec("ALTER TABLE tasks ADD COLUMN m3u8ResumeData TEXT;")
        }
    }

    private func migrateV3ToV4() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS batch_downloads (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            createdAt REAL NOT NULL,
            state TEXT NOT NULL,
            taskIds TEXT NOT NULL
        );
        """)

        try exec("""
        CREATE TABLE IF NOT EXISTS batch_failed_items (
            id TEXT PRIMARY KEY,
            batchId TEXT NOT NULL,
            url TEXT NOT NULL,
            fileName TEXT NOT NULL,
            errorDescription TEXT NOT NULL,
            failedAt REAL NOT NULL
        );
        """)
    }

    private func exec(_ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let msgPtr = sqlite3_errmsg(db)
            let message = msgPtr != nil ? String(cString: msgPtr!) : "Unknown error"
            throw StorageError.databaseQueryFailed(message)
        }
    }

    /// 检查指定表中是否已存在指定列（用于迁移幂等性保护）
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

    // MARK: - Transaction Helpers

    private func beginTransaction() throws {
        try exec("BEGIN TRANSACTION;")
    }

    private func commit() throws {
        try exec("COMMIT;")
    }

    private func rollback() {
        try? exec("ROLLBACK;")
    }

    // MARK: - Save

    public func saveRecord(_ record: DownloadTaskRecord) throws {
        let sql = """
        INSERT OR REPLACE INTO tasks (
            id, url, fileName, state, progress,
            totalSize, format, resumeData, downloadedSize, createdAt, completedAt, m3u8ResumeData
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msgPtr = sqlite3_errmsg(db)
            let message = msgPtr != nil ? String(cString: msgPtr!) : "Unknown error"
            throw StorageError.databaseQueryFailed("Prepare failed: \(message)")
        }

        sqlite3_bind_text(stmt, 1, record.id.uuidString, -1, nil)
        sqlite3_bind_text(stmt, 2, record.url, -1, nil)
        sqlite3_bind_text(stmt, 3, record.fileName, -1, nil)
        sqlite3_bind_text(stmt, 4, record.state, -1, nil)
        sqlite3_bind_double(stmt, 5, Double(record.progress))
        sqlite3_bind_int64(stmt, 6, record.totalSize ?? 0)
        sqlite3_bind_text(stmt, 7, record.format, -1, nil)
        if let resumeData = record.resumeData {
            sqlite3_bind_blob(stmt, 8, (resumeData as NSData).bytes, Int32(resumeData.count), nil)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        sqlite3_bind_int64(stmt, 9, record.downloadedSize)
        sqlite3_bind_double(stmt, 10, record.createdAt.timeIntervalSince1970)
        if let completedAt = record.completedAt {
            sqlite3_bind_double(stmt, 11, completedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 11)
        }
        sqlite3_bind_text(stmt, 12, record.m3u8ResumeData, -1, nil)

        let result = sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        guard result == SQLITE_DONE else {
            let msgPtr = sqlite3_errmsg(db)
            let message = msgPtr != nil ? String(cString: msgPtr!) : "Unknown error"
            throw StorageError.databaseQueryFailed("Step failed: \(message)")
        }
    }

    // MARK: - Load

    public func loadAllRecords() throws -> [DownloadTaskRecord] {
        let sql = """
        SELECT id, url, fileName, state, progress,
               totalSize, format, resumeData, downloadedSize, createdAt, completedAt, m3u8ResumeData
        FROM tasks
        """
        return try queryRecords(sql: sql, stateFilter: nil)
    }

    public func loadRecords(byState state: String) throws -> [DownloadTaskRecord] {
        let sql = """
        SELECT id, url, fileName, state, progress,
               totalSize, format, resumeData, downloadedSize, createdAt, completedAt, m3u8ResumeData
        FROM tasks WHERE state = ?
        """
        return try queryRecords(sql: sql, stateFilter: state)
    }

    public func loadRecord(byId id: UUID) throws -> DownloadTaskRecord? {
        let sql = """
        SELECT id, url, fileName, state, progress,
               totalSize, format, resumeData, downloadedSize, createdAt, completedAt, m3u8ResumeData
        FROM tasks WHERE id = ?
        """
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msgPtr = sqlite3_errmsg(db)
            let message = msgPtr != nil ? String(cString: msgPtr!) : "Unknown error"
            throw StorageError.databaseQueryFailed("Prepare failed: \(message)")
        }

        sqlite3_bind_text(stmt, 1, id.uuidString, -1, nil)
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        return readTaskRecord(from: stmt)
    }

    private func queryRecords(sql: String, stateFilter: String?) throws -> [DownloadTaskRecord] {
        var records: [DownloadTaskRecord] = []
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msgPtr = sqlite3_errmsg(db)
            let message = msgPtr != nil ? String(cString: msgPtr!) : "Unknown error"
            throw StorageError.databaseQueryFailed("Prepare failed: \(message)")
        }

        if let filter = stateFilter {
            sqlite3_bind_text(stmt, 1, filter, -1, nil)
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            records.append(readTaskRecord(from: stmt))
        }

        sqlite3_finalize(stmt)
        return records
    }

    private func readTaskRecord(from stmt: OpaquePointer?) -> DownloadTaskRecord {
        let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) ?? UUID()
        let url = String(cString: sqlite3_column_text(stmt, 1))
        let fileName = String(cString: sqlite3_column_text(stmt, 2))
        let state = String(cString: sqlite3_column_text(stmt, 3))
        let progress = Float(sqlite3_column_double(stmt, 4))
        let totalSize = sqlite3_column_int64(stmt, 5)
        let format = String(cString: sqlite3_column_text(stmt, 6))

        var resumeData: Data?
        if let blob = sqlite3_column_blob(stmt, 7) {
            let length = sqlite3_column_bytes(stmt, 7)
            resumeData = Data(bytes: blob, count: Int(length))
        }

        let downloadedSize = sqlite3_column_int64(stmt, 8)
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
        var completedAt: Date?
        if sqlite3_column_type(stmt, 10) != SQLITE_NULL {
            completedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
        }
        var m3u8ResumeData: String?
        if sqlite3_column_type(stmt, 11) != SQLITE_NULL {
            m3u8ResumeData = String(cString: sqlite3_column_text(stmt, 11))
        }

        return DownloadTaskRecord(
            id: id,
            url: url,
            fileName: fileName,
            state: state,
            progress: progress,
            totalSize: totalSize > 0 ? totalSize : nil,
            format: format,
            resumeData: resumeData,
            downloadedSize: downloadedSize,
            createdAt: createdAt,
            completedAt: completedAt,
            m3u8ResumeData: m3u8ResumeData
        )
    }

    // MARK: - Delete

    public func deleteRecord(byId id: UUID) throws {
        let sql = "DELETE FROM tasks WHERE id = ?"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msgPtr = sqlite3_errmsg(db)
            let message = msgPtr != nil ? String(cString: msgPtr!) : "Unknown error"
            throw StorageError.databaseQueryFailed("Prepare failed: \(message)")
        }

        sqlite3_bind_text(stmt, 1, id.uuidString, -1, nil)
        let result = sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        guard result == SQLITE_DONE else {
            let msgPtr = sqlite3_errmsg(db)
            let message = msgPtr != nil ? String(cString: msgPtr!) : "Unknown error"
            throw StorageError.databaseQueryFailed("Delete failed: \(message)")
        }
    }

    public func deleteRecords(byState state: String) throws {
        let sql = "DELETE FROM tasks WHERE state = ?"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msgPtr = sqlite3_errmsg(db)
            let message = msgPtr != nil ? String(cString: msgPtr!) : "Unknown error"
            throw StorageError.databaseQueryFailed("Prepare failed: \(message)")
        }

        sqlite3_bind_text(stmt, 1, state, -1, nil)
        let result = sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        guard result == SQLITE_DONE else {
            let msgPtr = sqlite3_errmsg(db)
            let message = msgPtr != nil ? String(cString: msgPtr!) : "Unknown error"
            throw StorageError.databaseQueryFailed("Delete failed: \(message)")
        }
    }

    public func deleteAllRecords() throws {
        try exec("DELETE FROM tasks;")
    }

    // MARK: - Batch Save & Load

    public func saveBatchRecord(_ record: BatchDownloadRecord) throws {
        let encodedTaskIds = try encodeTaskIds(record.taskIds)

        try beginTransaction()
        do {
            let sql = """
            INSERT OR REPLACE INTO batch_downloads (
                id, name, createdAt, state, taskIds
            ) VALUES (?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                let msgPtr = sqlite3_errmsg(db)
                let message = msgPtr != nil ? String(cString: msgPtr!) : "Unknown error"
                throw StorageError.databaseQueryFailed("Prepare failed: \(message)")
            }

            sqlite3_bind_text(stmt, 1, record.id.uuidString, -1, nil)
            sqlite3_bind_text(stmt, 2, record.name, -1, nil)
            sqlite3_bind_double(stmt, 3, record.createdAt.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 4, record.state, -1, nil)
            sqlite3_bind_text(stmt, 5, encodedTaskIds, -1, nil)

            let result = sqlite3_step(stmt)
            sqlite3_finalize(stmt)

            guard result == SQLITE_DONE else {
                let msgPtr = sqlite3_errmsg(db)
                let message = msgPtr != nil ? String(cString: msgPtr!) : "Unknown error"
                throw StorageError.databaseQueryFailed("Step failed: \(message)")
            }

            try deleteFailedItems(forBatchId: record.id)
            for failedItem in record.failedItems {
                try saveFailedItem(failedItem, batchId: record.id)
            }

            try commit()
        } catch {
            rollback()
            throw error
        }
    }

    public func loadAllBatchRecords() throws -> [BatchDownloadRecord] {
        let sql = """
        SELECT id, name, createdAt, state, taskIds
        FROM batch_downloads
        ORDER BY createdAt DESC
        """
        var stmt: OpaquePointer?
        var records: [BatchDownloadRecord] = []

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msgPtr = sqlite3_errmsg(db)
            let message = msgPtr != nil ? String(cString: msgPtr!) : "Unknown error"
            throw StorageError.databaseQueryFailed("Prepare failed: \(message)")
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) ?? UUID()
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let state = String(cString: sqlite3_column_text(stmt, 3))
            let taskIdsText = String(cString: sqlite3_column_text(stmt, 4))
            let taskIds = try decodeTaskIds(taskIdsText)
            let failedItems = try loadFailedItems(forBatchId: id)

            records.append(BatchDownloadRecord(
                id: id,
                name: name,
                createdAt: createdAt,
                state: state,
                taskIds: taskIds,
                failedItems: failedItems
            ))
        }

        return records
    }

    public func deleteBatchRecord(byId id: UUID) throws {
        try beginTransaction()
        do {
            try deleteFailedItems(forBatchId: id)

            let sql = "DELETE FROM batch_downloads WHERE id = ?"
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                let msgPtr = sqlite3_errmsg(db)
                let message = msgPtr != nil ? String(cString: msgPtr!) : "Unknown error"
                throw StorageError.databaseQueryFailed("Prepare failed: \(message)")
            }

            sqlite3_bind_text(stmt, 1, id.uuidString, -1, nil)
            let result = sqlite3_step(stmt)
            sqlite3_finalize(stmt)

            guard result == SQLITE_DONE else {
                let msgPtr = sqlite3_errmsg(db)
                let message = msgPtr != nil ? String(cString: msgPtr!) : "Unknown error"
                throw StorageError.databaseQueryFailed("Delete failed: \(message)")
            }

            try commit()
        } catch {
            rollback()
            throw error
        }
    }

    public func deleteAllBatchRecords() throws {
        try beginTransaction()
        do {
            try exec("DELETE FROM batch_failed_items;")
            try exec("DELETE FROM batch_downloads;")
            try commit()
        } catch {
            rollback()
            throw error
        }
    }

    private func saveFailedItem(_ failedItem: BatchDownloadFailedItemRecord, batchId: UUID) throws {
        let sql = """
        INSERT OR REPLACE INTO batch_failed_items (
            id, batchId, url, fileName, errorDescription, failedAt
        ) VALUES (?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msgPtr = sqlite3_errmsg(db)
            let message = msgPtr != nil ? String(cString: msgPtr!) : "Unknown error"
            throw StorageError.databaseQueryFailed("Prepare failed: \(message)")
        }

        sqlite3_bind_text(stmt, 1, failedItem.id.uuidString, -1, nil)
        sqlite3_bind_text(stmt, 2, batchId.uuidString, -1, nil)
        sqlite3_bind_text(stmt, 3, failedItem.url, -1, nil)
        sqlite3_bind_text(stmt, 4, failedItem.fileName, -1, nil)
        sqlite3_bind_text(stmt, 5, failedItem.errorDescription, -1, nil)
        sqlite3_bind_double(stmt, 6, failedItem.failedAt.timeIntervalSince1970)

        let result = sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        guard result == SQLITE_DONE else {
            let msgPtr = sqlite3_errmsg(db)
            let message = msgPtr != nil ? String(cString: msgPtr!) : "Unknown error"
            throw StorageError.databaseQueryFailed("Step failed: \(message)")
        }
    }

    private func loadFailedItems(forBatchId batchId: UUID) throws -> [BatchDownloadFailedItemRecord] {
        let sql = """
        SELECT id, url, fileName, errorDescription, failedAt
        FROM batch_failed_items
        WHERE batchId = ?
        ORDER BY failedAt ASC
        """
        var stmt: OpaquePointer?
        var failedItems: [BatchDownloadFailedItemRecord] = []

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msgPtr = sqlite3_errmsg(db)
            let message = msgPtr != nil ? String(cString: msgPtr!) : "Unknown error"
            throw StorageError.databaseQueryFailed("Prepare failed: \(message)")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, batchId.uuidString, -1, nil)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) ?? UUID()
            let url = String(cString: sqlite3_column_text(stmt, 1))
            let fileName = String(cString: sqlite3_column_text(stmt, 2))
            let errorDescription = String(cString: sqlite3_column_text(stmt, 3))
            let failedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))

            failedItems.append(BatchDownloadFailedItemRecord(
                id: id,
                url: url,
                fileName: fileName,
                errorDescription: errorDescription,
                failedAt: failedAt
            ))
        }

        return failedItems
    }

    private func deleteFailedItems(forBatchId batchId: UUID) throws {
        let sql = "DELETE FROM batch_failed_items WHERE batchId = ?"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msgPtr = sqlite3_errmsg(db)
            let message = msgPtr != nil ? String(cString: msgPtr!) : "Unknown error"
            throw StorageError.databaseQueryFailed("Prepare failed: \(message)")
        }

        sqlite3_bind_text(stmt, 1, batchId.uuidString, -1, nil)
        let result = sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        guard result == SQLITE_DONE else {
            let msgPtr = sqlite3_errmsg(db)
            let message = msgPtr != nil ? String(cString: msgPtr!) : "Unknown error"
            throw StorageError.databaseQueryFailed("Delete failed: \(message)")
        }
    }

    private func encodeTaskIds(_ taskIds: [UUID]) throws -> String {
        let values = taskIds.map(\.uuidString)
        let data = try JSONEncoder().encode(values)
        guard let text = String(data: data, encoding: .utf8) else {
            throw StorageError.databaseQueryFailed("Failed to encode batch task ids")
        }
        return text
    }

    private func decodeTaskIds(_ text: String) throws -> [UUID] {
        guard let data = text.data(using: .utf8) else {
            throw StorageError.databaseQueryFailed("Failed to decode batch task ids")
        }
        let values = try JSONDecoder().decode([String].self, from: data)
        return values.compactMap(UUID.init(uuidString:))
    }
}

// MARK: - DownloadItem Conversion

extension DownloadTaskRecord {
    init(from item: DownloadItem, m3u8ResumeData: String? = nil) {
        self.init(
            id: item.id,
            url: item.url,
            fileName: item.fileName,
            state: item.state.rawValue,
            progress: item.totalSize.map { Float(item.downloadedSize) / Float($0) } ?? 0,
            totalSize: item.totalSize,
            format: item.format.rawValue,
            resumeData: item.resumeData,
            downloadedSize: item.downloadedSize,
            createdAt: item.createdAt,
            completedAt: item.completedAt,
            m3u8ResumeData: m3u8ResumeData
        )
    }

    func toDownloadItem() -> DownloadItem {
        return DownloadItem(
            id: id,
            url: url,
            format: VideoFormat(rawValue: format) ?? .mp4,
            fileName: fileName,
            totalSize: totalSize,
            downloadedSize: downloadedSize,
            state: DownloadState(rawValue: state) ?? .pending,
            createdAt: createdAt,
            completedAt: completedAt,
            resumeData: resumeData
        )
    }
}
