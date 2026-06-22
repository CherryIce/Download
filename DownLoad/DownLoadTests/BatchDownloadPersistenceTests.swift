//
//  BatchDownloadPersistenceTests.swift
//  DownLoadTests
//
//  Created by Codex on 2026/6/22.
//

import Foundation
import Testing
@testable import DownLoad

@Suite("批量任务持久化测试")
struct BatchDownloadPersistenceTests {

    @Test("批量任务记录会持久化 taskIds 和创建失败项")
    func testBatchRecordRoundTripsTaskIdsAndFailedItems() throws {
        let database = try DownloadTaskDatabase()
        try database.deleteAllBatchRecords()
        defer { try? database.deleteAllBatchRecords() }

        let batchId = UUID()
        let taskIds = [UUID(), UUID()]
        let failedItem = BatchDownloadFailedItemRecord(
            id: UUID(),
            url: "https://example.com/missing.m3u8",
            fileName: "missing.m3u8",
            errorDescription: "404 Not Found",
            failedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )

        let record = BatchDownloadRecord(
            id: batchId,
            name: "恢复验证批量任务",
            createdAt: Date(timeIntervalSince1970: 1_780_000_100),
            state: BatchDownloadManager.BatchState.partiallyFailed.rawValue,
            taskIds: taskIds,
            failedItems: [failedItem]
        )

        try database.saveBatchRecord(record)

        let records = try database.loadAllBatchRecords()
        let restored = try #require(records.first { $0.id == batchId })

        #expect(restored.id == batchId)
        #expect(restored.name == "恢复验证批量任务")
        #expect(restored.state == BatchDownloadManager.BatchState.partiallyFailed.rawValue)
        #expect(restored.taskIds == taskIds)
        #expect(restored.failedItems.count == 1)
        #expect(restored.failedItems.first?.url == failedItem.url)
        #expect(restored.failedItems.first?.fileName == failedItem.fileName)
        #expect(restored.failedItems.first?.errorDescription == failedItem.errorDescription)
        #expect(restored.failedItems.first?.failedAt == failedItem.failedAt)
    }
}
