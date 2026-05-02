//
//  BatchDownloadExample.swift
//  DownLoad
//
//  Created by hubin on 2026/4/30.
//

import Foundation

/// 批量下载使用示例
class BatchDownloadExample {

    static func runExample() async {
        let engine = VideoDownloadEngine.shared

        print("=== 批量下载功能示例 ===\n")

        // 1. 创建批量下载任务
        do {
            print("1. 创建批量下载任务...")
            let batchTask = try await engine.createBatchDownload(
                name: "示例视频合集",
                urls: [
                    "https://example.com/video1.mp4",
                    "https://example.com/video2.m3u8",
                    "thunder://QUFodHRwOi8vZXhhbXBsZS5jb20vdmlkZW8ubXA0Wlo="
                ],
                fileNames: ["video1.mp4", "video2.mp4", "video3.mp4"]
            )

            print("✅ 批量任务创建成功: \(batchTask.name)")
            print("   任务ID: \(batchTask.id)")
            print("   包含 \(batchTask.taskItems.count) 个子任务\n")

            // 2. 获取所有批量任务
            let allTasks = await engine.getAllBatchTasks()
            print("2. 当前批量任务总数: \(allTasks.count)\n")

            // 3. 获取批量任务进度
            if let progress = await engine.getBatchProgress(batchId: batchTask.id) {
                print("3. 任务进度信息:")
                print("   总数: \(progress.total)")
                print("   已完成: \(progress.completed)")
                print("   下载中: \(progress.downloading)")
                print("   暂停中: \(progress.paused)")
                print("   失败: \(progress.failed)\n")
            }

            // 4. 开始批量下载
            print("4. 开始批量下载...")
            try await engine.startBatchDownload(batchId: batchTask.id)
            print("✅ 批量下载已启动\n")

            // 5. 暂停批量下载
            print("5. 暂停批量下载...")
            await engine.pauseBatchDownload(batchId: batchTask.id)
            print("✅ 批量下载已暂停\n")

            // 6. 取消批量下载
            print("6. 取消批量下载...")
            await engine.cancelBatchDownload(batchId: batchTask.id)
            print("✅ 批量下载已取消\n")

            // 7. 删除批量下载
            print("7. 删除批量下载...")
            await engine.deleteBatchDownload(batchId: batchTask.id)
            print("✅ 批量下载已删除\n")

            // 8. 最终检查
            let finalTasks = await engine.getAllBatchTasks()
            print("8. 最终批量任务总数: \(finalTasks.count)")

        } catch {
            print("❌ 错误: \(error.localizedDescription)")
        }

        print("\n=== 示例完成 ===")
    }
}