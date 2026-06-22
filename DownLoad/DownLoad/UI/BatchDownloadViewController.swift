import UIKit
import Combine

struct BatchURLInputRow {
    let rawURL: String
    let normalizedURL: String?
    let fileName: String
    let message: String

    var canCreateTask: Bool {
        normalizedURL != nil && message == "可添加"
    }
}

struct BatchURLInputParser {
    static func parse(_ text: String) -> [BatchURLInputRow] {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seenURLs = Set<String>()
        return lines.map { line in
            guard let normalizedURL = SingleDownloadInput.normalizedURLString(for: line) else {
                return BatchURLInputRow(
                    rawURL: line,
                    normalizedURL: nil,
                    fileName: "",
                    message: "URL 无效"
                )
            }

            if seenURLs.contains(normalizedURL) {
                return BatchURLInputRow(
                    rawURL: line,
                    normalizedURL: normalizedURL,
                    fileName: SingleDownloadInput.suggestedFileName(for: normalizedURL),
                    message: "重复 URL"
                )
            }

            seenURLs.insert(normalizedURL)
            return BatchURLInputRow(
                rawURL: line,
                normalizedURL: normalizedURL,
                fileName: SingleDownloadInput.suggestedFileName(for: normalizedURL),
                message: "可添加"
            )
        }
    }
}

/// 批量下载任务管理界面
class BatchDownloadViewController: UIViewController {

    // MARK: - Properties
    private let batchManager = BatchDownloadManager.shared
    private let engine = VideoDownloadEngine.shared
    private var cancellables = Set<AnyCancellable>()
    private var batchTasks: [BatchDownloadManager.BatchDownloadTask] = []
    private var selectedTaskIds: Set<UUID> = []
    private var isEditMode = false

    // MARK: - UI Components
    private lazy var tableView: UITableView = {
        let tableView = UITableView()
        tableView.register(BatchDownloadCell.self, forCellReuseIdentifier: "BatchDownloadCell")
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .systemGroupedBackground
        tableView.separatorStyle = .none
        tableView.translatesAutoresizingMaskIntoConstraints = false
        return tableView
    }()

    private lazy var editButton: UIBarButtonItem = {
        let button = UIBarButtonItem(
            title: "编辑",
            style: .plain,
            target: self,
            action: #selector(toggleEditMode)
        )
        return button
    }()

    // MARK: - Selection Bar
    private lazy var selectionBar: UIView = {
        let view = UIView()
        view.backgroundColor = .secondarySystemGroupedBackground
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var selectionCheckbox: UIImageView = {
        let imageView = UIImageView()
        imageView.isUserInteractionEnabled = true
        imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleSelectAll)))
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()

    private lazy var selectionLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 14)
        label.textColor = .label
        label.text = "已选0项"
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var deleteButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("删除", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = .systemRed
        button.layer.cornerRadius = 16
        button.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        button.addTarget(self, action: #selector(deleteSelectedTasks), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    // MARK: - Empty State & Loading
    private lazy var emptyStateView: EmptyStateView = {
        let view = EmptyStateView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()

    private lazy var loadingIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.hidesWhenStopped = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()

    // MARK: - Add Button
    private lazy var addButton: UIButton = {
        let button = UIButton(type: .system)
        button.backgroundColor = .systemBlue
        button.layer.cornerRadius = 16
        button.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)), for: .normal)
        button.tintColor = .white
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(showAddTaskDialog), for: .touchUpInside)
        return button
    }()

    
    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadBatchTasks()
        subscribeToTaskUpdates()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        loadBatchTasks()
    }

    // MARK: - Setup
    private func setupUI() {
        title = "批量下载"
        navigationItem.rightBarButtonItem = editButton

        view.addSubview(tableView)
        view.addSubview(emptyStateView)
        view.addSubview(loadingIndicator)
        view.addSubview(selectionBar)
        view.addSubview(addButton)

        // 设置选择栏
        selectionBar.addSubview(selectionCheckbox)
        selectionBar.addSubview(selectionLabel)
        selectionBar.addSubview(deleteButton)

        // 设置约束
        NSLayoutConstraint.activate([
            // Table View
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Selection Bar
            selectionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            selectionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            selectionBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            selectionBar.heightAnchor.constraint(equalToConstant: 48),

            // Selection Checkbox
            selectionCheckbox.leadingAnchor.constraint(equalTo: selectionBar.leadingAnchor, constant: 16),
            selectionCheckbox.centerYAnchor.constraint(equalTo: selectionBar.centerYAnchor),
            selectionCheckbox.widthAnchor.constraint(equalToConstant: 32),
            selectionCheckbox.heightAnchor.constraint(equalToConstant: 32),

            // Selection Label
            selectionLabel.leadingAnchor.constraint(equalTo: selectionCheckbox.trailingAnchor, constant: 8),
            selectionLabel.centerYAnchor.constraint(equalTo: selectionBar.centerYAnchor),

            // Delete Button
            deleteButton.trailingAnchor.constraint(equalTo: selectionBar.trailingAnchor, constant: -16),
            deleteButton.centerYAnchor.constraint(equalTo: selectionBar.centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 88),
            deleteButton.heightAnchor.constraint(equalToConstant: 32),

            // Add Button
            addButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            addButton.bottomAnchor.constraint(equalTo: selectionBar.topAnchor, constant: -16),
            addButton.widthAnchor.constraint(equalToConstant: 64),
            addButton.heightAnchor.constraint(equalToConstant: 64),

            // Empty State View
            emptyStateView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: selectionBar.topAnchor),

            // Loading Indicator
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    // MARK: - Actions
    @objc private func toggleEditMode() {
        isEditMode = !isEditMode
        tableView.setEditing(isEditMode, animated: true)
        editButton.title = isEditMode ? "完成" : "编辑"
        updateSelectionBar()
        updateDeleteButton()
    }

    @objc private func toggleSelectAll() {
        if selectedTaskIds.count == batchTasks.count {
            // 取消全部选择
            selectedTaskIds.removeAll()
        } else {
            // 全部选择
            selectedTaskIds = Set(batchTasks.map { $0.id })
        }
        updateSelectionBar()
        tableView.reloadData()
    }

    @objc private func showAddTaskDialog() {
        let addViewController = BatchAddViewController()
        addViewController.onCreate = { [weak self] rows in
            let urls = rows.compactMap { $0.normalizedURL }
            let fileNames = rows.map { $0.fileName }
            Task {
                await self?.createBatchDownload(urls: urls, fileNames: fileNames)
            }
        }

        let navigationController = UINavigationController(rootViewController: addViewController)
        if #available(iOS 15.0, *) {
            navigationController.sheetPresentationController?.detents = [.large()]
            navigationController.sheetPresentationController?.prefersGrabberVisible = true
        }
        present(navigationController, animated: true)
    }

    @objc private func deleteSelectedTasks() {
        guard !selectedTaskIds.isEmpty else { return }

        let alertController = UIAlertController(
            title: "确认删除",
            message: "确定要删除选中的下载任务吗？",
            preferredStyle: .alert
        )

        alertController.addAction(UIAlertAction(title: "取消", style: .cancel))
        alertController.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            Task {
                for batchId in self?.selectedTaskIds ?? [] {
                    await self?.batchManager.deleteBatchDownload(batchId: batchId)
                }
                self?.selectedTaskIds.removeAll()
                self?.loadBatchTasks()
            }
        })

        present(alertController, animated: true)
    }

    private func createBatchDownload(urls: [String], fileNames: [String]? = nil) async {
        AppLogger.info("开始创建批量下载任务，URLs: \(urls)")

        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let name = "下载任务 \(formatter.string(from: now))"
        AppLogger.info("批量任务名称: \(name)")

        let result = await batchManager.createBatchDownload(
            name: name,
            urls: urls,
            fileNames: fileNames
        )

        AppLogger.info("批量任务创建完成: \(result.batchTask.id)")
        AppLogger.info(result.summary)

        // 如果有失败项，显示提示
        if result.hasFailures {
            let message = result.summary + "\n失败项可在任务详情中查看并重试"
            showAlert(title: "批量任务创建完成（部分失败）", message: message)
        }

        await startBatchDownload(batchId: result.batchTask.id)
        AppLogger.info("批量任务已开始下载")

        loadBatchTasks()
        AppLogger.info("任务列表已刷新")
    }

    private func startBatchDownload(batchId: UUID) async {
        do {
            try await batchManager.startBatchDownload(batchId: batchId)
        } catch {
            showAlert(title: "开始失败", message: error.localizedDescription)
        }
    }

    /// 重试批量任务的失败项
    private func retryFailedItems(batchId: UUID) {
        Task {
            guard let result = await batchManager.retryFailedItems(batchId: batchId) else {
                showAlert(title: "重试失败", message: "无法找到批量任务或没有失败项")
                return
            }

            if result.hasFailures {
                showAlert(title: "重试完成（仍有失败）", message: result.summary)
            } else {
                showAlert(title: "重试成功", message: "所有失败项已重新添加并开始下载")
            }

            loadBatchTasks()
        }
    }

    /// 显示批量任务详情（含失败项）
    private func showBatchTaskDetail(_ batchTask: BatchDownloadManager.BatchDownloadTask) {
        let detailViewController = BatchTaskDetailViewController(batchTask: batchTask)
        detailViewController.onRetryFailedItems = { [weak self] batchId in
            self?.retryFailedItems(batchId: batchId)
        }
        navigationController?.pushViewController(detailViewController, animated: true)
    }

    // MARK: - Empty State
    private func updateEmptyState(isError: Bool = false) {
        if batchTasks.isEmpty {
            emptyStateView.isHidden = false
            tableView.isHidden = true

            if isError {
                emptyStateView.configure(
                    icon: "exclamationmark.triangle",
                    title: "加载失败",
                    description: "请稍后重试"
                )
            } else {
                emptyStateView.configure(
                    icon: "tray",
                    title: "暂无批量下载任务",
                    description: "点击右下角 + 按钮添加批量下载任务"
                )
            }
        } else {
            emptyStateView.isHidden = true
            tableView.isHidden = false
        }
    }

    // MARK: - Private Methods
    private func loadBatchTasks() {
        Task {
            // 显示加载状态
            DispatchQueue.main.async {
                self.loadingIndicator.startAnimating()
                self.emptyStateView.isHidden = true
                self.tableView.isHidden = true
            }

            await batchManager.restoreBatchDownloads()
            let tasks = await batchManager.getAllBatchTasks()
            AppLogger.info("获取到 \(tasks.count) 个批量任务")

            self.batchTasks = tasks
            DispatchQueue.main.async {
                self.loadingIndicator.stopAnimating()
                self.tableView.reloadData()
                self.updateSelectionBar()
                self.updateDeleteButton()
                self.updateEmptyState()
            }
        }
    }

    private func subscribeToTaskUpdates() {
        // 监听进度更新通知，实时刷新对应 Cell
        NotificationCenter.default.publisher(for: DownloadNotification.progressDidUpdate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self,
                      let taskId = notification.userInfo?[DownloadNotificationKey.taskId] as? UUID else {
                    return
                }
                self.refreshCellIfContains(taskId: taskId)
            }
            .store(in: &cancellables)

        // 监听状态变化通知
        NotificationCenter.default.publisher(for: DownloadNotification.stateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self,
                      let taskId = notification.userInfo?[DownloadNotificationKey.taskId] as? UUID else {
                    return
                }
                self.refreshCellIfContains(taskId: taskId)
            }
            .store(in: &cancellables)
    }

    private func refreshCellIfContains(taskId: UUID) {
        for (index, batchTask) in batchTasks.enumerated() where batchTask.taskItems.contains(where: { $0.task.id == taskId }) {
            let batchId = batchTask.id
            Task {
                _ = await batchManager.recomputeBatchState(batchId: batchId)
                guard let latestBatchTask = await batchManager.getBatchTask(by: batchId) else {
                    return
                }

                await MainActor.run {
                    guard index < self.batchTasks.count else { return }
                    self.batchTasks[index] = latestBatchTask
                    let indexPath = IndexPath(row: index, section: 0)
                    if let cell = self.tableView.cellForRow(at: indexPath) as? BatchDownloadCell {
                        cell.configure(with: latestBatchTask)
                    } else {
                        self.tableView.reloadRows(at: [indexPath], with: .none)
                    }
                }
            }
            break
        }
    }

    private func updateSelectionBar() {
        if isEditMode {
            selectionLabel.text = "已选\(selectedTaskIds.count)项"
            selectionCheckbox.image = selectedTaskIds.count == batchTasks.count ?
                UIImage(systemName: "checkmark.square.fill") :
                UIImage(systemName: "square")
            deleteButton.isHidden = false
        } else {
            selectionLabel.text = ""
            selectionCheckbox.image = UIImage(systemName: "square")
            deleteButton.isHidden = true
        }
    }

    private func updateDeleteButton() {
        deleteButton.isEnabled = !selectedTaskIds.isEmpty
    }

    private func showAlert(title: String, message: String) {
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: "确定", style: .default))
        present(alertController, animated: true)
    }
}

final class BatchAddViewController: UIViewController {
    var onCreate: (([BatchURLInputRow]) -> Void)?

    private var rows: [BatchURLInputRow] = [] {
        didSet {
            tableView.reloadData()
            updateSummary()
        }
    }

    private lazy var textView: UITextView = {
        let textView = UITextView()
        textView.font = UIFont.systemFont(ofSize: 15)
        textView.backgroundColor = .secondarySystemGroupedBackground
        textView.layer.cornerRadius = 8
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false
        return textView
    }()

    private lazy var placeholderLabel: UILabel = {
        let label = UILabel()
        label.text = "每行一个下载 URL"
        label.font = UIFont.systemFont(ofSize: 15)
        label.textColor = .placeholderText
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var summaryLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var tableView: UITableView = {
        let tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "BatchURLCell")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        return tableView
    }()

    private lazy var createButton: UIBarButtonItem = {
        let button = UIBarButtonItem(
            title: "创建",
            style: .done,
            target: self,
            action: #selector(createTapped)
        )
        button.isEnabled = false
        return button
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "添加批量下载"
        view.backgroundColor = .systemGroupedBackground
        setupNavigationItems()
        setupUI()
        updateRows()
    }

    private func setupNavigationItems() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "取消",
            style: .plain,
            target: self,
            action: #selector(cancelTapped)
        )
        navigationItem.rightBarButtonItems = [
            createButton,
            UIBarButtonItem(title: "粘贴", style: .plain, target: self, action: #selector(pasteTapped))
        ]
    }

    private func setupUI() {
        view.addSubview(textView)
        view.addSubview(summaryLabel)
        view.addSubview(tableView)
        textView.addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.heightAnchor.constraint(equalToConstant: 180),

            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 12),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 14),

            summaryLabel.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 10),
            summaryLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            summaryLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            tableView.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func updateRows() {
        rows = BatchURLInputParser.parse(textView.text)
        placeholderLabel.isHidden = !textView.text.isEmpty
    }

    private func updateSummary() {
        let validCount = rows.filter(\.canCreateTask).count
        let invalidCount = rows.count - validCount
        summaryLabel.text = rows.isEmpty
            ? "粘贴 URL 后会在这里预览文件名、重复项和非法行。"
            : "可创建 \(validCount) 项，需处理 \(invalidCount) 项"
        createButton.isEnabled = validCount > 0
    }

    @objc private func pasteTapped() {
        guard let pastedText = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pastedText.isEmpty else {
            return
        }

        if textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            textView.text = pastedText
        } else {
            textView.text += "\n\(pastedText)"
        }
        updateRows()
    }

    @objc private func createTapped() {
        let creatableRows = rows.filter(\.canCreateTask)
        guard !creatableRows.isEmpty else { return }
        dismiss(animated: true) { [onCreate] in
            onCreate?(creatableRows)
        }
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }
}

extension BatchAddViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        updateRows()
    }
}

extension BatchAddViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "BatchURLCell")
        let row = rows[indexPath.row]

        cell.textLabel?.text = row.rawURL
        cell.textLabel?.lineBreakMode = .byTruncatingMiddle
        cell.detailTextLabel?.text = row.canCreateTask ? row.fileName : row.message
        cell.detailTextLabel?.textColor = row.canCreateTask ? .secondaryLabel : .systemRed
        cell.accessoryType = row.canCreateTask ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }
}

final class BatchTaskDetailViewController: UIViewController {
    var onRetryFailedItems: ((UUID) -> Void)?

    private let batchTask: BatchDownloadManager.BatchDownloadTask

    private enum Section: Int, CaseIterable {
        case summary = 0
        case tasks = 1
        case failedItems = 2
    }

    private lazy var tableView: UITableView = {
        let tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.translatesAutoresizingMaskIntoConstraints = false
        return tableView
    }()

    init(batchTask: BatchDownloadManager.BatchDownloadTask) {
        self.batchTask = batchTask
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = batchTask.name
        view.backgroundColor = .systemGroupedBackground
        setupNavigationItem()
        setupUI()
    }

    private func setupNavigationItem() {
        guard !batchTask.failedItems.isEmpty else { return }
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "重试失败项",
            style: .plain,
            target: self,
            action: #selector(retryFailedItemsTapped)
        )
    }

    private func setupUI() {
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    @objc private func retryFailedItemsTapped() {
        let retryHandler = onRetryFailedItems
        navigationController?.popViewController(animated: true)
        retryHandler?(batchTask.id)
    }

    private func summaryRows() -> [(String, String)] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let total = batchTask.taskItems.count + batchTask.failedItems.count
        return [
            ("状态", batchTask.state.displayText),
            ("总数", "\(total) 项"),
            ("成功创建", "\(batchTask.taskItems.count) 项"),
            ("创建失败", "\(batchTask.failedItems.count) 项"),
            ("创建时间", formatter.string(from: batchTask.createdAt))
        ]
    }
}

extension BatchTaskDetailViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .summary:
            return summaryRows().count
        case .tasks:
            return batchTask.taskItems.count
        case .failedItems:
            return batchTask.failedItems.count
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .summary:
            return "概要"
        case .tasks:
            return batchTask.taskItems.isEmpty ? nil : "子任务"
        case .failedItems:
            return batchTask.failedItems.isEmpty ? nil : "失败项"
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .summary:
            let row = summaryRows()[indexPath.row]
            let cell = UITableViewCell(style: .value1, reuseIdentifier: "SummaryCell")
            cell.textLabel?.text = row.0
            cell.detailTextLabel?.text = row.1
            cell.selectionStyle = .none
            return cell

        case .tasks:
            let item = batchTask.taskItems[indexPath.row]
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "TaskCell")
            cell.textLabel?.text = item.fileName
            cell.textLabel?.numberOfLines = 1
            cell.detailTextLabel?.text = "\(item.task.state.value.displayText) · \(item.task.progress.value.percentage)"
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.selectionStyle = .none
            return cell

        case .failedItems:
            let item = batchTask.failedItems[indexPath.row]
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "FailedItemCell")
            cell.textLabel?.text = item.fileName
            cell.textLabel?.textColor = .systemRed
            cell.detailTextLabel?.text = "\(item.url)\n\(item.errorDescription)"
            cell.detailTextLabel?.numberOfLines = 0
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.selectionStyle = .none
            return cell
        }
    }
}

// MARK: - UITableViewDataSource & UITableViewDelegate
extension BatchDownloadViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return batchTasks.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "BatchDownloadCell", for: indexPath) as! BatchDownloadCell
        let batchTask = batchTasks[indexPath.row]
        cell.configure(with: batchTask)
        cell.delegate = self

        // 添加分隔线
        if indexPath.row < batchTasks.count - 1 {
            // 检查下一个任务状态是否相同，相同则不显示分隔线
            let nextTask = batchTasks[indexPath.row + 1]
            if batchTask.state != nextTask.state {
                cell.showSeparator(true)
            } else {
                cell.showSeparator(false)
            }
        } else {
            // 最后一个任务总是显示分隔线
            cell.showSeparator(false)
        }

        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if isEditMode {
            let batchTask = batchTasks[indexPath.row]
            if selectedTaskIds.contains(batchTask.id) {
                selectedTaskIds.remove(batchTask.id)
            } else {
                selectedTaskIds.insert(batchTask.id)
            }
            updateSelectionBar()
            updateDeleteButton()
        } else {
            tableView.deselectRow(at: indexPath, animated: true)
            let batchTask = batchTasks[indexPath.row]
            showBatchTaskDetail(batchTask)
        }
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        if isEditMode {
            let batchTask = batchTasks[indexPath.row]
            selectedTaskIds.remove(batchTask.id)
            updateSelectionBar()
            updateDeleteButton()
        }
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        return .delete
    }

    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        return false
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            let batchTask = batchTasks[indexPath.row]

            let alertController = UIAlertController(
                title: "确认删除",
                message: "确定要删除批量任务\"\(batchTask.name)\"吗？包含 \(batchTask.taskItems.count) 个文件",
                preferredStyle: .alert
            )

            alertController.addAction(UIAlertAction(title: "取消", style: .cancel))
            alertController.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
                Task {
                    await self?.batchManager.deleteBatchDownload(batchId: batchTask.id)
                    self?.loadBatchTasks()
                }
            })

            present(alertController, animated: true)
        }
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 140
    }
}

// MARK: - BatchDownloadCellDelegate
extension BatchDownloadViewController: BatchDownloadCellDelegate {
    func batchDownloadCell(_ cell: BatchDownloadCell, didTapPause batchId: UUID) {
        Task {
            await batchManager.pauseBatchDownload(batchId: batchId)
            loadBatchTasks()
        }
    }

    func batchDownloadCell(_ cell: BatchDownloadCell, didTapResume batchId: UUID) {
        Task {
            do {
                try await batchManager.startBatchDownload(batchId: batchId)
                loadBatchTasks()
            } catch {
                showAlert(title: "恢复失败", message: error.localizedDescription)
            }
        }
    }

    func batchDownloadCell(_ cell: BatchDownloadCell, didTapRetry batchId: UUID) {
        retryFailedItems(batchId: batchId)
    }

    func batchDownloadCell(_ cell: BatchDownloadCell, didTapCancel batchId: UUID) {
        let alertController = UIAlertController(
            title: "确认取消",
            message: "确定要取消该批量下载任务吗？",
            preferredStyle: .alert
        )
        alertController.addAction(UIAlertAction(title: "取消", style: .cancel))
        alertController.addAction(UIAlertAction(title: "确定", style: .destructive) { [weak self] _ in
            Task {
                await self?.batchManager.cancelBatchDownload(batchId: batchId)
                self?.loadBatchTasks()
            }
        })
        present(alertController, animated: true)
    }
}

// MARK: - Helper Methods
private func formatFileSize(_ bytes: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(bytes))
}
