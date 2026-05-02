import UIKit
import Combine

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
        tableView.backgroundColor = UIColor(hex: "f5f5f5")
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
        view.backgroundColor = .white
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
        label.textColor = UIColor(hex: "333333")
        label.text = "已选0项"
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var deleteButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("删除", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor(hex: "ff4d4f")
        button.layer.cornerRadius = 16
        button.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        button.addTarget(self, action: #selector(deleteSelectedTasks), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    // MARK: - Add Button
    private lazy var addButton: UIButton = {
        let button = UIButton(type: .system)
        button.backgroundColor = UIColor(hex: "1890ff")
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
            addButton.heightAnchor.constraint(equalToConstant: 64)
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
        let alertController = UIAlertController(
            title: "添加下载任务",
            message: "请输入下载URL（每行一个）",
            preferredStyle: .alert
        )

        // URL输入框
        alertController.addTextField { textField in
            textField.placeholder = "视频URL（每行一个）"
            textField.text = "https://example.com/video1.mp4\nhttps://example.com/video2.mp4\nhttps://example.com/video3.m3u8"
            textField.isSecureTextEntry = false
        }

        // 确定按钮
        alertController.addAction(UIAlertAction(title: "确定", style: .default) { [weak self] _ in
            guard let self = self,
                  let urlString = alertController.textFields?[0].text,
                  !urlString.isEmpty else {
                self?.showAlert(title: "错误", message: "请输入URL")
                return
            }

            let urls = urlString.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard !urls.isEmpty else {
                self.showAlert(title: "错误", message: "请输入有效的URL")
                return
            }

            Task {
                await self.createBatchDownload(urls: urls)
            }
        })

        // 取消按钮
        alertController.addAction(UIAlertAction(title: "取消", style: .cancel))

        present(alertController, animated: true)
        
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
                await self?.loadBatchTasks()
            }
        })

        present(alertController, animated: true)
    }

    private func createBatchDownload(urls: [String]) async {
        print("🔥 开始创建批量下载任务，URLs: \(urls)")

        do {
            let now = Date()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            let name = "下载任务 \(formatter.string(from: now))"
            print("🔥 批量任务名称: \(name)")

            let batchTask = try await batchManager.createBatchDownload(
                name: name,
                urls: urls
            )

            print("✅ 批量任务创建成功: \(batchTask.id)")

            await startBatchDownload(batchId: batchTask.id)
            print("✅ 批量任务已开始下载")

            await loadBatchTasks()
            print("✅ 任务列表已刷新")

        } catch {
            print("❌ 创建失败: \(error)")
            showAlert(title: "创建失败", message: error.localizedDescription)
        }
    }

    private func startBatchDownload(batchId: UUID) async {
        do {
            try await batchManager.startBatchDownload(batchId: batchId)
        } catch {
            showAlert(title: "开始失败", message: error.localizedDescription)
        }
    }

    // MARK: - Private Methods
    private func loadBatchTasks() {
        Task {
            let tasks = await batchManager.getAllBatchTasks()
            print("📋 获取到 \(tasks.count) 个批量任务")

            self.batchTasks = tasks
            DispatchQueue.main.async {
                self.tableView.reloadData()
                self.updateSelectionBar()
                self.updateDeleteButton()
            }
        }
    }

    private func subscribeToTaskUpdates() {
        // 定时刷新任务列表
        Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.loadBatchTasks()
            }
            .store(in: &cancellables)
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

// MARK: - UITableViewDataSource & UITableViewDelegate
extension BatchDownloadViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return batchTasks.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "BatchDownloadCell", for: indexPath) as! BatchDownloadCell
        let batchTask = batchTasks[indexPath.row]
        cell.configure(with: batchTask)

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
        return 100
    }
}

// MARK: - Helper Methods
private func formatFileSize(_ bytes: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(bytes))
}
