# 修复计划：问题44 - `UIColor+Hex` 不支持 3 位缩写和 alpha 通道

## 摘要

增强 `UIColor+Hex.swift` 中的 `convenience init(hex:)` 方法，使其支持 3 位缩写（`"FFF"`）、4 位缩写带 alpha（`"FFFA"`）和 8 位标准带 alpha（`"FFFFFFFF"`）格式，同时保持所有现有 6 位调用的向后兼容性。

## 当前状态分析

**文件**: `DownLoad/DownLoad/UI/Extensions/UIColor+Hex.swift`

当前 `init(hex:)` 仅支持 6 位 RGB hex 字符串（可选 `#` 前缀），alpha 固定为 1.0。使用 `Scanner.scanHexInt64` 解析后固定取低 24 位 RGB。对 3 位/4 位/8 位输入无法正确处理。

**现有调用点**（全部为 6 位无 alpha）:
- `CompletedFileCell.swift:43` — `UIColor(hex: "f0f0f0")`, `UIColor(hex: "2c2c2e")`
- `CompletedFileCell.swift:61` — `UIColor(hex: "e0e0e0")`, `UIColor(hex: "3a3a3a")`
- `BatchDownloadCell.swift:262` — `UIColor(hex: "e0e0e0")`, `UIColor(hex: "3a3a3a")`
- `UIColor+Hex.swift:30-31` — 内部 `dynamic(hex:darkHex:)` 调用

## 变更方案

### 变更 1：修改 `UIColor+Hex.swift`

**文件**: `DownLoad/DownLoad/UI/Extensions/UIColor+Hex.swift`

**做什么**: 替换 `convenience init(hex:)` 方法，新增 `static func expandShorthand(_:)` 辅助方法。

**怎么做**: 根据 `hexSanitized.count` 分派到不同解析路径：

| 长度 | 格式 | 处理方式 |
|------|------|----------|
| 3 | RGB 缩写 | `expandShorthand` 展开为 6 位，fallthrough 到 6 位分支 |
| 4 | RGBA 缩写 | `expandShorthand` 展开为 8 位，fallthrough 到 8 位分支 |
| 6 | RGB 标准 | 直接解析 RGB，alpha=1.0（与原逻辑一致） |
| 8 | RGBA 标准 | 解析 `RRGGBBAA`，alpha 在最低字节（CSS 标准） |
| 其他 | 非法 | `assertionFailure` + 回退透明黑色 |

关键设计：
- `expandShorthand` 为 `static` 方法（`convenience init` 中 self 未初始化，不能调用实例方法）
- 使用 `fallthrough` 复用解析逻辑，避免代码重复
- 8 位字节序采用 CSS `#RRGGBBAA` 标准
- `assertionFailure` 在 Release 中静默回退，不会崩溃

### 变更 2：更新缺陷修复记录

**文件**: `缺陷修复优先级排序.md`

**做什么**: 将第 44 行标记为已修复，记录修复内容。

## 假设与决策

1. 8 位 hex 采用 `RRGGBBAA` 字节序（CSS 标准），alpha 在最低字节
2. 无效输入使用 `assertionFailure` 而非 `fatalError`，Release 中静默回退透明黑色
3. 不修改任何调用方文件，全部向后兼容

## 验证步骤

1. 确认所有现有 6 位 `UIColor(hex:)` 调用走 6 位分支，行为不变
2. 编译项目，确认无编译错误和警告
3. 更新 `缺陷修复优先级排序.md` 记录修复状态
