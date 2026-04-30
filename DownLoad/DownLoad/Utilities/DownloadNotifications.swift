//
//  DownloadNotifications.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation
import UserNotifications

/// 下载通知名称
struct DownloadNotification {

    /// 下载状态变化通知
    static let stateDidChange = Notification.Name("DownloadStateDidChange")

    /// 下载进度更新通知
    static let progressDidUpdate = Notification.Name("DownloadProgressDidUpdate")

    /// 下载完成通知
    static let downloadDidComplete = Notification.Name("DownloadDidComplete")

    /// 下载失败通知
    static let downloadDidFail = Notification.Name("DownloadDidFail")

    /// 下载开始通知
    static let downloadDidStart = Notification.Name("DownloadDidStart")
}

/// 通知UserInfo键
struct DownloadNotificationKey {
    static let taskId = "taskId"
    static let state = "state"
    static let progress = "progress"
    static let error = "error"
    static let fileURL = "fileURL"
    static let fileName = "fileName"
}

/// 通知发送器
class DownloadNotifier {

    static let shared = DownloadNotifier()

    private let notificationCenter = NotificationCenter.default

    private init() {}

    /// 发送状态变化通知
    func notifyStateChange(taskId: UUID, state: DownloadState) {
        let userInfo: [String: Any] = [
            DownloadNotificationKey.taskId: taskId,
            DownloadNotificationKey.state: state.rawValue
        ]

        notificationCenter.post(
            name: DownloadNotification.stateDidChange,
            object: nil,
            userInfo: userInfo
        )

        // 根据状态发送特定通知
        switch state {
        case .downloading:
            notifyDownloadStart(taskId: taskId)
        case .completed:
            // completed通知需要fileURL，在其他地方发送
            break
        case .failed:
            // failed通知需要error，在其他地方发送
            break
        default:
            break
        }
    }

    /// 发送进度更新通知
    func notifyProgressUpdate(taskId: UUID, progress: DownloadProgress) {
        let userInfo: [String: Any] = [
            DownloadNotificationKey.taskId: taskId,
            DownloadNotificationKey.progress: progress
        ]

        notificationCenter.post(
            name: DownloadNotification.progressDidUpdate,
            object: nil,
            userInfo: userInfo
        )
    }

    /// 发送下载完成通知
    func notifyDownloadComplete(taskId: UUID, fileName: String, fileURL: URL) {
        let userInfo: [String: Any] = [
            DownloadNotificationKey.taskId: taskId,
            DownloadNotificationKey.fileName: fileName,
            DownloadNotificationKey.fileURL: fileURL
        ]

        notificationCenter.post(
            name: DownloadNotification.downloadDidComplete,
            object: nil,
            userInfo: userInfo
        )

        // 发送本地通知
        sendLocalNotification(
            title: "下载完成",
            body: "\(fileName) 已下载完成"
        )
    }

    /// 发送下载失败通知
    func notifyDownloadFail(taskId: UUID, fileName: String, error: Error) {
        let userInfo: [String: Any] = [
            DownloadNotificationKey.taskId: taskId,
            DownloadNotificationKey.fileName: fileName,
            DownloadNotificationKey.error: error
        ]

        notificationCenter.post(
            name: DownloadNotification.downloadDidFail,
            object: nil,
            userInfo: userInfo
        )

        // 发送本地通知
        sendLocalNotification(
            title: "下载失败",
            body: "\(fileName) 下载失败: \(error.localizedDescription)"
        )
    }

    /// 发送下载开始通知
    func notifyDownloadStart(taskId: UUID) {
        let userInfo: [String: Any] = [
            DownloadNotificationKey.taskId: taskId
        ]

        notificationCenter.post(
            name: DownloadNotification.downloadDidStart,
            object: nil,
            userInfo: userInfo
        )
    }

    // MARK: - Private Methods

    private func sendLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Logger.error("Failed to send local notification: \(error)")
            }
        }
    }
}
