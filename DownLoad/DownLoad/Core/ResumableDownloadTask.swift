import Foundation
import Combine

final class ResumableDownloadTask: NSObject, DownloadTask {
    let id = UUID()
    let url: String
    let fileName: String
    let configuration: DownloadConfiguration
    let state = CurrentValueSubject<DownloadState, Never>(.pending)
    let progress = CurrentValueSubject<DownloadProgress, Never>(.empty)
    private(set) var completedURL: URL?
    private(set) var resumeData: Data?

    let format: VideoFormat = .mp4
    var totalSize: Int64?
    var downloadedSize: Int64 = 0
    let createdAt: Date = Date()
    var completedAt: Date?

    private var urlSessionTask: URLSessionDownloadTask?
    private var urlSession: URLSession!
    private let speedCalculator = SpeedCalculator()

    /// 暂停原因（用于区分用户手动暂停和网络自动暂停）
    var pauseReason: PauseReason? = nil

    init(url: String, fileName: String, configuration: DownloadConfiguration) {
        self.url = url
        self.fileName = fileName
        self.configuration = configuration
        super.init()
        self.urlSession = URLSession(
            configuration: .default,
            delegate: self,
            delegateQueue: nil
        )
    }

    func resume() async throws {
        // 恢复时清除暂停原因
        pauseReason = nil

        if let resumeData = resumeData {
            urlSessionTask = urlSession.downloadTask(withResumeData: resumeData)
        } else if let fileURL = URL(string: url) {
            var request = URLRequest(url: fileURL)
            let downloadedBytes = Self.localFileSize(for: fileName)
            if downloadedBytes > 0 {
                request.setValue("bytes=\(downloadedBytes)-", forHTTPHeaderField: "Range")
            }
            urlSessionTask = urlSession.downloadTask(with: request)
        }
        urlSessionTask?.resume()
        state.send(.downloading)
    }

    func pause() async {
        // 如果没有外部指定原因，默认为用户手动暂停
        if pauseReason == nil {
            pauseReason = .userInitiated
        }

        urlSessionTask?.cancel(byProducingResumeData: {[weak self] data in
            self?.resumeData = data
        })
        state.send(.paused)
    }

    func cancel() async {
        // 取消时清除暂停原因
        pauseReason = nil

        urlSessionTask?.cancel()
        state.send(.cancelled)
    }

    /// 带原因的暂停（供网络监控使用）
    func pause(reason: PauseReason) async {
        pauseReason = reason
        Logger.info("Resumable task \(id) paused due to: \(reason.rawValue)")
        await pause()
    }

    static private func localFileSize(for filename: String) -> Int64 {
        let fileURL = FileStorageManager().completedDirectory().appendingPathComponent(filename)
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return attrs?[.size] as? Int64 ?? 0
    }
}

extension ResumableDownloadTask: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        self.totalSize = totalBytesExpectedToWrite
        self.downloadedSize = totalBytesWritten

        let now = Date().timeIntervalSince1970
        speedCalculator.addSample(bytes: totalBytesWritten, timestamp: now)
        let speed = speedCalculator.calculateSpeed()
        let remaining = speedCalculator.calculateRemainingTime(totalBytes: totalBytesExpectedToWrite, downloadedBytes: totalBytesWritten)

        progress.send(DownloadProgress(
            taskId: id,
            totalBytes: totalBytesExpectedToWrite,
            downloadedBytes: totalBytesWritten,
            progress: totalBytesExpectedToWrite > 0 ? Float(totalBytesWritten)/Float(totalBytesExpectedToWrite) : 0,
            speed: speed,
            remainingTime: remaining
        ))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let destURL = FileStorageManager().completedDirectory().appendingPathComponent(fileName)
        try? FileManager.default.moveItem(at: location, to: destURL)
        completedURL = destURL
        completedAt = Date()
        state.send(.completed)
    }
}
