//
//  CompletedFilesViewController.swift
//  DownLoad
//

import UIKit
import Combine
import QuickLook
import AVKit

/// 已完成文件管理页面
class CompletedFilesViewController: UIViewController {

    // MARK: - Properties
    private let storageManager = FileStorageManager()
    private var allItems: [CompletedFileItem] = []
    private var filteredItems: [CompletedFileItem] = []
    private var isSearchActive = false
    private var currentSortOption: SortOption = .completedTime
    private var cancellables = Set<AnyCancellable>()
    private var previewItemURL: URL?

    private enum SortOption: Int, CaseIterable {
        case completedTime = 0
        case fileName = 1
        case fileSize = 2

        var displayName: String {
            switch self {
            case .completedTime: return "完成时间"
            case .fileName: return "文件名"
            case .fileSize: return "文件大小"
            }
        }
    }

    /// 当前展示的数据源（搜索激活时用过滤结果，否则用全量）
    private var currentItems: [CompletedFileItem] {
        return isSearchActive ? filteredItems : allItems
    }

    // MARK: - UI Components
    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.dataSource = self
        tv.delegate = self
        tv.register(CompletedFileCell.self, forCellReuseIdentifier: CompletedFileCell.reuseIdentifier)
        tv.rowHeight = 72
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.separatorStyle = .none
        return tv
    }()

    private lazy var searchController: UISearchController = {
        let sc = UISearchController(searchResultsController: nil)
        sc.searchResultsUpdater = self
        sc.obscuresBackgroundDuringPresentation = false
        sc.searchBar.placeholder = "搜索文件名"
        sc.searchBar.returnKeyType = .done
        return sc
    }()

    private lazy var emptyStateView: EmptyStateView = {
        let view = EmptyStateView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var statsLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "已完成文件"
        setupUI()
        setupNotifications()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadCompletedFiles()
    }

    // MARK: - Setup
    private func setupUI() {
        view.backgroundColor = .systemBackground

        // 导航栏搜索控制器
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.up.arrow.down"),
            style: .plain,
            target: self,
            action: #selector(showSortOptions)
        )

        // 子视图
        view.addSubview(tableView)
        view.addSubview(emptyStateView)
        view.addSubview(statsLabel)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -30),

            statsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statsLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statsLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),

            emptyStateView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -30)
        ])
    }

    private func setupNotifications() {
        // 订阅下载完成通知，自动刷新列表
        NotificationCenter.default.publisher(for: DownloadNotification.downloadDidComplete)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadCompletedFiles()
            }
            .store(in: &cancellables)

        // 订阅文件删除通知（从详情页删除时）
        NotificationCenter.default.publisher(for: Notification.Name("CompletedFileDeleted"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadCompletedFiles()
            }
            .store(in: &cancellables)
    }

    // MARK: - Data Loading
    private func loadCompletedFiles() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // 1. 枚举文件系统
            let fileURLs = self.storageManager.enumerateCompletedFiles()

            // 2. 加载数据库中 completed 状态的记录
            var dbRecords: [String: DownloadTaskRecord] = [:]
            if let records = try? VideoDownloadEngine.shared.database.loadRecords(byState: "completed") {
                for record in records {
                    dbRecords[record.fileName] = record
                }
            }

            // 3. 构建展示模型
            var items: [CompletedFileItem] = []
            for fileURL in fileURLs {
                let fileName = fileURL.lastPathComponent
                let fileSize = self.storageManager.fileSize(at: fileURL)
                let record = dbRecords[fileName]

                let format: VideoFormat
                if let recordFormat = record?.format {
                    format = VideoFormat(rawValue: recordFormat) ?? self.formatFromExtension(fileName)
                } else {
                    format = self.formatFromExtension(fileName)
                }

                let completedAt: Date?
                if let recordCompleted = record?.completedAt {
                    completedAt = recordCompleted
                } else {
                    completedAt = self.fileModificationDate(fileURL)
                }

                let item = CompletedFileItem(
                    id: record?.id ?? UUID(),
                    fileName: fileName,
                    fileURL: fileURL,
                    fileSize: fileSize,
                    format: format,
                    completedAt: completedAt,
                    sourceURL: record?.url,
                    createdAt: record?.createdAt,
                    hasDatabaseRecord: record != nil
                )
                items.append(item)
            }

            // 4. 排序
            let sortedItems = self.sortItems(items)

            DispatchQueue.main.async {
                self.allItems = sortedItems
                if self.isSearchActive {
                    self.applySearchFilter()
                } else {
                    self.filteredItems = self.allItems
                }
                self.tableView.reloadData()
                self.updateEmptyState()
                self.updateStatsHeader()
            }
        }
    }

    // MARK: - Sorting
    private func sortItems(_ items: [CompletedFileItem]) -> [CompletedFileItem] {
        switch currentSortOption {
        case .completedTime:
            return items.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        case .fileName:
            return items.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        case .fileSize:
            return items.sorted { $0.fileSize > $1.fileSize }
        }
    }

    @objc private func showSortOptions() {
        let alert = UIAlertController(title: "排序方式", message: nil, preferredStyle: .actionSheet)

        for option in SortOption.allCases {
            let isCurrent = currentSortOption == option
            let action = UIAlertAction(title: option.displayName, style: .default) { [weak self] _ in
                guard let self = self else { return }
                self.currentSortOption = option
                self.allItems = self.sortItems(self.allItems)
                if self.isSearchActive {
                    self.applySearchFilter()
                } else {
                    self.filteredItems = self.allItems
                }
                self.tableView.reloadData()
            }
            if isCurrent {
                action.setValue(UIImage(systemName: "checkmark"), forKey: "image")
            }
            alert.addAction(action)
        }

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        // iPad 适配
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItem
        }

        present(alert, animated: true)
    }

    // MARK: - Empty State
    private func updateEmptyState() {
        let items = currentItems
        if items.isEmpty {
            emptyStateView.isHidden = false
            tableView.isHidden = true

            if isSearchActive && !(searchController.searchBar.text ?? "").isEmpty {
                emptyStateView.configure(
                    icon: "magnifyingglass",
                    title: "未找到匹配的文件",
                    description: "尝试使用其他关键词搜索"
                )
            } else {
                emptyStateView.configure(
                    icon: "doc.text.magnifyingglass",
                    title: "暂无已下载文件",
                    description: "下载完成的文件将显示在这里"
                )
            }
        } else {
            emptyStateView.isHidden = true
            tableView.isHidden = false
        }
    }

    private func updateStatsHeader() {
        let items = currentItems
        let count = items.count
        let totalSize = items.reduce(Int64(0)) { $0 + $1.fileSize }
        statsLabel.text = "共 \(count) 个文件，占用 \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))"
    }

    // MARK: - Actions
    private func shareFile(at indexPath: IndexPath) {
        let item = currentItems[indexPath.row]
        let activityVC = UIActivityViewController(
            activityItems: [item.fileURL],
            applicationActivities: nil
        )

        // iPad 适配
        if let popover = activityVC.popoverPresentationController {
            if let cell = tableView.cellForRow(at: indexPath) {
                popover.sourceView = cell
                popover.sourceRect = cell.bounds
            } else {
                popover.sourceView = view
                popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            }
        }

        present(activityVC, animated: true)
    }

    private func previewFile(at indexPath: IndexPath) {
        let item = currentItems[indexPath.row]
        previewItemURL = item.fileURL

        let previewController = QLPreviewController()
        previewController.dataSource = self
        navigationController?.pushViewController(previewController, animated: true)
    }

    private func playVideo(at indexPath: IndexPath) {
        let item = currentItems[indexPath.row]
        let playerVC = VideoPlayerViewController(videoURL: item.fileURL)
        playerVC.modalPresentationStyle = .fullScreen
        present(playerVC, animated: true)
    }

    private func showFileDetail(_ item: CompletedFileItem) {
        let detailVC = CompletedFileDetailViewController(item: item)
        navigationController?.pushViewController(detailVC, animated: true)
    }

    private func deleteFile(at indexPath: IndexPath) {
        let item = currentItems[indexPath.row]

        let alert = UIAlertController(
            title: "确认删除",
            message: "确定要删除\"\(item.fileName)\"吗？此操作不可恢复。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            guard let self = self else { return }

            // 1. 删除文件
            try? self.storageManager.deleteFile(at: item.fileURL)

            // 2. 删除数据库记录（如果有）
            if item.hasDatabaseRecord {
                try? VideoDownloadEngine.shared.database.deleteRecord(byId: item.id)
            }

            // 3. 更新数据源
            self.allItems.removeAll { $0.id == item.id }
            self.filteredItems.removeAll { $0.id == item.id }

            // 4. 更新 UI
            self.tableView.deleteRows(at: [indexPath], with: .automatic)
            self.updateEmptyState()
            self.updateStatsHeader()

            Logger.info("Deleted completed file: \(item.fileName)")
        })
        present(alert, animated: true)
    }

    // MARK: - Helpers
    private func formatFromExtension(_ fileName: String) -> VideoFormat {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4": return .mp4
        case "m3u8": return .m3u8
        case "webm": return .webm
        case "mkv": return .mkv
        case "flv": return .flv
        case "mov": return .mov
        default: return .mp4
        }
    }

    private func fileModificationDate(_ url: URL) -> Date? {
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func applySearchFilter() {
        guard let searchText = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces).lowercased() else {
            filteredItems = allItems
            return
        }

        if searchText.isEmpty {
            filteredItems = allItems
        } else {
            filteredItems = allItems.filter { $0.fileName.lowercased().contains(searchText) }
        }
    }
}

// MARK: - UITableViewDataSource
extension CompletedFilesViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return currentItems.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: CompletedFileCell.reuseIdentifier,
            for: indexPath
        ) as? CompletedFileCell else {
            return UITableViewCell()
        }

        let item = currentItems[indexPath.row]
        cell.configure(with: item)
        return cell
    }
}

// MARK: - UITableViewDelegate
extension CompletedFilesViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        playVideo(at: indexPath)
    }

    // 滑动删除
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let deleteAction = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completionHandler in
            self?.deleteFile(at: indexPath)
            completionHandler(true)
        }
        deleteAction.image = UIImage(systemName: "trash")

        let shareAction = UIContextualAction(style: .normal, title: "分享") { [weak self] _, _, completionHandler in
            self?.shareFile(at: indexPath)
            completionHandler(true)
        }
        shareAction.image = UIImage(systemName: "square.and.arrow.up")
        shareAction.backgroundColor = UIColor(hex: "1890ff")

        return UISwipeActionsConfiguration(actions: [deleteAction, shareAction])
    }

    // 长按上下文菜单
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self = self else { return nil }

            let play = UIAction(title: "播放", image: UIImage(systemName: "play.circle")) { _ in
                self.playVideo(at: indexPath)
            }
            let preview = UIAction(title: "预览", image: UIImage(systemName: "eye")) { _ in
                self.previewFile(at: indexPath)
            }
            let share = UIAction(title: "分享", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                self.shareFile(at: indexPath)
            }
            let detail = UIAction(title: "详情", image: UIImage(systemName: "info.circle")) { _ in
                let item = self.currentItems[indexPath.row]
                self.showFileDetail(item)
            }
            let delete = UIAction(title: "删除", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                self.deleteFile(at: indexPath)
            }

            return UIMenu(children: [play, preview, share, detail, UIMenu(title: "", options: .displayInline, children: [delete])])
        }
    }
}

// MARK: - UISearchResultsUpdating
extension CompletedFilesViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        isSearchActive = searchController.isActive
        applySearchFilter()
        tableView.reloadData()
        updateEmptyState()
        updateStatsHeader()
    }
}

// MARK: - QLPreviewControllerDataSource
extension CompletedFilesViewController: QLPreviewControllerDataSource {
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        return previewItemURL != nil ? 1 : 0
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        return previewItemURL! as QLPreviewItem
    }
}
