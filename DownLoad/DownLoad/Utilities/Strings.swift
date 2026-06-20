//
//  Strings.swift
//  DownLoad
//
//  Centralized Chinese UI strings for user-facing text.
//  Internal identifiers (rawValue, logs, notification names) remain in English.
//

import Foundation

enum Strings {

    // MARK: - Buttons
    enum Button {
        static let startDownload = "开始下载"
        static let pause         = "暂停"
        static let resume        = "恢复"
        static let cancel        = "取消"
        static let retry         = "重试"
        static let play          = "播放"
        static let confirm       = "确定"
        static let edit          = "编辑"
        static let done          = "完成"
        static let delete        = "删除"
        static let share         = "分享"
        static let preview       = "预览"
        static let detail        = "详情"
    }

    // MARK: - Navigation / Screen Titles
    enum Title {
        static let singleDownload   = "单任务下载"
        static let batchDownload    = "批量下载"
        static let completedFiles   = "已完成文件"
        static let settings         = "设置"
        static let fileDetail       = "文件详情"
        static let sortOptions      = "排序方式"
        static let failedDetails    = "失败详情"
        static let addTask          = "添加下载任务"
    }

    // MARK: - Placeholders
    enum Placeholder {
        static let urlInput              = "请输入下载链接"
        static let batchUrlInput         = "视频URL（每行一个）"
        static let searchFileName        = "搜索文件名"
    }

    // MARK: - Alerts
    enum Alert {
        static let confirmDelete         = "确认删除"
        static let confirmCancel         = "确认取消"
        static let error                 = "错误"
        static let startFailed           = "开始失败"
        static let retryFailed           = "重试失败"
        static let retryCompleted        = "重试完成（仍有失败）"
        static let retrySuccess          = "重试成功"
        static let batchPartialFailure   = "批量任务创建完成（部分失败）"
        static let playbackFailed        = "播放失败"
    }

    // MARK: - Messages
    enum Message {
        static let enterValidURL              = "请输入有效的URL"
        static let noActiveTaskToPause        = "No active task to pause"
        static let noActiveTaskToCancel       = "No active task to cancel"
        static let noActiveTaskToRetry        = "No active task to retry"
        static let taskNotFailedCannotRetry   = "Task is not in failed state, cannot retry"
        static let noCompletedFileToPlay      = "No completed file to play"
        static let deleteConfirmation(batchName: String, count: Int) -> String {
            return "确定要删除批量任务\"\(batchName)\"吗？包含 \(count) 个文件"
        }
        static let cancelConfirmation         = "确定要取消该批量下载任务吗？"
        static let deleteFileConfirmation(fileName: String) -> String {
            return "确定要删除\"\(fileName)\"吗？此操作不可恢复。"
        }
        static let retryFailedItemsHint       = "失败项可在任务详情中查看并重试"
        static let retryFailedItemsNone       = "无法找到批量任务或没有失败项"
        static let retryFailedItemsStillFail  = "所有失败项已重新添加并开始下载"
    }

    // MARK: - Empty State
    enum EmptyState {
        static let noSearchResultsTitle       = "未找到匹配的文件"
        static let noSearchResultsDesc        = "尝试使用其他关键词搜索"
        static let noCompletedFilesTitle      = "暂无已下载文件"
        static let noCompletedFilesDesc       = "下载完成的文件将显示在这里"
    }

    // MARK: - Stats / Info
    enum Stats {
        static func fileCountAndSize(count: Int, size: String) -> String {
            return "共 \(count) 个文件，占用 \(size)"
        }
        static let calculatingSize = "大小计算中..."
        static let unknown         = "未知"
    }

    // MARK: - Notifications
    enum Notification {
        static let downloadCompleteTitle = "下载完成"
        static func downloadCompleteBody(fileName: String) -> String {
            return "\(fileName) 已下载完成"
        }
        static let downloadFailedTitle = "下载失败"
        static func downloadFailedBody(fileName: String, error: String) -> String {
            return "\(fileName) 下载失败：\(error)"
        }
    }

    // MARK: - Labels
    enum Label {
        static let file = "文件"
        static let downloading = "下载中"
        static let paused = "暂停"
        static let failed = "失败"
        static let createdFailed = "创建失败"
    }

    // MARK: - Section Headers
    enum Section {
        static let fileInfo     = "文件信息"
        static let downloadInfo = "下载信息"
        static let actions      = "操作"
    }

    // MARK: - Row Titles
    enum Row {
        static let fileName        = "文件名"
        static let fileSize        = "文件大小"
        static let fileFormat      = "文件格式"
        static let sourceURL       = "来源 URL"
        static let completedAt     = "下载完成时间"
        static let createdAt       = "任务创建时间"
        static let playVideo       = "播放视频"
        static let previewFile     = "预览文件"
        static let shareFile       = "分享文件"
        static let deleteFile      = "删除文件"
    }
}
