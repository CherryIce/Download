//
//  CompletedFileDetailViewController.swift
//  DownLoad
//

import UIKit
import QuickLook
import AVKit

enum CompletedFileDetailAction: Int, CaseIterable {
    case playVideo = 0
    case previewFile = 1
    case shareFile = 2
    case deleteFile = 3

    var title: String {
        switch self {
        case .playVideo: return Strings.Row.playVideo
        case .previewFile: return Strings.Row.previewFile
        case .shareFile: return Strings.Row.shareFile
        case .deleteFile: return Strings.Row.deleteFile
        }
    }

    var icon: String {
        switch self {
        case .playVideo: return "play.circle"
        case .previewFile: return "eye"
        case .shareFile: return "square.and.arrow.up"
        case .deleteFile: return "trash"
        }
    }

    var isDestructive: Bool {
        return self == .deleteFile
    }
}

/// 已完成文件详情页面
class CompletedFileDetailViewController: UIViewController {

    // MARK: - Properties
    private let item: CompletedFileItem
    private let storageManager = FileStorageManager()

    // MARK: - UI Components
    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .grouped)
        tv.dataSource = self
        tv.delegate = self
        tv.translatesAutoresizingMaskIntoConstraints = false
        return tv
    }()

    // MARK: - Section Data
    private enum SectionType: Int, CaseIterable {
        case fileInfo = 0
        case downloadInfo = 1
        case actions = 2
    }

    private let fileInfoRows: [(title: String, value: String)] = [
        ("文件名", ""),
        ("文件大小", ""),
        ("文件格式", "")
    ]

    private let downloadInfoRows: [(title: String, value: String)] = [
        ("来源 URL", ""),
        ("下载完成时间", ""),
        ("任务创建时间", "")
    ]

    private let actionRows = CompletedFileDetailAction.allCases

    // MARK: - Initialization
    init(item: CompletedFileItem) {
        self.item = item
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "文件详情"
        setupUI()
    }

    private func setupUI() {
        view.backgroundColor = .systemBackground
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    // MARK: - Actions
    private func playVideo() {
        let playerVC = VideoPlayerViewController(videoURL: item.fileURL)
        playerVC.modalPresentationStyle = .fullScreen
        present(playerVC, animated: true)
    }

    private func previewFile() {
        let previewController = QLPreviewController()
        previewController.dataSource = self
        navigationController?.pushViewController(previewController, animated: true)
    }

    private func shareFile() {
        let activityVC = UIActivityViewController(
            activityItems: [item.fileURL],
            applicationActivities: nil
        )

        // iPad 适配
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }

        present(activityVC, animated: true)
    }

    private func deleteFile() {
        let alert = UIAlertController(
            title: "确认删除",
            message: "确定要删除\"\(item.fileName)\"吗？此操作不可恢复。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            guard let self = self else { return }

            do {
                try self.storageManager.deleteFile(at: self.item.fileURL)

                if self.item.hasDatabaseRecord {
                    try VideoDownloadEngine.shared.database.deleteRecord(byId: self.item.id)
                }

                NotificationCenter.default.post(
                    name: Notification.Name("CompletedFileDeleted"),
                    object: nil,
                    userInfo: ["fileName": self.item.fileName, "taskId": self.item.id]
                )

                AppLogger.info("Deleted completed file from detail: \(self.item.fileName)")
                self.navigationController?.popViewController(animated: true)
            } catch {
                AppLogger.error("Failed to delete completed file from detail: \(error)")
                self.showAlert(title: "删除失败", message: error.localizedDescription)
            }
        })
        present(alert, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - UITableViewDataSource
extension CompletedFileDetailViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return SectionType.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch SectionType(rawValue: section)! {
        case .fileInfo:
            return fileInfoRows.count
        case .downloadInfo:
            return downloadInfoRows.count
        case .actions:
            return actionRows.count
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: "DetailCell")

        switch SectionType(rawValue: indexPath.section)! {
        case .fileInfo:
            let row = fileInfoRows[indexPath.row]
            cell.textLabel?.text = row.title
            cell.selectionStyle = .none

            switch indexPath.row {
            case 0:
                cell.detailTextLabel?.text = item.fileName
                cell.detailTextLabel?.adjustsFontSizeToFitWidth = true
                cell.detailTextLabel?.minimumScaleFactor = 0.6
            case 1:
                cell.detailTextLabel?.text = item.formattedFileSize
            case 2:
                cell.detailTextLabel?.text = item.fileExtension
            default:
                break
            }

        case .downloadInfo:
            let row = downloadInfoRows[indexPath.row]
            cell.textLabel?.text = row.title
            cell.selectionStyle = .none

            switch indexPath.row {
            case 0:
                cell.detailTextLabel?.text = item.sourceURL ?? "未知"
                cell.detailTextLabel?.adjustsFontSizeToFitWidth = true
                cell.detailTextLabel?.minimumScaleFactor = 0.5
            case 1:
                cell.detailTextLabel?.text = item.formattedCompletedAt ?? "未知"
            case 2:
                if let createdAt = item.createdAt {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd HH:mm"
                    cell.detailTextLabel?.text = formatter.string(from: createdAt)
                } else {
                    cell.detailTextLabel?.text = "未知"
                }
            default:
                break
            }

        case .actions:
            let action = actionRows[indexPath.row]
            cell.textLabel?.text = action.title
            cell.imageView?.image = UIImage(systemName: action.icon)
            cell.accessoryType = .disclosureIndicator

            if action.isDestructive {
                cell.textLabel?.textColor = .systemRed
            }
        }

        return cell
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch SectionType(rawValue: section)! {
        case .fileInfo:
            return "文件信息"
        case .downloadInfo:
            return "下载信息"
        case .actions:
            return "操作"
        }
    }
}

// MARK: - UITableViewDelegate
extension CompletedFileDetailViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        guard SectionType(rawValue: indexPath.section) == .actions else { return }

        guard let action = CompletedFileDetailAction(rawValue: indexPath.row) else {
            return
        }

        switch action {
        case .playVideo:
            playVideo()
        case .previewFile:
            previewFile()
        case .shareFile:
            shareFile()
        case .deleteFile:
            deleteFile()
        }
    }
}

// MARK: - QLPreviewControllerDataSource
extension CompletedFileDetailViewController: QLPreviewControllerDataSource {
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        return 1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        return item.fileURL as QLPreviewItem
    }
}
