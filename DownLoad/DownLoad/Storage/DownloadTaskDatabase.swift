import Foundation
import SQLite3

public struct DownloadTaskRecord: Codable {
    public let id: UUID
    public let url: String
    public let fileName: String
    public let state: String
    public let progress: Float
}

public class DownloadTaskDatabase {
    private var db: OpaquePointer?

    public init() {
        let dbPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DownloadTasks.sqlite3").path

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("Unable to open database.")
        } else {
            let createTable =
            """
            CREATE TABLE IF NOT EXISTS tasks (
              id TEXT PRIMARY KEY,
              url TEXT,
              fileName TEXT,
              state TEXT,
              progress FLOAT
            );
            """
            if sqlite3_exec(db, createTable, nil, nil, nil) != SQLITE_OK {
                print("Unable to create tasks table.")
            }
        }
    }

    public func saveRecord(_ record: DownloadTaskRecord) {
        let insert = "INSERT OR REPLACE INTO tasks (id,url,fileName,state,progress) VALUES (?,?,?,?,?)"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, insert, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, record.id.uuidString, -1, nil)
            sqlite3_bind_text(stmt, 2, record.url, -1, nil)
            sqlite3_bind_text(stmt, 3, record.fileName, -1, nil)
            sqlite3_bind_text(stmt, 4, record.state, -1, nil)
            sqlite3_bind_double(stmt, 5, Double(record.progress))
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    public func loadAllRecords() -> [DownloadTaskRecord] {
        var records: [DownloadTaskRecord] = []
        let query = "SELECT id,url,fileName,state,progress FROM tasks"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) ?? UUID()
                let url = String(cString: sqlite3_column_text(stmt, 1))
                let fileName = String(cString: sqlite3_column_text(stmt, 2))
                let state = String(cString: sqlite3_column_text(stmt, 3))
                let progress = Float(sqlite3_column_double(stmt, 4))
                let record = DownloadTaskRecord(id: id, url: url, fileName: fileName, state: state, progress: progress)
                records.append(record)
            }
        }
        sqlite3_finalize(stmt)
        return records
    }
}
