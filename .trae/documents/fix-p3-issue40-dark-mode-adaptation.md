# P3-40 暗色模式适配修复计划

## 摘要

修复 P3 问题 40：暗色模式未适配。项目中存在 14 处 `UIColor(hex:)` 硬编码颜色、12 处 `.white` 硬编码、1 处 `.gray` 硬编码，在暗色模式下会导致背景刺眼、文字不可读、分隔线异常等问题。当前项目完全没有任何暗黑模式适配代码。

## 当前状态分析

### 已适配（无需修改）
以下文件已使用 iOS 语义颜色，自动支持暗黑模式：
- `ViewController.swift` — `.systemBackground`、`.systemBlue/.systemOrange/.systemRed/.systemGreen/.systemPurple`
- `CompletedFilesViewController.swift` — `.secondaryLabel`、`.systemBackground`
- `CompletedFileDetailViewController.swift` — `.systemBackground`、`.systemRed`
- `EmptyStateView.swift` — `.secondaryLabel`、`.label`
- `MainTabBarController.swift` — `.systemBackground`、`.systemBlue`
- `SettingsViewController.swift` — `.systemBackground`
- `VideoPlayerViewController.swift` — 无自定义颜色

### 需要修复的硬编码颜色（共 27 处）

| 文件 | 类型 | 数量 | 问题 |
|------|------|------|------|
| `BatchDownloadViewController.swift` | hex + .white | 5 | tableView 背景 `f5f5f5`、选择栏背景 `.white`、文字 `333333`、按钮颜色 |
| `BatchDownloadCell.swift` | hex + .white + .gray | 7 | 按钮颜色（重试/取消/暂停/恢复）、分隔线 `e0e0e0`、状态 `.gray` |
| `CompletedFileCell.swift` | hex | 4 | 图标 `1890ff`、格式标签文字 `8c8c8c` + 背景 `f0f0f0`、分隔线 `e0e0e0` |
| `CompletedFilesViewController.swift` | hex | 1 | 分享按钮 `1890ff` |
| `ViewController.swift` | .white | 5 | 按钮文字颜色（彩色按钮上的白色文字，影响较小） |

## 修改方案

### 策略：使用 `UIColor { traitCollection in ... }` 动态颜色

不使用 Asset Catalog（改动量大），直接在代码中用 iOS 动态颜色 API 替换硬编码值。按钮文字的 `.white` 在彩色背景上可接受，仅修复背景和分隔线相关的硬编码。

### Step 1: 扩展 `UIColor+Hex.swift`，新增暗黑模式动态颜色工厂方法

**文件**: `DownLoad/UI/Extensions/UIColor+Hex.swift`

新增两个工具方法：
```swift
/// 创建动态颜色，自动适配暗黑模式
static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
    return UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark ? dark : light
    }
}

/// 从 hex 创建动态颜色（提供 light 和 dark 两个 hex 值）
static func dynamic(hex lightHex: String, darkHex: String) -> UIColor {
    return UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark
            ? UIColor(hex: darkHex)
            : UIColor(hex: lightHex)
    }
}
```

### Step 2: 修复 `BatchDownloadViewController.swift`（5 处）

| 行号 | 原值 | 替换为 | 说明 |
|------|------|--------|------|
| 21 | `UIColor(hex: "f5f5f5")` | `.systemGroupedBackground` | tableView 背景色 |
| 40 | `.white` | `.secondarySystemGroupedBackground` | 选择栏背景色 |
| 57 | `UIColor(hex: "333333")` | `.label` | 选择栏文字颜色 |
| 67 | `UIColor(hex: "ff4d4f")` | `.systemRed` | 删除按钮背景色 |
| 78 | `UIColor(hex: "1890ff")` | `.systemBlue` | 添加按钮背景色 |

### Step 3: 修复 `BatchDownloadCell.swift`（7 处）

| 行号 | 原值 | 替换为 | 说明 |
|------|------|--------|------|
| 96 | `UIColor(hex: "52c41a")` | `.systemGreen` | 重试按钮背景色 |
| 108 | `UIColor(hex: "ff4d4f")` | `.systemRed` | 取消按钮背景色 |
| 211 | `UIColor(hex: "faad14")` | `.systemOrange` | 暂停按钮背景色 |
| 218 | `UIColor(hex: "1890ff")` | `.systemBlue` | 恢复按钮背景色 |
| 262 | `UIColor(hex: "e0e0e0")` | `UIColor.dynamic(light: UIColor(hex: "e0e0e0"), dark: UIColor(hex: "3a3a3a"))` | 分隔线背景色 |
| 339 | `.gray` | `.tertiaryLabel` | 已取消状态文字颜色 |

注意：按钮文字的 `.white` 在彩色按钮背景上可接受，不修改。

### Step 4: 修复 `CompletedFileCell.swift`（4 处）

| 行号 | 原值 | 替换为 | 说明 |
|------|------|--------|------|
| 17 | `UIColor(hex: "1890ff")` | `.systemBlue` | 图标 tintColor |
| 42 | `UIColor(hex: "8c8c8c")` | `.secondaryLabel` | 格式标签文字颜色 |
| 43 | `UIColor(hex: "f0f0f0")` | `UIColor.dynamic(light: UIColor(hex: "f0f0f0"), dark: UIColor(hex: "2c2c2e"))` | 格式标签背景色 |
| 61 | `UIColor(hex: "e0e0e0")` | `UIColor.dynamic(light: UIColor(hex: "e0e0e0"), dark: UIColor(hex: "3a3a3a"))` | 分隔线背景色 |

### Step 5: 修复 `CompletedFilesViewController.swift`（1 处）

| 行号 | 原值 | 替换为 | 说明 |
|------|------|--------|------|
| 439 | `UIColor(hex: "1890ff")` | `.systemBlue` | 分享滑动按钮背景色 |

### Step 6: `ViewController.swift` 按钮文字 `.white` — 不修改

5 处 `.white` 按钮文字（download/pause/cancel/retry/play）均在彩色背景按钮上，暗黑模式下白色文字在 `.systemBlue/.systemOrange/.systemRed/.systemGreen/.systemPurple` 背景上依然可读，无需修改。

## 假设与决策

1. **不使用 Asset Catalog 颜色集**：改动量大且需要 Xcode 操作，代码内动态颜色更直接
2. **不强制锁定外观模式**：尊重系统设置，跟随系统自动切换
3. **按钮文字白色保留**：彩色按钮上的白色文字在暗黑模式下对比度足够
4. **分隔线使用动态颜色**：浅灰 `e0e0e0` → 暗黑模式用 `3a3a3a`，与 iOS 暗黑分隔线风格一致
5. **格式标签背景使用动态颜色**：浅灰 `f0f0f0` → 暗黑模式用 `2c2c2e`（iOS 暗黑次级背景色）

## 验证步骤

1. **编译验证**：`xcodebuild build -scheme DownLoad -destination 'platform=iOS Simulator,name=iPhone 16'` 确保编译通过
2. **搜索验证**：
   - `grep -r 'UIColor(hex:' UI/` 确认无残留硬编码 hex（分隔线/标签除外）
   - `grep -rn 'view.backgroundColor = .white' UI/` 确认无 `.white` 背景
   - `grep -rn 'textColor = .gray' UI/` 确认无 `.gray` 文字色
3. **功能验证**：在模拟器中切换 Light/Dark 模式，检查所有页面：
   - 批量下载页：tableView 背景、选择栏、按钮、分隔线
   - 已完成文件页：图标、格式标签、分隔线
   - 单任务下载页：按钮（确认白色文字可读）
   - 设置页：已使用语义颜色，无需额外验证
4. **记录更新**：在 `缺陷修复优先级排序.md` 中将问题 40 标记为 ✅ 已修复
