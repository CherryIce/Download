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
            image: UIImage(systemName: "arrow.down.circle"),
            tag: 0
        )

        // 创建批量下载视图控制器
        let batchDownloadVC = BatchDownloadViewController()
        batchDownloadVC.title = "批量下载"
        let batchDownloadNav = UINavigationController(rootViewController: batchDownloadVC)
        batchDownloadNav.tabBarItem = UITabBarItem(
            title: "批量下载",
            image: UIImage(systemName: "rectangle.stack"),
            tag: 1
        )

        // 创建已完成文件视图控制器
        let completedFilesVC = CompletedFilesViewController()
        completedFilesVC.title = "已完成文件"
        let completedFilesNav = UINavigationController(rootViewController: completedFilesVC)
        completedFilesNav.tabBarItem = UITabBarItem(
            title: "已完成",
            image: UIImage(systemName: "doc.text"),
            tag: 2
        )

        // 创建设置视图控制器
        let settingsVC = SettingsViewController()
        settingsVC.title = "设置"
        let settingsNav = UINavigationController(rootViewController: settingsVC)
        settingsNav.tabBarItem = UITabBarItem(
            title: "设置",
            image: UIImage(systemName: "gear"),
            tag: 3
        )

        // 设置视图控制器数组
        let viewControllers = [singleDownloadNav, batchDownloadNav, completedFilesNav, settingsNav]

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
