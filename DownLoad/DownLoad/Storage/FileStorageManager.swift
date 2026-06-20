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
        let cacheDir = cacheDirectory()
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
            Logger.error("Failed to get cache file age: \(error)")
        }
        return nil
    }

    /// 清理过期缓存文件
    /// - Returns: 清理的文件数量和释放的总字节数
    func cleanExpiredCache() -> (deletedCount: Int, freedBytes: Int64) {
        let cacheDir = cacheDirectory()
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

        Logger.info("Cleaned expired cache: \(deletedCount) files, freed \(ByteCountFormatter.string(fromByteCount: freedBytes, countStyle: .file))")
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
                        Logger.info("Deleted expired cache file: \(fileURL.lastPathComponent)")
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

        let cacheDir = cacheDirectory()

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
                Logger.info("Deleted cache file for size limit: \(file.url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)))")
            } catch {
                Logger.error("Failed to delete cache file \(file.url.path): \(error)")
            }
        }

        Logger.info("Enforced cache size limit: \(deletedCount) files deleted, \(ByteCountFormatter.string(fromByteCount: freedBytes, countStyle: .file)) freed")
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
        Logger.info("Starting full cache cleanup...")

        let expiredResult = cleanExpiredCache()
        let sizeResult = enforceCacheSizeLimit()

        let totalDeleted = expiredResult.deletedCount + sizeResult.deletedCount
        let totalFreed = expiredResult.freedBytes + sizeResult.freedBytes

        Logger.info("Full cache cleanup completed: \(totalDeleted) files deleted, \(ByteCountFormatter.string(fromByteCount: totalFreed, countStyle: .file)) freed")
        return (totalDeleted, totalFreed)
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
