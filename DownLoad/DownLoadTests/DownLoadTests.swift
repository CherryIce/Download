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

        #expect(statePayloads == [(task.id, DownloadState.downloading.rawValue)])
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
