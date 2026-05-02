import UIKit
import Combine

/// 批量下载任务单元格
class BatchDownloadCell: UITableViewCell {

    // MARK: - UI Components
    private let nameLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 14)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let progressView: UIProgressView = {
        let progressView = UIProgressView()
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progress = 0
        return progressView
    }()

    private let progressLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let countLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private var separatorView: UIView?
    private var cancellables = Set<AnyCancellable>()
    private let engine = VideoDownloadEngine.shared

    // MARK: - Initialization
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup
    private func setupUI() {
        contentView.addSubview(nameLabel)
        contentView.addSubview(statusLabel)
        contentView.addSubview(progressView)
        contentView.addSubview(progressLabel)
        contentView.addSubview(countLabel)

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            statusLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

            progressView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            progressView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            progressView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            progressView.heightAnchor.constraint(equalToConstant: 4),

            progressLabel.topAnchor.constraint(equalTo: progressView.bottomAnchor, constant: 4),
            progressLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

            countLabel.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        ])
    }

    // MARK: - Configuration
    func configure(with batchTask: BatchDownloadManager.BatchDownloadTask) {
        // 清理旧的订阅
        cancellables.removeAll()

        nameLabel.text = batchTask.name
        statusLabel.text = batchTask.state.rawValue
        updateStatusColor(batchTask.state)

        // 显示进度
        updateProgress(batchTask: batchTask)

        // 添加任务状态监听
        NotificationCenter.default.publisher(for: DownloadNotification.stateDidChange)
            .compactMap { $0.userInfo?[DownloadNotificationKey.taskId] as? UUID }
            .filter { [weak self] taskId in
                // 检查这个ID是否属于当前批量的任何任务
                return batchTask.taskItems.contains { $0.task.id == taskId }
            }
            .sink { [weak self] _ in
                self?.updateProgress(batchTask: batchTask)
            }
            .store(in: &cancellables)
    }

    func showSeparator(_ show: Bool) {
        if show {
            if separatorView == nil {
                separatorView = UIView()
                separatorView!.backgroundColor = UIColor(hex: "e0e0e0")
                contentView.addSubview(separatorView!)
                separatorView!.translatesAutoresizingMaskIntoConstraints = false

                NSLayoutConstraint.activate([
                    separatorView!.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                    separatorView!.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                    separatorView!.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                    separatorView!.heightAnchor.constraint(equalToConstant: 1)
                ])
            }
        } else {
            separatorView?.removeFromSuperview()
            separatorView = nil
        }
    }

    private func updateProgress(batchTask: BatchDownloadManager.BatchDownloadTask) {
        let total = batchTask.taskItems.count
        let completed = batchTask.taskItems.filter { $0.task.state.value == .completed }.count
        let downloading = batchTask.taskItems.filter { $0.task.state.value == .downloading }.count
        let paused = batchTask.taskItems.filter { $0.task.state.value == .paused }.count

        progressView.progress = Float(completed) / Float(total)
        progressLabel.text = "\(completed)/\(total)"
        countLabel.text = "总数: \(total)"
    }

    private func updateStatusColor(_ state: BatchDownloadManager.BatchState) {
        switch state {
        case .pending:
            statusLabel.textColor = .secondaryLabel
        case .downloading:
            statusLabel.textColor = .systemBlue
        case .paused:
            statusLabel.textColor = .systemOrange
        case .completed:
            statusLabel.textColor = .systemGreen
        case .failed:
            statusLabel.textColor = .systemRed
        case .cancelled:
            statusLabel.textColor = .gray
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancellables.removeAll()
        progressView.progress = 0
        progressLabel.text = ""
        countLabel.text = ""
        separatorView?.removeFromSuperview()
        separatorView = nil
    }
}