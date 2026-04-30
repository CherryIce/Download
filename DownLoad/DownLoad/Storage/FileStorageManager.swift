//
//  FileStorageManager.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation

/// 文件存储管理器
class FileStorageManager {

    private let fileManager = FileManager.default

    /// 获取文档目录
    func documentsDirectory() -> URL {
        return fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 获取下载根目录
    func downloadsDirectory() -> URL {
        let url = documentsDirectory().appendingPathComponent(Constants.Storage.downloadsDirectoryName)
        createDirectoryIfNeeded(at: url)
        return url
    }

    /// 获取正在下载目录
    func inProgressDirectory() -> URL {
        let url = downloadsDirectory().appendingPathComponent(Constants.Storage.inProgressDirectoryName)
        createDirectoryIfNeeded(at: url)
        return url
    }

    /// 获取已完成目录
    func completedDirectory() -> URL {
        let url = downloadsDirectory().appendingPathComponent(Constants.Storage.completedDirectoryName)
        createDirectoryIfNeeded(at: url)
        return url
    }

    /// 获取缓存目录
    func cacheDirectory() -> URL {
        let url = downloadsDirectory().appendingPathComponent(Constants.Storage.cacheDirectoryName)
        createDirectoryIfNeeded(at: url)
        return url
    }

    /// 创建任务专属目录
    func createTaskDirectory(taskId: UUID) -> URL {
        let url = inProgressDirectory().appendingPathComponent(taskId.uuidString)
        createDirectoryIfNeeded(at: url)
        return url
    }

    /// 检查存储空间
    func checkAvailableSpace(requiredBytes: Int64) throws {
        let documentsURL = documentsDirectory()
        let values = try documentsURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        let availableCapacity = values.volumeAvailableCapacity ?? 0

        let requiredWithBuffer = requiredBytes + Int64(Double(requiredBytes) * 0.1) // 添加10%缓冲

        if Int64(availableCapacity) < requiredWithBuffer {
            throw StorageError.insufficientStorage(
                required: requiredWithBuffer,
                available: Int64(availableCapacity)
            )
        }
    }

    /// 获取可用存储空间
    func availableStorageSpace() -> Int64 {
        do {
            let documentsURL = documentsDirectory()
            let values = try documentsURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            return Int64(values.volumeAvailableCapacity ?? 0)
        } catch {
            Logger.error("Failed to get available storage space: \(error)")
            return 0
        }
    }

    /// 移动文件
    func moveFile(from source: URL, to destination: URL) throws {
        let destinationDir = destination.deletingLastPathComponent()
        createDirectoryIfNeeded(at: destinationDir)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        try fileManager.moveItem(at: source, to: destination)
        Logger.info("File moved from \(source.path) to \(destination.path)")
    }

    /// 删除文件
    func deleteFile(at url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
            Logger.info("File deleted at \(url.path)")
        }
    }

    /// 清理目录
    func cleanDirectory(at url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            for fileURL in contents {
                try fileManager.removeItem(at: fileURL)
            }
            Logger.info("Directory cleaned at \(url.path)")
        }
    }

    /// 获取文件大小
    func fileSize(at url: URL) -> Int64 {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            return (attributes[.size] as? Int64) ?? 0
        } catch {
            Logger.error("Failed to get file size: \(error)")
            return 0
        }
    }

    /// 获取目录大小
    func directorySize(at url: URL) -> Int64 {
        var totalSize: Int64 = 0

        do {
            let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])

            for item in contents {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory) {
                    if isDirectory.boolValue {
                        totalSize += directorySize(at: item)
                    } else {
                        totalSize += fileSize(at: item)
                    }
                }
            }
        } catch {
            Logger.error("Failed to calculate directory size: \(error)")
        }

        return totalSize
    }

    // MARK: - Private Methods

    private func createDirectoryIfNeeded(at url: URL) {
        if !fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
                Logger.debug("Directory created at \(url.path)")
            } catch {
                Logger.error("Failed to create directory at \(url.path): \(error)")
            }
        }
    }
}
