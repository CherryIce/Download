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

    private var urlSessionTask: URLSessionDownloadTask?
    private var urlSession: URLSession!

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
        urlSessionTask?.cancel(byProducingResumeData: {[weak self] data in
            self?.resumeData = data
        })
        state.send(.paused)
    }

    func cancel() async {
        urlSessionTask?.cancel()
        state.send(.cancelled)
    }

    static private func localFileSize(for filename: String) -> Int64 {
        let fileURL = FileStorageManager().completedDirectory().appendingPathComponent(filename)
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return attrs?[.size] as? Int64 ?? 0
    }
}

extension ResumableDownloadTask: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress.send(DownloadProgress(
            taskId: id,
            totalBytes: totalBytesExpectedToWrite,
            downloadedBytes: totalBytesWritten,
            progress: totalBytesExpectedToWrite > 0 ? Float(totalBytesWritten)/Float(totalBytesExpectedToWrite) : 0,
            speed: 0,
            remainingTime: nil
        ))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let destURL = FileStorageManager().completedDirectory().appendingPathComponent(fileName)
        try? FileManager.default.moveItem(at: location, to: destURL)
        completedURL = destURL
        state.send(.completed)
    }
}
