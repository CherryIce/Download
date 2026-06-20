# P2 缺陷修复实现计划（问题 25-32）

> **目标：** 修复缺陷优先级排序文档中 P2 级别的问题 25-32，提升用户体验。
> **架构：** 以 UI 层和配置层修复为主，少量涉及业务逻辑层。保持现有架构不变，在现有代码基础上增量修改。
> **技术栈：** Swift, UIKit, Combine, UserDefaults

---

## 当前状态分析

- `ViewController.swift`：单任务下载页面，硬编码示例 URL，用户无法输入自定义链接。
- `BatchDownloadViewController.swift`：批量下载页面，仅支持创建/删除，无暂停/恢复/重试操作；使用 2 秒定时器轮询刷新，体验不流畅。
- `BatchDownloadCell.swift`：Cell 信息展示不足，缺少速度/剩余时间/文件大小；状态文字直接显示英文 `rawValue`。
- `MainTabBarController.swift`："下载管理"和"批量下载"两个 Tab 完全重复，都是 `BatchDownloadViewController` 实例。
- `Info.plist`：`NSAllowsArbitraryLoads = true`，ATS 全局禁用，App Store 审核风险。
- `Constants.swift` / `DownloadConfiguration.swift`：所有参数硬编码，无用户可调入口。
- `DownloadTaskProtocol.swift`：`DownloadTask` 协议已暴露 `downloadedSize` 和 `totalSize` 属性（`Int64`），问题 28 可直接使用。
- `BatchDownloadManager`：已提供 `pauseBatchDownload`、`startBatchDownload`、`cancelBatchDownload`、`retryFailedItems` 方法，问题 26 只需在 UI 层调用。
- `DownloadNotification`：已定义 `progressDidUpdate` 和 `stateDidChange` 通知，问题 27 可直接使用。

---

## 任务分解与执行顺序

| 顺序 | 任务 | 依赖 |
|------|------|------|
| 1 | 问题 29：状态中文显示 | 无 |
| 2 | 问题 32：ATS 配置修复 | 无 |
| 3 | 问题 25：URL 输入框 | 无 |
| 4 | 问题 30：设置页面 | 无 |
| 5 | 问题 31：Tab 重复修复 | 依赖问题 30 |
| 6 | 问题 28：Cell 信息展示 | 依赖问题 29 |
| 7 | 问题 26：暂停/恢复/重试 | 依赖问题 28 |
| 8 | 问题 27：实时进度刷新 | 依赖问题 26 |

---

## 任务 1：问题 29 - 状态文字显示中文

**文件：**
- 修改：`/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/Core/BatchDownloadManager.swift`
- 修改：`/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/Models/DownloadState.swift`
- 修改：`/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/UI/BatchDownloadCell.swift`
- 修改：`/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/ViewController.swift`

- [ ] **步骤 1：为 `BatchState` 添加中文显示属性**

在 `BatchDownloadManager.swift` 的 `BatchState` 枚举中添加：

```swift
var displayText: String {
    switch self {
    case .pending: return "等待中"
    case .downloading: return "下载中"
    case .paused: return "已暂停"
    case .completed: return "已完成"
    case .failed: return "失败"
    case .partiallyFailed: return "部分失败"
    case .cancelled: return "已取消"
    }
}
```

- [ ] **步骤 2：为 `DownloadState` 添加中文显示属性**

在 `DownloadState.swift` 中添加：

```swift
var displayText: String {
    switch self {
    case .pending: return "等待中"
    case .downloading: return "下载中"
    case .paused: return "已暂停"
    case .completed: return "已完成"
    case .failed: return "失败"
    case .cancelled: return "已取消"
    }
}
```

- [ ] **步骤 3：修改 Cell 状态显示**

在 `BatchDownloadCell.swift` 的 `configure(with:)` 方法中，将：

```swift
statusLabel.text = batchTask.state.rawValue
```

改为：

```swift
statusLabel.text = batchTask.state.displayText
```

- [ ] **步骤 4：修改单任务页状态日志**

在 `ViewController.swift` 的状态监听中，将：

```swift
self?.log("State: \(state.rawValue)")
```

改为：

```swift
self?.log("State: \(state.displayText)")
```

- [ ] **步骤 5：编译验证**

Run: `xcodebuild -project /Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad.xcodeproj -scheme DownLoad -destination 'platform=iOS Simulator,name=iPhone 15'`
Expected: 编译通过

---

## 任务 2：问题 32 - ATS 全局禁用修复

**文件：**
- 修改：`/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/Info.plist`

- [ ] **步骤 1：修改 ATS 配置**

将 `Info.plist` 中的：

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>
```

替换为：

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <false/>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

- [ ] **步骤 2：编译验证**

Run: `xcodebuild -project /Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad.xcodeproj -scheme DownLoad -destination 'platform=iOS Simulator,name=iPhone 15'`
Expected: 编译通过

---

## 任务 3：问题 25 - URL 输入框

**文件：**
- 修改：`/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/ViewController.swift`

- [ ] **步骤 1：添加 URL 输入框属性**

在 `ViewController` 的 UI 组件区域（`textView` 之前）添加：

```swift
private let urlTextField: UITextField = {
    let tf = UITextField()
    tf.translatesAutoresizingMaskIntoConstraints = false
    tf.placeholder = "请输入下载URL"
    tf.borderStyle = .roundedRect
    tf.autocorrectionType = .no
    tf.autocapitalizationType = .none
    tf.keyboardType = .URL
    tf.returnKeyType = .done
    tf.clearButtonMode = .whileEditing
    tf.text = "https://example.com/sample.mp4"
    return tf
}()
```

- [ ] **步骤 2：修改 `setupUI()` 添加输入框**

在 `view.addSubview(textView)` 之前添加：

```swift
view.addSubview(urlTextField)
```

修改约束，在原有 `textView` 约束之前插入 `urlTextField` 约束，并将 `textView.topAnchor` 改为依赖 `urlTextField.bottomAnchor`：

```swift
urlTextField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
urlTextField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
urlTextField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
urlTextField.heightAnchor.constraint(equalToConstant: 44),

textView.topAnchor.constraint(equalTo: urlTextField.bottomAnchor, constant: 12),
```

在 `setupUI()` 末尾添加键盘收起处理：

```swift
urlTextField.delegate = self
let tapGesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
view.addGestureRecognizer(tapGesture)
```

- [ ] **步骤 3：添加 UITextFieldDelegate 扩展**

在文件末尾（`Usage Examples` 注释块之前）添加：

```swift
extension ViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }
}
```

- [ ] **步骤 4：修改 `startDownload()` 读取输入框 URL**

将 `startDownload()` 方法替换为：

```swift
@objc private func startDownload() {
    guard let urlString = urlTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
          !urlString.isEmpty,
          URL(string: urlString) != nil else {
        log("请输入有效的URL")
        return
    }

    log("Starting download: \(urlString)")

    Task {
        do {
            let task = try await downloadEngine.createDownloadTask(
                url: urlString,
                fileName: "sample_video.mp4"
            )
            currentTask = task

            task.progress
                .receive(on: DispatchQueue.main)
                .sink { [weak self] progress in
                    self?.log("Progress: \(progress.percentage)")
                    self?.log("Downloaded: \(progress.formattedDownloaded)")
                    self?.log("Speed: \(progress.formattedSpeed)")
                }
                .store(in: &cancellables)

            task.state
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    self?.log("State: \(state.displayText)")

                    switch state {
                    case .completed:
                        let path = self?.currentTask?.completedURL?.path ?? "unknown"
                        self?.log("下载完成: \(path)")
                    case .failed:
                        self?.log("下载失败")
                    case .cancelled:
                        self?.log("下载已取消")
                    default:
                        break
                    }
                }
                .store(in: &cancellables)

            try await downloadEngine.startDownload(task: task)

        } catch {
            log("错误: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **步骤 5：编译验证**

Run: `xcodebuild -project /Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad.xcodeproj -scheme DownLoad -destination 'platform=iOS Simulator,name=iPhone 15'`
Expected: 编译通过

---

## 任务 4：问题 30 - 设置页面

**文件：**
- 新建：`/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/UI/SettingsViewController.swift`
- 修改：`/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/Utilities/DownloadConfiguration.swift`

- [ ] **步骤 1：创建 `SettingsViewController.swift`**

```swift
import UIKit

/// 设置页面
class SettingsViewController: UIViewController {

    // MARK: - UserDefaults Keys
    private enum UserDefaultsKey {
        static let maxConcurrentDownloads = "settings.maxConcurrentDownloads"
        static let timeoutInterval = "settings.timeoutInterval"
        static let retryCount = "settings.retryCount"
        static let allowCellularDownload = "settings.allowCellularDownload"
        static let enableBackgroundDownload = "settings.enableBackgroundDownload"
    }

    // MARK: - UI Components
    private lazy var tableView: UITableView = {
        let tv = UITableView(style: .grouped)
        tv.dataSource = self
        tv.delegate = self
        tv.translatesAutoresizingMaskIntoConstraints = false
        return tv
    }()

    // MARK: - Settings Model
    private struct SettingItem {
        let title: String
        let key: String
        let type: SettingType
    }

    private enum SettingType {
        case slider(Int, Int, String)
        case sliderDouble(Double, Double, Double, String)
        case toggle
    }

    private let settings: [[SettingItem]] = [
        [
            SettingItem(title: "最大并发下载数", key: UserDefaultsKey.maxConcurrentDownloads, type: .slider(1, 10, "个")),
            SettingItem(title: "请求超时时间", key: UserDefaultsKey.timeoutInterval, type: .sliderDouble(5, 120, 5, "秒")),
            SettingItem(title: "重试次数", key: UserDefaultsKey.retryCount, type: .slider(0, 10, "次"))
        ],
        [
            SettingItem(title: "允许蜂窝网络下载", key: UserDefaultsKey.allowCellularDownload, type: .toggle),
            SettingItem(title: "启用后台下载", key: UserDefaultsKey.enableBackgroundDownload, type: .toggle)
        ]
    ]

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    private func setupUI() {
        title = "设置"
        view.backgroundColor = .systemBackground
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    // MARK: - Static Helpers
    static func getMaxConcurrentDownloads() -> Int {
        let value = UserDefaults.standard.integer(forKey: UserDefaultsKey.maxConcurrentDownloads)
        return value > 0 ? value : Constants.Network.maxConcurrentDownloads
    }

    static func getTimeoutInterval() -> TimeInterval {
        let value = UserDefaults.standard.double(forKey: UserDefaultsKey.timeoutInterval)
        return value > 0 ? value : Constants.Network.timeoutInterval
    }

    static func getRetryCount() -> Int {
        if UserDefaults.standard.object(forKey: UserDefaultsKey.retryCount) == nil {
            return Constants.Network.maxRetryCount
        }
        return UserDefaults.standard.integer(forKey: UserDefaultsKey.retryCount)
    }

    static func getAllowCellularDownload() -> Bool {
        if UserDefaults.standard.object(forKey: UserDefaultsKey.allowCellularDownload) == nil {
            return Constants.NetworkMonitor.defaultAllowCellularDownload
        }
        return UserDefaults.standard.bool(forKey: UserDefaultsKey.allowCellularDownload)
    }

    static func getEnableBackgroundDownload() -> Bool {
        if UserDefaults.standard.object(forKey: UserDefaultsKey.enableBackgroundDownload) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: UserDefaultsKey.enableBackgroundDownload)
    }
}

// MARK: - UITableViewDataSource
extension SettingsViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return settings.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return settings[section].count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = settings[indexPath.section][indexPath.row]
        let cell = UITableViewCell(style: .value1, reuseIdentifier: "SettingCell")
        cell.textLabel?.text = item.title

        switch item.type {
        case .slider(let min, let max, let unit):
            let value = UserDefaults.standard.integer(forKey: item.key)
            let displayValue = value > 0 ? value : min
            cell.detailTextLabel?.text = "\(displayValue) \(unit)"
            cell.accessoryType = .disclosureIndicator

        case .sliderDouble(let min, _, _, let unit):
            let value = UserDefaults.standard.double(forKey: item.key)
            let displayValue = value > 0 ? value : min
            cell.detailTextLabel?.text = String(format: "%.0f %@", displayValue, unit)
            cell.accessoryType = .disclosureIndicator

        case .toggle:
            let toggle = UISwitch()
            toggle.isOn = getToggleValue(for: item.key)
            toggle.tag = indexPath.section * 100 + indexPath.row
            toggle.addTarget(self, action: #selector(toggleChanged(_:)), for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        }

        return cell
    }

    private func getToggleValue(for key: String) -> Bool {
        switch key {
        case UserDefaultsKey.allowCellularDownload:
            return SettingsViewController.getAllowCellularDownload()
        case UserDefaultsKey.enableBackgroundDownload:
            return SettingsViewController.getEnableBackgroundDownload()
        default:
            return true
        }
    }

    @objc private func toggleChanged(_ sender: UISwitch) {
        let section = sender.tag / 100
        let row = sender.tag % 100
        let item = settings[section][row]
        UserDefaults.standard.set(sender.isOn, forKey: item.key)
    }
}

// MARK: - UITableViewDelegate
extension SettingsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = settings[indexPath.section][indexPath.row]

        switch item.type {
        case .slider(let min, let max, let unit):
            showSliderAlert(item: item, min: min, max: max, unit: unit, isDouble: false)

        case .sliderDouble(let min, let max, let step, let unit):
            showSliderAlert(item: item, min: Int(min), max: Int(max), unit: unit, isDouble: true)

        case .toggle:
            break
        }
    }

    private func showSliderAlert(item: SettingItem, min: Int, max: Int, unit: String, isDouble: Bool) {
        let alert = UIAlertController(title: item.title, message: nil, preferredStyle: .alert)

        alert.addTextField { textField in
            textField.keyboardType = .numberPad
            if isDouble {
                let value = UserDefaults.standard.double(forKey: item.key)
                textField.text = value > 0 ? String(format: "%.0f", value) : String(format: "%.0f", Double(min))
            } else {
                let value = UserDefaults.standard.integer(forKey: item.key)
                textField.text = value > 0 ? "\(value)" : "\(min)"
            }
        }

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self] _ in
            guard let text = alert.textFields?.first?.text,
                  let value = Double(text) else {
                return
            }
            let finalValue = isDouble ? value : Double(Int(value))
            UserDefaults.standard.set(finalValue, forKey: item.key)
            self?.tableView.reloadData()
        })

        present(alert, animated: true)
    }
}
```

- [ ] **步骤 2：修改 `DownloadConfiguration.default` 为计算属性**

在 `DownloadConfiguration.swift` 中，将：

```swift
static let `default` = DownloadConfiguration(
    maxConcurrentDownloads: Constants.Network.maxConcurrentDownloads,
    timeoutInterval: Constants.Network.timeoutInterval,
    retryCount: Constants.Network.maxRetryCount,
    enableBackgroundDownload: true,
    customHeaders: [:],
    allowCellularDownload: Constants.NetworkMonitor.defaultAllowCellularDownload
)
```

替换为：

```swift
static var `default`: DownloadConfiguration {
    return DownloadConfiguration(
        maxConcurrentDownloads: SettingsViewController.getMaxConcurrentDownloads(),
        timeoutInterval: SettingsViewController.getTimeoutInterval(),
        retryCount: SettingsViewController.getRetryCount(),
        enableBackgroundDownload: SettingsViewController.getEnableBackgroundDownload(),
        customHeaders: [:],
        allowCellularDownload: SettingsViewController.getAllowCellularDownload()
    )
}
```

- [ ] **步骤 3：编译验证**

Run: `xcodebuild -project /Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad.xcodeproj -scheme DownLoad -destination 'platform=iOS Simulator,name=iPhone 15'`
Expected: 编译通过

---

## 任务 5：问题 31 - Tab 重复修复

**文件：**
- 修改：`/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/UI/MainTabBarController.swift`

- [ ] **步骤 1：替换 `setupTabBarController()` 方法**

将 `setupTabBarController()` 方法整体替换为：

```swift
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

    // 创建设置视图控制器
    let settingsVC = SettingsViewController()
    settingsVC.title = "设置"
    let settingsNav = UINavigationController(rootViewController: settingsVC)
    settingsNav.tabBarItem = UITabBarItem(
        title: "设置",
        image: UIImage(systemName: "gear"),
        tag: 2
    )

    // 设置视图控制器数组
    let viewControllers = [singleDownloadNav, batchDownloadNav, settingsNav]

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
```

- [ ] **步骤 2：编译验证**

Run: `xcodebuild -project /Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad.xcodeproj -scheme DownLoad -destination 'platform=iOS Simulator,name=iPhone 15'`
Expected: 编译通过

---

## 任务 6：问题 28 - Cell 信息展示增强

**文件：**
- 修改：`/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/UI/BatchDownloadCell.swift`

- [ ] **步骤 1：添加信息标签**

在 `UI Components` 区域添加：

```swift
private let infoLabel: UILabel = {
    let label = UILabel()
    label.font = UIFont.systemFont(ofSize: 11)
    label.textColor = .secondaryLabel
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
}()
```

- [ ] **步骤 2：修改 `setupUI()` 添加约束**

在 `contentView.addSubview(failedCountLabel)` 之后添加：

```swift
contentView.addSubview(infoLabel)
```

在约束区域，在 `failedCountLabel` 约束之后添加：

```swift
infoLabel.topAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: 4),
infoLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16)
```

- [ ] **步骤 3：修改 `updateProgress(batchTask:)` 方法**

将方法替换为：

```swift
private func updateProgress(batchTask: BatchDownloadManager.BatchDownloadTask) {
    Task {
        let progress = await engine.getBatchProgress(batchId: batchTask.id)
        let total = progress?.total ?? batchTask.taskItems.count
        let completed = progress?.completed ?? 0
        let downloading = progress?.downloading ?? 0
        let paused = progress?.paused ?? 0
        let failedInCreation = progress?.failedInCreation ?? 0

        // 聚合计算已下载大小和总大小
        var totalDownloadedBytes: Int64 = 0
        var totalTotalBytes: Int64 = 0

        for item in batchTask.taskItems {
            if let task = await engine.getTask(by: item.task.id) {
                totalDownloadedBytes += task.downloadedSize
                if let taskTotal = task.totalSize {
                    totalTotalBytes += taskTotal
                }
            }
        }

        let sizeText: String
        if totalTotalBytes > 0 {
            sizeText = "\(ByteCountFormatter.string(fromByteCount: totalDownloadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: totalTotalBytes, countStyle: .file))"
        } else {
            sizeText = "大小计算中..."
        }

        await MainActor.run {
            progressView.progress = total > 0 ? Float(completed) / Float(total) : 0
            progressLabel.text = "\(completed)/\(total) (\(Int((Float(completed) / Float(total)) * 100))%)"
            countLabel.text = "下载中:\(downloading) 暂停:\(paused)"
            infoLabel.text = sizeText

            if failedInCreation > 0 {
                failedCountLabel.text = "创建失败:\(failedInCreation)"
                failedCountLabel.isHidden = false
            } else {
                failedCountLabel.isHidden = true
            }
        }
    }
}
```

- [ ] **步骤 4：修改 `prepareForReuse()`**

添加 `infoLabel` 清理：

```swift
infoLabel.text = ""
```

- [ ] **步骤 5：编译验证**

Run: `xcodebuild -project /Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad.xcodeproj -scheme DownLoad -destination 'platform=iOS Simulator,name=iPhone 15'`
Expected: 编译通过

---

## 任务 7：问题 26 - 批量下载页暂停/恢复/重试操作

**文件：**
- 修改：`/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/UI/BatchDownloadCell.swift`
- 修改：`/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/UI/BatchDownloadViewController.swift`

- [ ] **步骤 1：添加委托协议**

在 `BatchDownloadCell.swift` 的类定义之前添加：

```swift
protocol BatchDownloadCellDelegate: AnyObject {
    func batchDownloadCell(_ cell: BatchDownloadCell, didTapPause batchId: UUID)
    func batchDownloadCell(_ cell: BatchDownloadCell, didTapResume batchId: UUID)
    func batchDownloadCell(_ cell: BatchDownloadCell, didTapRetry batchId: UUID)
    func batchDownloadCell(_ cell: BatchDownloadCell, didTapCancel batchId: UUID)
}
```

- [ ] **步骤 2：添加操作按钮属性**

在 `BatchDownloadCell` 的 `UI Components` 区域添加：

```swift
weak var delegate: BatchDownloadCellDelegate?
private var currentBatchId: UUID?

private let actionStackView: UIStackView = {
    let sv = UIStackView()
    sv.axis = .horizontal
    sv.spacing = 8
    sv.distribution = .fillEqually
    sv.translatesAutoresizingMaskIntoConstraints = false
    return sv
}()

private lazy var pauseResumeButton: UIButton = {
    let button = UIButton(type: .system)
    button.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .medium)
    button.layer.cornerRadius = 4
    button.translatesAutoresizingMaskIntoConstraints = false
    button.addTarget(self, action: #selector(pauseResumeTapped), for: .touchUpInside)
    return button
}()

private lazy var retryButton: UIButton = {
    let button = UIButton(type: .system)
    button.setTitle("重试", for: .normal)
    button.setTitleColor(.white, for: .normal)
    button.backgroundColor = UIColor(hex: "52c41a")
    button.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .medium)
    button.layer.cornerRadius = 4
    button.translatesAutoresizingMaskIntoConstraints = false
    button.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
    return button
}()

private lazy var cancelButton: UIButton = {
    let button = UIButton(type: .system)
    button.setTitle("取消", for: .normal)
    button.setTitleColor(.white, for: .normal)
    button.backgroundColor = UIColor(hex: "ff4d4f")
    button.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .medium)
    button.layer.cornerRadius = 4
    button.translatesAutoresizingMaskIntoConstraints = false
    button.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
    return button
}()
```

- [ ] **步骤 3：修改 `setupUI()` 添加操作按钮**

在 `contentView.addSubview(failedCountLabel)` 之后添加：

```swift
contentView.addSubview(actionStackView)
actionStackView.addArrangedSubview(pauseResumeButton)
actionStackView.addArrangedSubview(retryButton)
actionStackView.addArrangedSubview(cancelButton)
```

在约束区域，在 `infoLabel` 约束之后添加：

```swift
actionStackView.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 8),
actionStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
actionStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
actionStackView.heightAnchor.constraint(equalToConstant: 32),
actionStackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12)
```

- [ ] **步骤 4：修改 `configure(with:)` 方法**

在方法开头添加：

```swift
currentBatchId = batchTask.id
```

在方法末尾添加操作按钮状态更新：

```swift
updateActionButtons(state: batchTask.state, hasFailedItems: !batchTask.failedItems.isEmpty)
```

添加 `updateActionButtons` 方法：

```swift
private func updateActionButtons(state: BatchDownloadManager.BatchState, hasFailedItems: Bool) {
    switch state {
    case .downloading:
        pauseResumeButton.setTitle("暂停", for: .normal)
        pauseResumeButton.backgroundColor = UIColor(hex: "faad14")
        pauseResumeButton.setTitleColor(.white, for: .normal)
        pauseResumeButton.isHidden = false
        retryButton.isHidden = true
        cancelButton.isHidden = false
    case .paused:
        pauseResumeButton.setTitle("恢复", for: .normal)
        pauseResumeButton.backgroundColor = UIColor(hex: "1890ff")
        pauseResumeButton.setTitleColor(.white, for: .normal)
        pauseResumeButton.isHidden = false
        retryButton.isHidden = true
        cancelButton.isHidden = false
    case .failed, .partiallyFailed:
        pauseResumeButton.isHidden = true
        retryButton.isHidden = !hasFailedItems
        cancelButton.isHidden = false
    case .pending:
        pauseResumeButton.isHidden = true
        retryButton.isHidden = true
        cancelButton.isHidden = false
    case .completed, .cancelled:
        pauseResumeButton.isHidden = true
        retryButton.isHidden = true
        cancelButton.isHidden = true
    }
}
```

- [ ] **步骤 5：添加按钮点击处理方法**

```swift
@objc private func pauseResumeTapped() {
    guard let batchId = currentBatchId else { return }
    let title = pauseResumeButton.title(for: .normal)
    if title == "暂停" {
        delegate?.batchDownloadCell(self, didTapPause: batchId)
    } else if title == "恢复" {
        delegate?.batchDownloadCell(self, didTapResume: batchId)
    }
}

@objc private func retryTapped() {
    guard let batchId = currentBatchId else { return }
    delegate?.batchDownloadCell(self, didTapRetry: batchId)
}

@objc private func cancelTapped() {
    guard let batchId = currentBatchId else { return }
    delegate?.batchDownloadCell(self, didTapCancel: batchId)
}
```

- [ ] **步骤 6：修改 `prepareForReuse()`**

添加清理：

```swift
currentBatchId = nil
delegate = nil
pauseResumeButton.isHidden = true
retryButton.isHidden = true
cancelButton.isHidden = true
```

- [ ] **步骤 7：调整 Cell 高度**

在 `BatchDownloadViewController.swift` 的 `heightForRowAt` 中，将返回值从 `100` 改为 `140`：

```swift
func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    return 140
}
```

- [ ] **步骤 8：在 `BatchDownloadViewController` 中实现委托协议**

在类声明中添加协议遵循：

```swift
class BatchDownloadViewController: UIViewController, BatchDownloadCellDelegate {
```

在 `cellForRowAt` 中设置委托：

```swift
cell.delegate = self
```

添加委托方法实现（放在 `Helper Methods` 区域）：

```swift
// MARK: - BatchDownloadCellDelegate

func batchDownloadCell(_ cell: BatchDownloadCell, didTapPause batchId: UUID) {
    Task {
        await batchManager.pauseBatchDownload(batchId: batchId)
        await loadBatchTasks()
    }
}

func batchDownloadCell(_ cell: BatchDownloadCell, didTapResume batchId: UUID) {
    Task {
        do {
            try await batchManager.startBatchDownload(batchId: batchId)
            await loadBatchTasks()
        } catch {
            showAlert(title: "恢复失败", message: error.localizedDescription)
        }
    }
}

func batchDownloadCell(_ cell: BatchDownloadCell, didTapRetry batchId: UUID) {
    retryFailedItems(batchId: batchId)
}

func batchDownloadCell(_ cell: BatchDownloadCell, didTapCancel batchId: UUID) {
    let alertController = UIAlertController(
        title: "确认取消",
        message: "确定要取消该批量下载任务吗？",
        preferredStyle: .alert
    )
    alertController.addAction(UIAlertAction(title: "取消", style: .cancel))
    alertController.addAction(UIAlertAction(title: "确定", style: .destructive) { [weak self] _ in
        Task {
            await self?.batchManager.cancelBatchDownload(batchId: batchId)
            await self?.loadBatchTasks()
        }
    })
    present(alertController, animated: true)
}
```

- [ ] **步骤 9：编译验证**

Run: `xcodebuild -project /Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad.xcodeproj -scheme DownLoad -destination 'platform=iOS Simulator,name=iPhone 15'`
Expected: 编译通过

---

## 任务 8：问题 27 - 实时进度刷新

**文件：**
- 修改：`/Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad/UI/BatchDownloadViewController.swift`

- [ ] **步骤 1：替换 `subscribeToTaskUpdates()` 方法**

将 `subscribeToTaskUpdates()` 方法完全替换为：

```swift
private func subscribeToTaskUpdates() {
    // 监听进度更新通知，实时刷新对应 Cell
    NotificationCenter.default.publisher(for: DownloadNotification.progressDidUpdate)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] notification in
            guard let self = self,
                  let taskId = notification.userInfo?[DownloadNotificationKey.taskId] as? UUID else {
                return
            }
            self.refreshCellIfContains(taskId: taskId)
        }
        .store(in: &cancellables)

    // 监听状态变化通知
    NotificationCenter.default.publisher(for: DownloadNotification.stateDidChange)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] notification in
            guard let self = self,
                  let taskId = notification.userInfo?[DownloadNotificationKey.taskId] as? UUID else {
                return
            }
            self.refreshCellIfContains(taskId: taskId)
        }
        .store(in: &cancellables)
}

private func refreshCellIfContains(taskId: UUID) {
    for (index, batchTask) in batchTasks.enumerated() {
        if batchTask.taskItems.contains(where: { $0.task.id == taskId }) {
            let indexPath = IndexPath(row: index, section: 0)
            if let cell = tableView.cellForRow(at: indexPath) as? BatchDownloadCell {
                cell.configure(with: batchTask)
            }
            break
        }
    }
}
```

- [ ] **步骤 2：编译验证**

Run: `xcodebuild -project /Users/hubin/Desktop/MutiDownload/DownLoad/DownLoad.xcodeproj -scheme DownLoad -destination 'platform=iOS Simulator,name=iPhone 15'`
Expected: 编译通过

---

## 验证步骤汇总

1. **编译验证：** 每次任务完成后执行 `xcodebuild` 编译，确保无编译错误。
2. **功能验证：**
   - 问题 25：运行应用，进入"单任务下载"Tab，确认 URL 输入框可见，输入有效/无效 URL 测试。
   - 问题 26：进入"批量下载"Tab，添加任务后确认 Cell 上显示"暂停"/"取消"按钮，点击测试暂停/恢复/重试/取消功能。
   - 问题 27：下载过程中观察 Cell 进度条，确认实时更新。
   - 问题 28：确认 Cell 中显示已下载大小/总大小信息。
   - 问题 29：确认所有状态文字显示为中文。
   - 问题 30：进入"设置"Tab，修改参数后确认保存生效。
   - 问题 31：确认底部只有 3 个 Tab，无重复。
   - 问题 32：确认 `Info.plist` 中 `NSAllowsArbitraryLoads` 为 `false`。
3. **回归测试：** 所有修改完成后，重新运行完整编译，确保无新增警告或错误。

---

## 假设与决策

1. **DownloadTask 协议属性：** 假设 `DownloadTask` 协议已暴露 `downloadedSize` 和 `totalSize` 属性（实际代码已确认）。
2. **设置页面持久化：** 使用 `UserDefaults` 持久化用户设置，简单可靠，满足当前需求。
3. **ATS 配置：** 将 `NSAllowsArbitraryLoads` 设为 `false`，不添加特定域名例外，因为视频下载 URL 由用户输入，无法预知。
4. **Cell 高度：** 将 Cell 高度从 100 调整为 140，为操作按钮和信息标签留出足够空间。
5. **实时刷新机制：** 使用 `NotificationCenter` 通知替代定时器轮询，减少资源消耗，提升实时性。
