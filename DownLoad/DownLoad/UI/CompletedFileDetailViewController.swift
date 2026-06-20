//
//  CompletedFileDetailViewController.swift
//  DownLoad
//

import UIKit
import QuickLook

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

    private let actionRows: [(title: String, icon: String)] = [
        ("预览文件", "eye"),
        ("分享文件", "square.and.arrow.up"),
        ("删除文件", "trash")
    ]

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

            // 删除文件
            try? self.storageManager.deleteFile(at: self.item.fileURL)

            // 删除数据库记录（如果有）
            if self.item.hasDatabaseRecord {
                let engine = VideoDownloadEngine.shared
                // 通过通知让列表页刷新
                NotificationCenter.default.post(name: Notification.Name("CompletedFileDeleted"), object: nil, userInfo: ["fileName": self.item.fileName])
            }

            Logger.info("Deleted completed file from detail: \(self.item.fileName)")

            // 返回上一页
            self.navigationController?.popViewController(animated: true)
        })
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
            let row = actionRows[indexPath.row]
            cell.textLabel?.text = row.title
            cell.imageView?.image = UIImage(systemName: row.icon)
            cell.accessoryType = .disclosureIndicator

            // 删除操作红色文字
            if indexPath.row == 2 {
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

        switch indexPath.row {
        case 0:
            previewFile()
        case 1:
            shareFile()
        case 2:
            deleteFile()
        default:
            break
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
