# P3 问题42修复计划：BatchDownloadViewController 空状态页面/加载状态/错误引导

## 摘要
为 `BatchDownloadViewController` 添加空状态页面、加载状态指示器和错误引导，参照 `CompletedFilesViewController` 的成熟模式，复用已有的 `EmptyStateView` 组件。

## 当前状态分析
- `BatchDownloadViewController.swift`（551行）只有 `tableView`、`selectionBar`、`addButton` 三个 UI 组件
- `batchTasks` 为空时，`numberOfRowsInSection` 返回 0，页面完全空白，无任何引导
- `loadBatchTasks()` 无加载中指示器，无错误处理（无 catch）
- 项目中已有 `EmptyStateView` 组件（`EmptyStateView.swift`），接口：`configure(icon:title:description:)`
- `CompletedFilesViewController` 已成功集成 `EmptyStateView`，可参照其模式

## 修改方案

### 修改文件：`DownLoad/DownLoad/UI/BatchDownloadViewController.swift`

#### 1. 添加 EmptyStateView 属性
在 UI Components 区域添加：
```swift
private lazy var emptyStateView: EmptyStateView = {
    let view = EmptyStateView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
}()
```

#### 2. 添加加载状态 ActivityIndicator
```swift
private lazy var loadingIndicator: UIActivityIndicatorView = {
    let indicator = UIActivityIndicatorView(style: .medium)
    indicator.hidesWhenStopped = true
    indicator.translatesAutoresizingMaskIntoConstraints = false
    return indicator
}()
```

#### 3. setupUI() 中添加视图和约束
- 将 `emptyStateView` 添加到 view
- 设置约束覆盖 tableView 区域（safeAreaLayoutGuide 内）
- `emptyStateView` 初始 `isHidden = true`

#### 4. 新增 updateEmptyState() 方法
参照 CompletedFilesViewController 模式：
- `batchTasks` 为空 → 显示空状态，配置引导文案（icon: `"tray"`, title: `"暂无批量下载任务"`, description: `"点击右下角 + 按钮添加批量下载任务"`）
- `batchTasks` 非空 → 隐藏空状态，显示 tableView
- 加载失败 → 配置错误引导（icon: `"exclamationmark.triangle"`, title: `"加载失败"`, description: `"请稍后重试"`）

#### 5. 改造 loadBatchTasks() 方法
- 开始时：显示 loadingIndicator，隐藏 emptyStateView 和 tableView
- 成功时：隐藏 loadingIndicator，更新 batchTasks，reloadData，调用 updateEmptyState()
- 失败时：隐藏 loadingIndicator，调用 updateEmptyState() 显示错误状态

#### 6. 在数据变更处调用 updateEmptyState()
- `createBatchDownload` 完成后（已有 `loadBatchTasks()` 调用，内部会处理）
- 删除任务后（已有 `loadBatchTasks()` 调用，内部会处理）
- `viewDidAppear` 中的 `loadBatchTasks()`（内部会处理）

## 验证步骤
1. 编译通过（`xcodebuild` 或 Xcode）
2. 首次打开批量下载页（无任务）→ 显示空状态引导页面
3. 添加批量任务后 → 空状态消失，显示任务列表
4. 删除所有任务后 → 重新显示空状态
5. 加载数据时 → 显示 loading indicator
6. 记录修复到 `缺陷修复优先级排序.md` 问题42行
