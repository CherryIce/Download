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
    func downloadsDirectory() throws -> URL {
        let url = documentsDirectory().appendingPathComponent(Constants.Storage.downloadsDirectoryName)
        try createDirectoryIfNeeded(at: url)
        return url
    }

    /// 获取正在下载目录
    func inProgressDirectory() throws -> URL {
        let url = try downloadsDirectory().appendingPathComponent(Constants.Storage.inProgressDirectoryName)
        try createDirectoryIfNeeded(at: url)
        return url
    }

    /// 获取已完成目录
    func completedDirectory() throws -> URL {
        let url = try downloadsDirectory().appendingPathComponent(Constants.Storage.completedDirectoryName)
        try createDirectoryIfNeeded(at: url)
        return url
    }

    /// 获取缓存目录
    func cacheDirectory() throws -> URL {
        let url = try downloadsDirectory().appendingPathComponent(Constants.Storage.cacheDirectoryName)
        try createDirectoryIfNeeded(at: url)
        return url
    }

    /// 创建任务专属目录
    func createTaskDirectory(taskId: UUID) throws -> URL {
        let url = try inProgressDirectory().appendingPathComponent(taskId.uuidString)
        try createDirectoryIfNeeded(at: url)
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
            AppLogger.error("Failed to get available storage space: \(error)")
            return 0
        }
    }

    /// 移动文件
    func moveFile(from source: URL, to destination: URL) throws {
        let destinationDir = destination.deletingLastPathComponent()
        try createDirectoryIfNeeded(at: destinationDir)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        try fileManager.moveItem(at: source, to: destination)
        AppLogger.info("File moved from \(source.path) to \(destination.path)")
    }

    /// 删除文件
    func deleteFile(at url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
            AppLogger.info("File deleted at \(url.path)")
        }
    }

    /// 清理目录
    func cleanDirectory(at url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            for fileURL in contents {
                try fileManager.removeItem(at: fileURL)
            }
            AppLogger.info("Directory cleaned at \(url.path)")
        }
    }

    /// 获取文件大小
    func fileSize(at url: URL) -> Int64 {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            return (attributes[.size] as? Int64) ?? 0
        } catch {
            AppLogger.error("Failed to get file size: \(error)")
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
            AppLogger.error("Failed to calculate directory size: \(error)")
        }

        return totalSize
    }

    // MARK: - Private Methods

    private func createDirectoryIfNeeded(at url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
                AppLogger.debug("Directory created at \(url.path)")
            } catch {
                throw StorageError.directoryCreationFailed(url.path)
            }
        }
    }
}

// MARK: - Storage Space Monitoring

extension FileStorageManager {
    /// 检查是否有足够空间用于继续下载
    /// - Parameters:
    ///   - requiredBytes: 还需要下载的字节数
    ///   - bufferRatio: 缓冲比例（默认10%）
    /// - Returns: 是否有足够空间
    func hasEnoughSpaceForContinue(requiredBytes: Int64, bufferRatio: Double = 0.1) -> Bool {
        let requiredWithBuffer = requiredBytes + Int64(Double(requiredBytes) * bufferRatio)
        let available = availableStorageSpace()
        return available >= requiredWithBuffer
    }

    /// 获取指定任务还需要的存储空间
    func requiredSpaceForTask(totalSize: Int64?, downloadedSize: Int64) -> Int64 {
        guard let total = totalSize else {
            return Constants.Storage.defaultMP4SpaceRequirement
        }
        return max(0, total - downloadedSize)
    }
}

// MARK: - Cache Management

extension FileStorageManager {
    /// 获取缓存目录总大小（字节）
    func getCacheSize() -> Int64 {
        guard let cacheDir = try? cacheDirectory() else {
            AppLogger.error("Failed to access cache directory")
            return 0
        }
        return directorySize(at: cacheDir)
    }

    /// 获取缓存文件年龄（天数）
    func getCacheFileAge(_ url: URL) -> Int? {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            if let modificationDate = attributes[.modificationDate] as? Date {
                let age = Date().timeIntervalSince(modificationDate)
                return Int(age / (24 * 60 * 60))
            }
        } catch {
            AppLogger.error("Failed to get cache file age: \(error)")
        }
        return nil
    }

    /// 清理过期缓存文件
    /// - Returns: 清理的文件数量和释放的总字节数
    func cleanExpiredCache() -> (deletedCount: Int, freedBytes: Int64) {
        guard let cacheDir = try? cacheDirectory() else {
            AppLogger.error("Failed to access cache directory for cleanup")
            return (0, 0)
        }
        var deletedCount = 0
        var freedBytes: Int64 = 0

        guard fileManager.fileExists(atPath: cacheDir.path) else {
            return (0, 0)
        }

        let expirationInterval = TimeInterval(Constants.Storage.cacheExpirationDays * 24 * 60 * 60)
        let now = Date()

        let result = cleanExpiredCache(in: cacheDir, expirationInterval: expirationInterval, now: now)
        deletedCount += result.deletedCount
        freedBytes += result.freedBytes

        AppLogger.info("Cleaned expired cache: \(deletedCount) files, freed \(ByteCountFormatter.string(fromByteCount: freedBytes, countStyle: .file))")
        return (deletedCount, freedBytes)
    }

    /// 递归清理指定目录中的过期缓存
    private func cleanExpiredCache(in directory: URL, expirationInterval: TimeInterval, now: Date) -> (deletedCount: Int, freedBytes: Int64) {
        var deletedCount = 0
        var freedBytes: Int64 = 0

        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return (0, 0)
        }

        for fileURL in contents {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                let subResult = cleanExpiredCache(in: fileURL, expirationInterval: expirationInterval, now: now)
                deletedCount += subResult.deletedCount
                freedBytes += subResult.freedBytes

                // 删除空目录
                if let subContents = try? fileManager.contentsOfDirectory(at: fileURL, includingPropertiesForKeys: nil),
                   subContents.isEmpty {
                    try? fileManager.removeItem(at: fileURL)
                }
            } else {
                if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                   let modificationDate = attributes[.modificationDate] as? Date {
                    if now.timeIntervalSince(modificationDate) > expirationInterval {
                        let fileSize = self.fileSize(at: fileURL)
                        try? fileManager.removeItem(at: fileURL)
                        freedBytes += fileSize
                        deletedCount += 1
                        AppLogger.info("Deleted expired cache file: \(fileURL.lastPathComponent)")
                    }
                }
            }
        }

        return (deletedCount, freedBytes)
    }

    /// 强制缓存大小限制（LRU策略：按最久未访问顺序删除）
    /// - Returns: 删除的文件数量和释放的总字节数
    func enforceCacheSizeLimit() -> (deletedCount: Int, freedBytes: Int64) {
        let maxSize = Constants.Storage.maxCacheSize
        let currentSize = getCacheSize()

        guard currentSize > maxSize else {
            return (0, 0)
        }

        let targetSize = Int64(Double(maxSize) * 0.8) // 清理到80%阈值
        var bytesToFree = currentSize - targetSize
        var deletedCount = 0
        var freedBytes: Int64 = 0

        let cacheDir: URL
        if let dir = try? cacheDirectory() {
            cacheDir = dir
        } else {
            AppLogger.error("Failed to access cache directory for size limit enforcement")
            return (0, 0)
        }

        // 收集所有缓存文件及其访问时间
        var files: [(url: URL, modificationDate: Date, size: Int64)] = []
        collectCacheFiles(in: cacheDir, into: &files)

        // 按修改时间排序（最久未访问的在前）
        files.sort { $0.modificationDate < $1.modificationDate }

        // 删除最久未访问的文件直到低于阈值
        for file in files {
            guard bytesToFree > 0 else { break }

            do {
                try fileManager.removeItem(at: file.url)
                freedBytes += file.size
                bytesToFree -= file.size
                deletedCount += 1
                AppLogger.info("Deleted cache file for size limit: \(file.url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)))")
            } catch {
                AppLogger.error("Failed to delete cache file \(file.url.path): \(error)")
            }
        }

        AppLogger.info("Enforced cache size limit: \(deletedCount) files deleted, \(ByteCountFormatter.string(fromByteCount: freedBytes, countStyle: .file)) freed")
        return (deletedCount, freedBytes)
    }

    /// 递归收集缓存文件信息
    private func collectCacheFiles(in directory: URL, into files: inout [(url: URL, modificationDate: Date, size: Int64)]) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for fileURL in contents {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                collectCacheFiles(in: fileURL, into: &files)
            } else {
                if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                   let modificationDate = attributes[.modificationDate] as? Date {
                    let size = fileSize(at: fileURL)
                    files.append((url: fileURL, modificationDate: modificationDate, size: size))
                }
            }
        }
    }

    /// 执行完整缓存清理（先清理过期，再强制大小限制）
    /// - Returns: 清理结果汇总
    func performFullCacheCleanup() -> (deletedCount: Int, freedBytes: Int64) {
        AppLogger.info("Starting full cache cleanup...")

        let expiredResult = cleanExpiredCache()
        let sizeResult = enforceCacheSizeLimit()

        let totalDeleted = expiredResult.deletedCount + sizeResult.deletedCount
        let totalFreed = expiredResult.freedBytes + sizeResult.freedBytes

        AppLogger.info("Full cache cleanup completed: \(totalDeleted) files deleted, \(ByteCountFormatter.string(fromByteCount: totalFreed, countStyle: .file)) freed")
        return (totalDeleted, totalFreed)
    }
}

// MARK: - Completed Files Enumeration

extension FileStorageManager {
    /// 枚举已完成目录中的所有文件
    /// - Returns: 文件 URL 数组（按修改时间降序）
    func enumerateCompletedFiles() -> [URL] {
        guard let completedDir = try? completedDirectory() else {
            AppLogger.error("Failed to access completed directory")
            return []
        }
        guard let contents = try? fileManager.contentsOfDirectory(
            at: completedDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        // 过滤掉目录，只保留文件
        let files = contents.filter { url in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }

        // 按修改时间降序排序（最新的在前）
        return files.sorted { a, b in
            let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            return dateA > dateB
        }
    }

    /// 获取已完成目录中的文件数量
    func completedFileCount() -> Int {
        return enumerateCompletedFiles().count
    }
}

// MARK: - JSON Persistence Helpers

extension FileStorageManager {
    /// 保存 Codable 对象为 JSON 文件
    func saveJSON<T: Codable>(_ object: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(object)
        try data.write(to: url, options: .atomic)
    }

    /// 从 JSON 文件加载 Codable 对象
    func loadJSON<T: Codable>(from url: URL, as type: T.Type) throws -> T {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
