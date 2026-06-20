import UIKit
import Combine

// MARK: - BatchDownloadCellDelegate
protocol BatchDownloadCellDelegate: AnyObject {
    func batchDownloadCell(_ cell: BatchDownloadCell, didTapPause batchId: UUID)
    func batchDownloadCell(_ cell: BatchDownloadCell, didTapResume batchId: UUID)
    func batchDownloadCell(_ cell: BatchDownloadCell, didTapRetry batchId: UUID)
    func batchDownloadCell(_ cell: BatchDownloadCell, didTapCancel batchId: UUID)
}

/// 批量下载任务单元格
class BatchDownloadCell: UITableViewCell {

    // MARK: - Properties
    weak var delegate: BatchDownloadCellDelegate?
    private var currentBatchId: UUID?

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

    private let failedCountLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 12)
        label.textColor = .systemRed
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()

    private let infoLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let actionStackView: UIStackView = {
        let sv = UIStackView()
        sv.axis = .horizontal
        sv.spacing = 8
        sv.distribution = .fillEqually
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private lazy var pauseResumeButton: UIButton = {
        let button = UIButton(type: .system)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        button.layer.cornerRadius = 4
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(pauseResumeTapped), for: .touchUpInside)
        return button
    }()

    private lazy var retryButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("重试", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor(hex: "52c41a")
        button.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        button.layer.cornerRadius = 4
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        return button
    }()

    private lazy var cancelButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("取消", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor(hex: "ff4d4f")
        button.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        button.layer.cornerRadius = 4
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        return button
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
        contentView.addSubview(failedCountLabel)
        contentView.addSubview(infoLabel)
        contentView.addSubview(actionStackView)
        actionStackView.addArrangedSubview(pauseResumeButton)
        actionStackView.addArrangedSubview(retryButton)
        actionStackView.addArrangedSubview(cancelButton)

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
            countLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            failedCountLabel.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 2),
            failedCountLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            infoLabel.topAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: 4),
            infoLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),

            actionStackView.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 8),
            actionStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            actionStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            actionStackView.heightAnchor.constraint(equalToConstant: 32),
            actionStackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    // MARK: - Configuration
    func configure(with batchTask: BatchDownloadManager.BatchDownloadTask) {
        // 清理旧的订阅
        cancellables.removeAll()

        currentBatchId = batchTask.id
        nameLabel.text = batchTask.name
        statusLabel.text = batchTask.state.displayText
        updateStatusColor(batchTask.state)

        // 显示进度
        updateProgress(batchTask: batchTask)

        // 更新操作按钮状态
        updateActionButtons(state: batchTask.state, hasFailedItems: !batchTask.failedItems.isEmpty)

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

    private func updateActionButtons(state: BatchDownloadManager.BatchState, hasFailedItems: Bool) {
        switch state {
        case .downloading:
            pauseResumeButton.setTitle("暂停", for: .normal)
            pauseResumeButton.backgroundColor = UIColor(hex: "faad14")
            pauseResumeButton.setTitleColor(.white, for: .normal)
            pauseResumeButton.isHidden = false
            retryButton.isHidden = true
            cancelButton.isHidden = false
        case .paused:
            pauseResumeButton.setTitle("恢复", for: .normal)
            pauseResumeButton.backgroundColor = UIColor(hex: "1890ff")
            pauseResumeButton.setTitleColor(.white, for: .normal)
            pauseResumeButton.isHidden = false
            retryButton.isHidden = true
            cancelButton.isHidden = false
        case .failed, .partiallyFailed:
            pauseResumeButton.isHidden = true
            retryButton.isHidden = !hasFailedItems
            cancelButton.isHidden = false
        case .pending:
            pauseResumeButton.isHidden = true
            retryButton.isHidden = true
            cancelButton.isHidden = false
        case .completed, .cancelled:
            pauseResumeButton.isHidden = true
            retryButton.isHidden = true
            cancelButton.isHidden = true
        }
    }

    @objc private func pauseResumeTapped() {
        guard let batchId = currentBatchId else { return }
        let title = pauseResumeButton.title(for: .normal)
        if title == "暂停" {
            delegate?.batchDownloadCell(self, didTapPause: batchId)
        } else if title == "恢复" {
            delegate?.batchDownloadCell(self, didTapResume: batchId)
        }
    }

    @objc private func retryTapped() {
        guard let batchId = currentBatchId else { return }
        delegate?.batchDownloadCell(self, didTapRetry: batchId)
    }

    @objc private func cancelTapped() {
        guard let batchId = currentBatchId else { return }
        delegate?.batchDownloadCell(self, didTapCancel: batchId)
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
        Task {
            let progress = await engine.getBatchProgress(batchId: batchTask.id)
            let total = progress?.total ?? batchTask.taskItems.count
            let completed = progress?.completed ?? 0
            let downloading = progress?.downloading ?? 0
            let paused = progress?.paused ?? 0
            let failedInCreation = progress?.failedInCreation ?? 0

            // 聚合计算已下载大小和总大小
            var totalDownloadedBytes: Int64 = 0
            var totalTotalBytes: Int64 = 0

            for item in batchTask.taskItems {
                if let task = await engine.getTask(by: item.task.id) {
                    totalDownloadedBytes += task.downloadedSize
                    if let taskTotal = task.totalSize {
                        totalTotalBytes += taskTotal
                    }
                }
            }

            let sizeText: String
            if totalTotalBytes > 0 {
                sizeText = "\(ByteCountFormatter.string(fromByteCount: totalDownloadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: totalTotalBytes, countStyle: .file))"
            } else {
                sizeText = "大小计算中..."
            }

            await MainActor.run {
                progressView.progress = total > 0 ? Float(completed) / Float(total) : 0
                progressLabel.text = "\(completed)/\(total) (\(Int((Float(completed) / Float(total)) * 100))%)"
                countLabel.text = "下载中:\(downloading) 暂停:\(paused)"
                infoLabel.text = sizeText

                if failedInCreation > 0 {
                    failedCountLabel.text = "创建失败:\(failedInCreation)"
                    failedCountLabel.isHidden = false
                } else {
                    failedCountLabel.isHidden = true
                }
            }
        }
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
        case .partiallyFailed:
            statusLabel.textColor = .systemOrange
        case .cancelled:
            statusLabel.textColor = .gray
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancellables.removeAll()
        currentBatchId = nil
        delegate = nil
        progressView.progress = 0
        progressLabel.text = ""
        countLabel.text = ""
        infoLabel.text = ""
        failedCountLabel.isHidden = true
        failedCountLabel.text = ""
        pauseResumeButton.isHidden = true
        retryButton.isHidden = true
        cancelButton.isHidden = true
        separatorView?.removeFromSuperview()
        separatorView = nil
    }
}