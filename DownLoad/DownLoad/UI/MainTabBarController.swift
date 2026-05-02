import UIKit

/// 主标签控制器
class MainTabBarController: UITabBarController {

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTabBarController()
    }

    private func setupTabBarController() {
        // 创建单个下载视图控制器
        let singleDownloadVC = ViewController()
        singleDownloadVC.title = "单任务下载"
        let singleDownloadNav = UINavigationController(rootViewController: singleDownloadVC)
        singleDownloadNav.tabBarItem = UITabBarItem(
            title: "单任务下载",
            image: UIImage(systemName: "rectangle.stack"),
            tag: 0
        )

        // 创建视频下载管理视图控制器
        let videoDownloadManagerVC = VideoDownloadManagerViewController()
        videoDownloadManagerVC.title = "下载管理"
        let videoDownloadManagerNav = UINavigationController(rootViewController: videoDownloadManagerVC)
        videoDownloadManagerNav.tabBarItem = UITabBarItem(
            title: "下载管理",
            image: UIImage(systemName: "list.bullet"),
            tag: 1
        )

        // 创建批量下载视图控制器
        let batchDownloadVC = BatchDownloadViewController()
        batchDownloadVC.title = "批量下载"
        let batchDownloadNav = UINavigationController(rootViewController: batchDownloadVC)
        batchDownloadNav.tabBarItem = UITabBarItem(
            title: "批量下载",
            image: UIImage(systemName: "rectangle.stack"),
            tag: 2
        )

        // 设置视图控制器数组
        let viewControllers = [singleDownloadNav, videoDownloadManagerNav, batchDownloadNav]

        // 设置标签栏控制器
        self.viewControllers = viewControllers
        self.selectedIndex = 0

        // 设置标签栏样式
        tabBar.barTintColor = .systemBackground
        tabBar.tintColor = .systemBlue

        // 设置标签栏标题样式
        if let items = tabBar.items {
            for item in items {
                item.setTitleTextAttributes([
                    .font: UIFont.systemFont(ofSize: 12, weight: .medium)
                ], for: .normal)
            }
        }
    }
}
