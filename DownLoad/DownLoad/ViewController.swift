//
//  ViewController.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import UIKit
import Combine

class ViewController: UIViewController {

    private let downloadEngine = VideoDownloadEngine.shared
    private var cancellables = Set<AnyCancellable>()
    private var currentTask: (any DownloadTask)?

    private let textView: UITextView = {
        let tv = UITextView()
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.isEditable = false
        tv.font = UIFont.systemFont(ofSize: 14)
        tv.backgroundColor = .systemBackground
        return tv
    }()

    private let downloadButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Start Download", for: .normal)
        button.backgroundColor = .systemBlue
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
        return button
    }()

    private let pauseButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Pause", for: .normal)
        button.backgroundColor = .systemOrange
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
        return button
    }()

    private let cancelButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Cancel", for: .normal)
        button.backgroundColor = .systemRed
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
        return button
    }()

    private let stackView: UIStackView = {
        let sv = UIStackView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.axis = .vertical
        sv.spacing = 12
        sv.distribution = .fillEqually
        return sv
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    private func setupUI() {
        view.backgroundColor = .systemBackground

        // Add subviews
        view.addSubview(textView)
        view.addSubview(stackView)

        stackView.addArrangedSubview(downloadButton)
        stackView.addArrangedSubview(pauseButton)
        stackView.addArrangedSubview(cancelButton)

        // Setup constraints
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            textView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.5),

            stackView.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 20),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stackView.heightAnchor.constraint(equalToConstant: 150)
        ])

        // Setup actions
        downloadButton.addTarget(self, action: #selector(startDownload), for: .touchUpInside)
        pauseButton.addTarget(self, action: #selector(pauseDownload), for: .touchUpInside)
        cancelButton.addTarget(self, action: #selector(cancelDownload), for: .touchUpInside)
    }

    @objc private func startDownload() {
        log("Starting download...")

        Task {
            do {
                // 示例1: 下载MP4
                // let task = try await downloadEngine.createDownloadTask(
                //     url: "https://example.com/video.mp4",
                //     fileName: "my_video.mp4"
                // )

                // 示例2: 下载M3U8
                // let task = try await downloadEngine.createDownloadTask(
                //     url: "https://example.com/video.m3u8",
                //     fileName: "my_hls_video.mp4"
                // )

                // 示例3: 下载迅雷链接
                // let task = try await downloadEngine.createDownloadTask(
                //     url: "thunder://QUFodHRwOi8vZXhhbXBsZS5jb20vdmlkZW8ubXA0Wlo=",
                //     fileName: "thunder_video.mp4"
                // )

                // 使用示例URL（实际使用时替换为真实URL）
                let task = try await downloadEngine.createDownloadTask(
                    url: "https://example.com/sample.mp4",
                    fileName: "sample_video.mp4"
                )

                currentTask = task

                // 监听进度
                task.progress
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] progress in
                        self?.log("Progress: \(progress.percentage)")
                        self?.log("Downloaded: \(progress.formattedDownloaded)")
                        self?.log("Speed: \(progress.formattedSpeed)")
                    }
                    .store(in: &cancellables)

                // 监听状态
                task.state
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] state in
                        self?.log("State: \(state.rawValue)")

                        switch state {
                        case .completed:
                            let path = self?.currentTask?.completedURL?.path ?? "unknown"
                            self?.log("✅ Download completed: \(path)")
                        case .failed:
                            self?.log("❌ Download failed")
                        case .cancelled:
                            self?.log("⚠️ Download cancelled")
                        default:
                            break
                        }
                    }
                    .store(in: &cancellables)

                // 开始下载
                try await downloadEngine.startDownload(task: task)

            } catch {
                log("❌ Error: \(error.localizedDescription)")
            }
        }
    }

    @objc private func pauseDownload() {
        guard let task = currentTask else {
            log("No active task to pause")
            return
        }

        Task {
            await downloadEngine.pauseDownload(task: task)
            log("Download paused")
        }
    }

    @objc private func cancelDownload() {
        guard let task = currentTask else {
            log("No active task to cancel")
            return
        }

        Task {
            await downloadEngine.cancelDownload(task: task)
            log("Download cancelled")
            currentTask = nil
        }
    }

    private func log(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            let logMessage = "[\(timestamp)] \(message)\n"
            self.textView.text += logMessage

            // Scroll to bottom
            let range = NSRange(location: self.textView.text.count - 1, length: 1)
            self.textView.scrollRangeToVisible(range)
        }
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
