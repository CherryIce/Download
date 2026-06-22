//
//  ViewController.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import UIKit
import Combine
import AVKit

struct SingleDownloadInput {
    static func normalizedURLString(for rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased() else {
            return nil
        }

        switch scheme {
        case "http", "https":
            guard url.host?.isEmpty == false else { return nil }
        case "thunder", "thunderp2p", "magnet":
            break
        default:
            return nil
        }

        return trimmed
    }

    static func suggestedFileName(for rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(string: trimmed)
        let format = VideoFormatDetector.detectFromURLString(trimmed) ?? .mp4
        let fallbackName = "video"

        let pathComponent = url?.deletingPathExtension().lastPathComponent
            .removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = sanitizeFileName(pathComponent?.isEmpty == false ? pathComponent! : fallbackName)
        let extensionName = format.fileExtension

        return "\(baseName).\(extensionName)"
    }

    private static func sanitizeFileName(_ value: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let components = value.components(separatedBy: disallowed)
        let sanitized = components.joined(separator: "-")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return sanitized.isEmpty ? "video" : sanitized
    }
}

class ViewController: UIViewController {

    private let downloadEngine = VideoDownloadEngine.shared
    private let storageManager = FileStorageManager()
    private var cancellables = Set<AnyCancellable>()
    private var currentTask: (any DownloadTask)?
    private var isFileNameEditedManually = false

    private let urlTextField: UITextField = {
        let tf = UITextField()
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.placeholder = Strings.Placeholder.urlInput
        tf.borderStyle = .roundedRect
        tf.autocorrectionType = .no
        tf.autocapitalizationType = .none
        tf.keyboardType = .URL
        tf.returnKeyType = .done
        tf.clearButtonMode = .whileEditing
        return tf
    }()

    private let fileNameTextField: UITextField = {
        let tf = UITextField()
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.placeholder = "自动识别文件名，可手动修改"
        tf.borderStyle = .roundedRect
        tf.autocorrectionType = .no
        tf.autocapitalizationType = .none
        tf.returnKeyType = .done
        tf.clearButtonMode = .whileEditing
        return tf
    }()

    private let formatValueLabel = ViewController.makeValueLabel(text: "待识别")
    private let statusValueLabel = ViewController.makeValueLabel(text: "未开始")
    private let progressPercentLabel = ViewController.makeValueLabel(text: "0%")
    private let sizeValueLabel = ViewController.makeValueLabel(text: "--")
    private let speedValueLabel = ViewController.makeValueLabel(text: "--")
    private let remainingValueLabel = ViewController.makeValueLabel(text: "--")

    private let progressView: UIProgressView = {
        let view = UIProgressView(progressViewStyle: .default)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.progress = 0
        return view
    }()

    private let errorLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = .systemRed
        label.numberOfLines = 0
        label.isHidden = true
        return label
    }()

    private lazy var downloadButton = makeActionButton(title: Strings.Button.startDownload, icon: "arrow.down.circle", color: .systemBlue)
    private lazy var pauseButton = makeActionButton(title: Strings.Button.pause, icon: "pause.circle", color: .systemOrange)
    private lazy var cancelButton = makeActionButton(title: Strings.Button.cancel, icon: "xmark.circle", color: .systemRed)
    private lazy var retryButton = makeActionButton(title: Strings.Button.retry, icon: "arrow.clockwise.circle", color: .systemGreen)
    private lazy var playButton = makeActionButton(title: Strings.Button.play, icon: "play.circle", color: .systemPurple)
    private lazy var shareButton = makeActionButton(title: Strings.Button.share, icon: "square.and.arrow.up", color: .systemBlue)
    private lazy var detailButton = makeActionButton(title: Strings.Button.detail, icon: "info.circle", color: .systemGray)

    private let debugLogButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("显示调试日志", for: .normal)
        return button
    }()

    private let debugTextView: UITextView = {
        let tv = UITextView()
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.isEditable = false
        tv.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.backgroundColor = .secondarySystemGroupedBackground
        tv.layer.cornerRadius = 8
        tv.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        tv.isHidden = true
        return tv
    }()

    private let scrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        return scrollView
    }()

    private let contentStackView: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 16
        return stack
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        updateActionButtons(for: nil)
        updateURLDerivedFields()
    }

    private func setupUI() {
        title = Strings.Title.singleDownload
        view.backgroundColor = .systemGroupedBackground
        view.addSubview(scrollView)
        scrollView.addSubview(contentStackView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            contentStackView.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            contentStackView.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
            contentStackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24)
        ])

        contentStackView.addArrangedSubview(makeInputCard())
        contentStackView.addArrangedSubview(makeProgressCard())
        contentStackView.addArrangedSubview(makeActionCard())
        contentStackView.addArrangedSubview(debugLogButton)
        contentStackView.addArrangedSubview(debugTextView)
        debugTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        downloadButton.addTarget(self, action: #selector(startDownload), for: .touchUpInside)
        pauseButton.addTarget(self, action: #selector(pauseDownload), for: .touchUpInside)
        cancelButton.addTarget(self, action: #selector(cancelDownload), for: .touchUpInside)
        retryButton.addTarget(self, action: #selector(retryDownload), for: .touchUpInside)
        playButton.addTarget(self, action: #selector(playDownloadedVideo), for: .touchUpInside)
        shareButton.addTarget(self, action: #selector(shareDownloadedVideo), for: .touchUpInside)
        detailButton.addTarget(self, action: #selector(showDownloadedFileDetail), for: .touchUpInside)
        debugLogButton.addTarget(self, action: #selector(toggleDebugLog), for: .touchUpInside)

        urlTextField.addTarget(self, action: #selector(urlTextDidChange), for: .editingChanged)
        fileNameTextField.addTarget(self, action: #selector(fileNameTextDidChange), for: .editingChanged)
        urlTextField.delegate = self
        fileNameTextField.delegate = self
    }

    private func makeInputCard() -> UIView {
        let stack = makeCardStack()
        stack.addArrangedSubview(makeSectionTitle("下载信息"))
        stack.addArrangedSubview(urlTextField)
        stack.addArrangedSubview(fileNameTextField)
        stack.addArrangedSubview(makeInfoRow(title: "识别格式", valueLabel: formatValueLabel))
        return wrapCard(stack)
    }

    private func makeProgressCard() -> UIView {
        let stack = makeCardStack()
        stack.addArrangedSubview(makeSectionTitle("任务状态"))
        stack.addArrangedSubview(makeInfoRow(title: "状态", valueLabel: statusValueLabel))
        stack.addArrangedSubview(progressView)
        stack.addArrangedSubview(makeInfoRow(title: "进度", valueLabel: progressPercentLabel))
        stack.addArrangedSubview(makeInfoRow(title: "大小", valueLabel: sizeValueLabel))
        stack.addArrangedSubview(makeInfoRow(title: "速度", valueLabel: speedValueLabel))
        stack.addArrangedSubview(makeInfoRow(title: "剩余时间", valueLabel: remainingValueLabel))
        stack.addArrangedSubview(errorLabel)
        return wrapCard(stack)
    }

    private func makeActionCard() -> UIView {
        let stack = makeCardStack()
        stack.addArrangedSubview(makeSectionTitle("操作"))

        let primaryRow = UIStackView(arrangedSubviews: [downloadButton, pauseButton, retryButton])
        primaryRow.axis = .horizontal
        primaryRow.spacing = 10
        primaryRow.distribution = .fillEqually

        let secondaryRow = UIStackView(arrangedSubviews: [cancelButton, playButton, shareButton, detailButton])
        secondaryRow.axis = .horizontal
        secondaryRow.spacing = 10
        secondaryRow.distribution = .fillEqually

        stack.addArrangedSubview(primaryRow)
        stack.addArrangedSubview(secondaryRow)
        return wrapCard(stack)
    }

    private func makeCardStack() -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        return stack
    }

    private func wrapCard(_ stack: UIStackView) -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 8
        card.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])
        return card
    }

    private func makeSectionTitle(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        label.textColor = .label
        label.text = text
        return label
    }

    private func makeInfoRow(title: String, valueLabel: UILabel) -> UIStackView {
        let titleLabel = UILabel()
        titleLabel.font = UIFont.systemFont(ofSize: 14)
        titleLabel.textColor = .secondaryLabel
        titleLabel.text = title

        let row = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .firstBaseline
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private static func makeValueLabel(text: String) -> UILabel {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .label
        label.text = text
        label.textAlignment = .right
        label.numberOfLines = 0
        return label
    }

    private func makeActionButton(title: String, icon: String, color: UIColor) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(title, for: .normal)
        button.setImage(UIImage(systemName: icon), for: .normal)
        button.tintColor = .white
        button.backgroundColor = color
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.75
        button.layer.cornerRadius = 8
        button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        button.imageEdgeInsets = UIEdgeInsets(top: 0, left: -2, bottom: 0, right: 4)
        button.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return button
    }

    @objc private func urlTextDidChange() {
        updateURLDerivedFields()
    }

    @objc private func fileNameTextDidChange() {
        isFileNameEditedManually = true
    }

    private func updateURLDerivedFields() {
        let urlString = urlTextField.text ?? ""
        if !isFileNameEditedManually {
            fileNameTextField.text = urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ""
                : SingleDownloadInput.suggestedFileName(for: urlString)
        }

        if let format = VideoFormatDetector.detectFromURLString(urlString) {
            formatValueLabel.text = format.rawValue.uppercased()
        } else {
            formatValueLabel.text = urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "待识别" : "MP4"
        }
    }

    @objc private func startDownload() {
        if let task = currentTask, task.state.value == .paused {
            Task {
                do {
                    try await downloadEngine.startDownload(task: task)
                    appendDebugLog("Download resumed")
                } catch {
                    showError(error.localizedDescription)
                }
            }
            return
        }

        guard let urlString = SingleDownloadInput.normalizedURLString(for: urlTextField.text ?? "") else {
            showError(Strings.Message.enterValidURL)
            return
        }

        let requestedFileName = fileNameTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = requestedFileName?.isEmpty == false ? requestedFileName! : SingleDownloadInput.suggestedFileName(for: urlString)

        Task {
            do {
                await MainActor.run {
                    self.prepareForNewDownload(fileName: fileName, urlString: urlString)
                }

                let task = try await downloadEngine.createDownloadTask(
                    url: urlString,
                    fileName: fileName
                )

                await MainActor.run {
                    self.currentTask = task
                    self.bind(task)
                }

                try await downloadEngine.startDownload(task: task)

            } catch {
                await MainActor.run {
                    self.showError(error.localizedDescription)
                    self.updateActionButtons(for: self.currentTask?.state.value)
                    self.appendDebugLog("Error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func prepareForNewDownload(fileName: String, urlString: String) {
        cancellables.removeAll()
        currentTask = nil
        errorLabel.isHidden = true
        errorLabel.text = nil
        statusValueLabel.text = "创建中"
        progressView.progress = 0
        progressPercentLabel.text = "0%"
        sizeValueLabel.text = "--"
        speedValueLabel.text = "--"
        remainingValueLabel.text = "--"
        fileNameTextField.text = fileName
        appendDebugLog("Starting download: \(urlString)")
        updateActionButtons(for: .pending)
    }

    private func bind(_ task: any DownloadTask) {
        task.progress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.updateProgress(progress)
            }
            .store(in: &cancellables)

        task.state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateState(state, task: task)
            }
            .store(in: &cancellables)
    }

    private func updateProgress(_ progress: DownloadProgress) {
        progressView.progress = progress.progress
        progressPercentLabel.text = progress.percentage
        sizeValueLabel.text = "\(progress.formattedDownloaded) / \(progress.formattedTotal)"
        speedValueLabel.text = progress.formattedSpeed
        remainingValueLabel.text = progress.formattedRemainingTime
        appendDebugLog("Progress \(progress.percentage), speed \(progress.formattedSpeed)")
    }

    private func updateState(_ state: DownloadState, task: any DownloadTask) {
        statusValueLabel.text = state.displayText
        updateActionButtons(for: state)

        switch state {
        case .failed:
            showError(task.lastError?.localizedDescription ?? "下载失败，请检查链接后重试")
        case .completed:
            errorLabel.isHidden = true
            errorLabel.text = nil
            appendDebugLog("Download completed: \(task.completedURL?.path ?? task.fileName)")
        case .cancelled:
            appendDebugLog("Download cancelled")
        default:
            errorLabel.isHidden = true
            errorLabel.text = nil
        }
    }

    private func updateActionButtons(for state: DownloadState?) {
        downloadButton.isHidden = false
        downloadButton.setTitle(state == .paused ? Strings.Button.resume : Strings.Button.startDownload, for: .normal)
        pauseButton.isHidden = true
        cancelButton.isHidden = true
        retryButton.isHidden = true
        playButton.isHidden = true
        shareButton.isHidden = true
        detailButton.isHidden = true

        guard let state = state else { return }

        switch state {
        case .pending:
            cancelButton.isHidden = false
        case .downloading:
            downloadButton.isHidden = true
            pauseButton.isHidden = false
            cancelButton.isHidden = false
        case .paused:
            cancelButton.isHidden = false
        case .failed:
            downloadButton.isHidden = true
            retryButton.isHidden = false
            cancelButton.isHidden = false
        case .completed:
            playButton.isHidden = false
            shareButton.isHidden = false
            detailButton.isHidden = false
        case .cancelled:
            break
        }
    }

    @objc private func pauseDownload() {
        guard let task = currentTask else {
            showError(Strings.Message.noActiveTaskToPause)
            return
        }

        Task {
            await downloadEngine.pauseDownload(task: task)
            appendDebugLog("Download paused")
        }
    }

    @objc private func cancelDownload() {
        guard let task = currentTask else {
            showError(Strings.Message.noActiveTaskToCancel)
            return
        }

        Task {
            await downloadEngine.cancelDownload(task: task)
            await MainActor.run {
                self.currentTask = nil
                self.statusValueLabel.text = DownloadState.cancelled.displayText
                self.updateActionButtons(for: .cancelled)
                self.appendDebugLog("Download cancelled")
            }
        }
    }

    @objc private func retryDownload() {
        guard let task = currentTask else {
            showError(Strings.Message.noActiveTaskToRetry)
            return
        }

        guard task.state.value == .failed else {
            showError(Strings.Message.taskNotFailedCannotRetry)
            return
        }

        Task {
            do {
                await MainActor.run {
                    self.errorLabel.isHidden = true
                    self.errorLabel.text = nil
                }
                try await downloadEngine.retryDownload(task: task)
                appendDebugLog("Download retry started")
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    @objc private func playDownloadedVideo() {
        guard let completedURL = currentTask?.completedURL else {
            showError(Strings.Message.noCompletedFileToPlay)
            return
        }

        let playerVC = VideoPlayerViewController(videoURL: completedURL)
        playerVC.modalPresentationStyle = .fullScreen
        present(playerVC, animated: true)
    }

    @objc private func shareDownloadedVideo() {
        guard let completedURL = currentTask?.completedURL else {
            showError(Strings.Message.noCompletedFileToPlay)
            return
        }

        let activityVC = UIActivityViewController(activityItems: [completedURL], applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = shareButton
            popover.sourceRect = shareButton.bounds
        }
        present(activityVC, animated: true)
    }

    @objc private func showDownloadedFileDetail() {
        guard let item = makeCompletedFileItem() else {
            showError(Strings.Message.noCompletedFileToPlay)
            return
        }

        navigationController?.pushViewController(CompletedFileDetailViewController(item: item), animated: true)
    }

    private func makeCompletedFileItem() -> CompletedFileItem? {
        guard let task = currentTask,
              let completedURL = task.completedURL else {
            return nil
        }

        return CompletedFileItem(
            id: task.id,
            fileName: task.fileName,
            fileURL: completedURL,
            fileSize: storageManager.fileSize(at: completedURL),
            format: task.format,
            completedAt: task.completedAt,
            sourceURL: task.url,
            createdAt: task.createdAt,
            hasDatabaseRecord: true
        )
    }

    @objc private func toggleDebugLog() {
        debugTextView.isHidden.toggle()
        debugLogButton.setTitle(debugTextView.isHidden ? "显示调试日志" : "隐藏调试日志", for: .normal)
    }

    private func showError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.errorLabel.text = message
            self?.errorLabel.isHidden = false
            self?.appendDebugLog("Error: \(message)")
        }
    }

    private func appendDebugLog(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            let logMessage = "[\(timestamp)] \(message)\n"
            self.debugTextView.text += logMessage

            if !self.debugTextView.text.isEmpty {
                let range = NSRange(location: self.debugTextView.text.count - 1, length: 1)
                self.debugTextView.scrollRangeToVisible(range)
            }
        }
    }
}

// MARK: - UITextFieldDelegate
extension ViewController: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        if textField === fileNameTextField {
            isFileNameEditedManually = true
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

// MARK: - Usage Examples

/*
 使用示例：

 1. 下载MP4视频：
    let task = try await VideoDownloadEngine.shared.createDownloadTask(
        url: "https://example.com/video.mp4",
        fileName: "my_video.mp4"
    )
    try await VideoDownloadEngine.shared.startDownload(task: task)

 2. 下载M3U8流媒体：
    let task = try await VideoDownloadEngine.shared.createDownloadTask(
        url: "https://example.com/video.m3u8",
        fileName: "my_hls_video.mp4"
    )
    try await VideoDownloadEngine.shared.startDownload(task: task)

 3. 下载迅雷链接：
    let task = try await VideoDownloadEngine.shared.createDownloadTask(
        url: "thunder://QUFodHRwOi8vZXhhbXBsZS5jb20vdmlkZW8ubXA0Wlo=",
        fileName: "thunder_video.mp4"
    )
    try await VideoDownloadEngine.shared.startDownload(task: task)

 4. 监听进度：
    task.progress
        .receive(on: DispatchQueue.main)
        .sink { progress in
            print("Progress: \(progress.percentage)")
            print("Speed: \(progress.formattedSpeed)")
        }
        .store(in: &cancellables)

 5. 监听状态：
    task.state
        .receive(on: DispatchQueue.main)
        .sink { state in
            switch state {
            case .completed(let url):
                print("Download completed: \(url)")
            case .failed:
                print("Download failed")
            case .paused:
                print("Download paused")
            default:
                break
            }
        }
        .store(in: &cancellables)

 6. 暂停和恢复：
    await VideoDownloadEngine.shared.pauseDownload(task: task)
    try await VideoDownloadEngine.shared.startDownload(task: task)

 7. 取消下载：
    await VideoDownloadEngine.shared.cancelDownload(task: task)
 */
