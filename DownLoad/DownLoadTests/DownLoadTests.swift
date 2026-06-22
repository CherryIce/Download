//
//  DownLoadTests.swift
//  DownLoadTests
//
//  Created by hubin on 2026/4/29.
//

import Testing
import Foundation
@testable import DownLoad

struct DownLoadTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

}

@Suite("下载设置生效测试")
struct DownloadSettingsTests {

    @Test("URLSession 配置会继承蜂窝网络策略")
    func testURLSessionConfigurationUsesCellularPolicy() {
        let configuration = DownloadConfiguration(allowCellularDownload: false)
        let sessionConfiguration = configuration.makeURLSessionConfiguration()

        #expect(sessionConfiguration.allowsCellularAccess == false)
        if #available(iOS 13.0, *) {
            #expect(sessionConfiguration.allowsExpensiveNetworkAccess == false)
        }
    }

    @Test("设置页蜂窝开关会同步到网络监控器")
    func testCellularSettingAppliesToNetworkMonitor() {
        let originalValue = SettingsViewController.getAllowCellularDownload()
        let originalMonitorValue = NetworkMonitor.shared.isCellularAllowed
        defer {
            SettingsViewController.setAllowCellularDownload(originalValue)
            NetworkMonitor.shared.isCellularAllowed = originalMonitorValue
        }

        SettingsViewController.setAllowCellularDownload(false)
        SettingsViewController.applyCurrentDownloadSettings()

        #expect(NetworkMonitor.shared.isCellularAllowed == false)
    }
}

@Suite("DownloadTask 通知桥接测试")
struct DownloadTaskNotificationBridgeTests {

    @Test("任务状态和进度变化会发送对应通知")
    func testTaskStateAndProgressPostNotifications() async throws {
        let task = MockDownloadTask()
        let progress = DownloadProgress(
            taskId: task.id,
            totalBytes: 100,
            downloadedBytes: 40,
            progress: 0.4,
            speed: 10,
            remainingTime: 6
        )

        var statePayloads: [(UUID, String)] = []
        var progressPayloads: [DownloadProgress] = []

        let stateObserver = NotificationCenter.default.addObserver(
            forName: DownloadNotification.stateDidChange,
            object: nil,
            queue: nil
        ) { notification in
            guard let taskId = notification.userInfo?[DownloadNotificationKey.taskId] as? UUID,
                  let state = notification.userInfo?[DownloadNotificationKey.state] as? String else {
                return
            }
            statePayloads.append((taskId, state))
        }

        let progressObserver = NotificationCenter.default.addObserver(
            forName: DownloadNotification.progressDidUpdate,
            object: nil,
            queue: nil
        ) { notification in
            guard let payload = notification.userInfo?[DownloadNotificationKey.progress] as? DownloadProgress else {
                return
            }
            progressPayloads.append(payload)
        }

        defer {
            NotificationCenter.default.removeObserver(stateObserver)
            NotificationCenter.default.removeObserver(progressObserver)
        }

        let bridge = DownloadTaskNotificationBridge()
        let cancellable = bridge.observe(task)
        defer { cancellable.cancel() }

        task.state.send(.downloading)
        task.progress.send(progress)

        #expect(statePayloads.count == 1)
        #expect(statePayloads.first?.0 == task.id)
        #expect(statePayloads.first?.1 == DownloadState.downloading.rawValue)
        #expect(progressPayloads.count == 1)
        #expect(progressPayloads.first?.taskId == task.id)
        #expect(progressPayloads.first?.downloadedBytes == 40)
    }

    @Test("任务完成和失败会发送完成或失败通知")
    func testTerminalStatesPostCompletionAndFailureNotifications() async throws {
        let completedTask = MockDownloadTask(fileName: "done.mp4")
        let completedURL = FileManager.default.temporaryDirectory.appendingPathComponent("done.mp4")
        completedTask.completedURL = completedURL

        let failedTask = MockDownloadTask(fileName: "failed.mp4")
        let expectedError = NSError(domain: "DownloadTaskNotificationBridgeTests", code: 7)
        failedTask.lastError = expectedError

        var completedPayload: (UUID, String, URL)?
        var failedPayload: (UUID, String, NSError)?

        let completeObserver = NotificationCenter.default.addObserver(
            forName: DownloadNotification.downloadDidComplete,
            object: nil,
            queue: nil
        ) { notification in
            guard let taskId = notification.userInfo?[DownloadNotificationKey.taskId] as? UUID,
                  let fileName = notification.userInfo?[DownloadNotificationKey.fileName] as? String,
                  let fileURL = notification.userInfo?[DownloadNotificationKey.fileURL] as? URL else {
                return
            }
            completedPayload = (taskId, fileName, fileURL)
        }

        let failObserver = NotificationCenter.default.addObserver(
            forName: DownloadNotification.downloadDidFail,
            object: nil,
            queue: nil
        ) { notification in
            guard let taskId = notification.userInfo?[DownloadNotificationKey.taskId] as? UUID,
                  let fileName = notification.userInfo?[DownloadNotificationKey.fileName] as? String,
                  let error = notification.userInfo?[DownloadNotificationKey.error] as? NSError else {
                return
            }
            failedPayload = (taskId, fileName, error)
        }

        defer {
            NotificationCenter.default.removeObserver(completeObserver)
            NotificationCenter.default.removeObserver(failObserver)
        }

        let bridge = DownloadTaskNotificationBridge()
        let completedCancellable = bridge.observe(completedTask)
        let failedCancellable = bridge.observe(failedTask)
        defer {
            completedCancellable.cancel()
            failedCancellable.cancel()
        }

        completedTask.state.send(.completed)
        failedTask.state.send(.failed)

        #expect(completedPayload?.0 == completedTask.id)
        #expect(completedPayload?.1 == "done.mp4")
        #expect(completedPayload?.2 == completedURL)
        #expect(failedPayload?.0 == failedTask.id)
        #expect(failedPayload?.1 == "failed.mp4")
        #expect(failedPayload?.2.code == expectedError.code)
    }
}

@Suite("单任务下载输入助手测试")
struct SingleDownloadInputTests {

    @Test("URL 带 query 时应从路径推导真实文件名")
    func testSuggestedFileNameStripsQueryString() {
        let fileName = SingleDownloadInput.suggestedFileName(
            for: " https://cdn.example.com/videos/clip.mp4?token=abc#player "
        )

        #expect(fileName == "clip.mp4")
    }

    @Test("URL 没有扩展名时应补齐识别出的默认视频扩展")
    func testSuggestedFileNameAddsFallbackExtension() {
        let fileName = SingleDownloadInput.suggestedFileName(
            for: "https://cdn.example.com/watch/episode-01?id=42"
        )

        #expect(fileName == "episode-01.mp4")
    }
}

@Suite("批量状态推导测试")
struct BatchStateInferenceTests {

    @Test("全部子任务完成时批量状态应自动完成")
    func testAllCompletedInfersCompleted() {
        let state = BatchDownloadManager.inferredState(
            taskStates: [.completed, .completed],
            failedItemCount: 0,
            persistedState: .downloading
        )

        #expect(state == .completed)
    }

    @Test("部分子任务失败时批量状态应为部分失败")
    func testMixedFailureInfersPartiallyFailed() {
        let state = BatchDownloadManager.inferredState(
            taskStates: [.completed, .failed],
            failedItemCount: 0,
            persistedState: .downloading
        )

        #expect(state == .partiallyFailed)
    }

    @Test("用户取消状态应被保留")
    func testCancelledStateIsPreserved() {
        let state = BatchDownloadManager.inferredState(
            taskStates: [.completed, .failed],
            failedItemCount: 0,
            persistedState: .cancelled
        )

        #expect(state == .cancelled)
    }
}

@Suite("已完成详情动作测试")
struct CompletedFileDetailActionTests {

    @Test("只有删除文件动作应显示为破坏性样式")
    func testOnlyDeleteActionIsDestructive() {
        #expect(CompletedFileDetailAction.shareFile.isDestructive == false)
        #expect(CompletedFileDetailAction.deleteFile.isDestructive == true)
    }
}

@Suite("批量 URL 输入解析测试")
struct BatchURLInputParserTests {

    @Test("批量粘贴应标记非法 URL 并识别重复项")
    func testParserMarksInvalidAndDuplicateRows() {
        let rows = BatchURLInputParser.parse("""
        https://cdn.example.com/a.mp4
        not a url
        https://cdn.example.com/a.mp4
        https://cdn.example.com/b.m3u8?token=1
        """)

        #expect(rows.count == 4)
        #expect(rows[0].canCreateTask == true)
        #expect(rows[1].canCreateTask == false)
        #expect(rows[1].message == "URL 无效")
        #expect(rows[2].canCreateTask == false)
        #expect(rows[2].message == "重复 URL")
        #expect(rows[3].fileName == "b.mp4")
    }
}

@Suite("批量失败项单独重试测试")
struct BatchFailedItemSingleRetryTests {

    @Test("编辑失败项 URL 后应规范化并推导新的文件名")
    func testRetryInputNormalizesEditedURLAndSuggestsFileName() {
        let failedItemId = UUID()
        let input = BatchFailedItemRetryInput(
            failedItemId: failedItemId,
            rawURL: " https://cdn.example.com/fixed/episode.m3u8?token=abc "
        )

        #expect(input?.failedItemId == failedItemId)
        #expect(input?.url == "https://cdn.example.com/fixed/episode.m3u8?token=abc")
        #expect(input?.fileName == "episode.mp4")
    }

    @Test("单独重试成功时只移除被重试的失败项")
    func testSingleRetrySuccessRemovesOnlyTargetFailedItem() {
        let target = makeFailedItem(fileName: "bad-one.mp4")
        let untouched = makeFailedItem(fileName: "bad-two.mp4")

        let updatedItems = BatchDownloadManager.failedItemsAfterSingleRetry(
            [target, untouched],
            failedItemId: target.id,
            retryFailure: nil
        )

        #expect(updatedItems?.count == 1)
        #expect(updatedItems?.first?.id == untouched.id)
    }

    @Test("单独重试再次失败时只替换被重试失败项的 URL 和错误")
    func testSingleRetryFailureReplacesOnlyTargetFailedItem() {
        let target = makeFailedItem(fileName: "bad-one.mp4")
        let untouched = makeFailedItem(fileName: "bad-two.mp4")
        let retryFailure = BatchDownloadManager.BatchFailedItem(
            id: target.id,
            url: "https://cdn.example.com/fixed.mp4",
            fileName: "fixed.mp4",
            errorDescription: "仍然失败",
            failedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let updatedItems = BatchDownloadManager.failedItemsAfterSingleRetry(
            [target, untouched],
            failedItemId: target.id,
            retryFailure: retryFailure
        )

        #expect(updatedItems?.count == 2)
        #expect(updatedItems?.first?.id == target.id)
        #expect(updatedItems?.first?.url == "https://cdn.example.com/fixed.mp4")
        #expect(updatedItems?.first?.errorDescription == "仍然失败")
        #expect(updatedItems?.last?.id == untouched.id)
    }

    private func makeFailedItem(fileName: String) -> BatchDownloadManager.BatchFailedItem {
        BatchDownloadManager.BatchFailedItem(
            id: UUID(),
            url: "https://cdn.example.com/\(fileName)",
            fileName: fileName,
            errorDescription: "创建失败",
            failedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }
}
