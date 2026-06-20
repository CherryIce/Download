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
        let tv = UITableView(frame: .zero, style: .grouped)
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
