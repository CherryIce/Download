//
//  VideoPlayerViewController.swift
//  DownLoad
//

import UIKit
import AVKit

/// 视频播放器视图控制器
/// 封装 AVPlayerViewController，提供全屏播放、错误处理和播放完成监听
class VideoPlayerViewController: UIViewController {

    // MARK: - Properties
    private let videoURL: URL
    private var playerViewController: AVPlayerViewController?

    // MARK: - Initialization
    init(videoURL: URL) {
        self.videoURL = videoURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupPlayer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 页面消失时停止播放，释放资源
        playerViewController?.player?.pause()
        playerViewController?.player = nil
    }

    // MARK: - Setup
    private func setupPlayer() {
        // 创建播放器
        let player = AVPlayer(url: videoURL)

        // 创建 AVPlayerViewController
        let playerVC = AVPlayerViewController()
        playerVC.player = player
        playerVC.showsPlaybackControls = true
        playerVC.allowsPictureInPicturePlayback = true
        playerVC.videoGravity = .resizeAspect

        self.playerViewController = playerVC

        // 添加为子视图控制器
        addChild(playerVC)
        view.addSubview(playerVC.view)
        playerVC.view.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            playerVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            playerVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        playerVC.didMove(toParent: self)

        // 监听播放完成
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinishPlaying),
            name: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem
        )

        // 监听播放失败
        player.currentItem?.addObserver(
            self,
            forKeyPath: #keyPath(AVPlayerItem.status),
            options: [.new, .initial],
            context: nil
        )

        // 自动开始播放
        player.play()
    }

    // MARK: - Actions
    @objc private func playerDidFinishPlaying() {
        Logger.info("视频播放完成: \(videoURL.lastPathComponent)")
        // 播放完成后自动退出
        dismiss(animated: true)
    }

    // MARK: - KVO
    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        if keyPath == #keyPath(AVPlayerItem.status) {
            guard let playerItem = object as? AVPlayerItem else { return }

            DispatchQueue.main.async { [weak self] in
                switch playerItem.status {
                case .failed:
                    self?.handlePlaybackError(playerItem.error)
                case .readyToPlay:
                    Logger.info("视频准备就绪，开始播放: \(self?.videoURL.lastPathComponent ?? "")")
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    // MARK: - Error Handling
    private func handlePlaybackError(_ error: Error?) {
        let errorMessage: String
        if let error = error {
            errorMessage = "播放失败: \(error.localizedDescription)"
        } else {
            errorMessage = "无法播放该视频文件，格式可能不受支持或文件已损坏"
        }

        Logger.error(errorMessage)

        let alert = UIAlertController(
            title: "播放失败",
            message: errorMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }

    deinit {
        // 移除 KVO 监听
        playerViewController?.player?.currentItem?.removeObserver(
            self,
            forKeyPath: #keyPath(AVPlayerItem.status)
        )
        NotificationCenter.default.removeObserver(self)
    }
}
