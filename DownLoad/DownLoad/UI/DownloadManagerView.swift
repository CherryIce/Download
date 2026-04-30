import UIKit
import Combine

/// 可复用的下载管理视图
public class DownloadManagerView: UIView, UITableViewDataSource, UITableViewDelegate {
    private let tableView = UITableView()
    private var tasks: [any DownloadTask] = []
    private var cancellables = Set<AnyCancellable>()

    public var engine = VideoDownloadEngine.shared

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
        subscribeToTasks()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
        subscribeToTasks()
    }

    private func setupUI() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: topAnchor),
            tableView.leftAnchor.constraint(equalTo: leftAnchor),
            tableView.rightAnchor.constraint(equalTo: rightAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func subscribeToTasks() {
        // 假设 engine 提供 tasks 发布器
        // engine.tasksPublisher
        //     .sink { [weak self] newTasks in
        //         self?.tasks = newTasks
        //         self?.tableView.reloadData()
        //     }
        //     .store(in: &cancellables)
    }

    public func reload(tasks: [any DownloadTask]) {
        self.tasks = tasks
        tableView.reloadData()
    }

    // UITableViewDataSource
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return tasks.count
    }
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let task = tasks[indexPath.row]
        cell.textLabel?.text = "\(task.fileName) - \(task.state.value)"
        return cell
    }
}
