import UIKit

extension UIColor {
    /// 支持 3/4/6/8 位 hex 字符串初始化 UIColor
    /// - 3 位: "FFF" -> 每位重复展开为 "FFFFFF"，alpha = 1.0
    /// - 4 位: "FFFA" -> 每位重复展开为 "FFFFFFAA"
    /// - 6 位: "FFFFFF" -> RGB，alpha = 1.0
    /// - 8 位: "FFFFFFFF" -> RGBA（CSS #RRGGBBAA 标准）
    /// - 可选 "#" 前缀，大小写不敏感
    convenience init(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        switch hexSanitized.count {
        case 3:
            // "RGB" -> "RRGGBB"
            hexSanitized = Self.expandShorthand(hexSanitized)
            fallthrough
        case 6:
            // "RRGGBB" -> RGB, alpha = 1.0
            var rgb: UInt64 = 0
            Scanner(string: hexSanitized).scanHexInt64(&rgb)
            let red = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            let green = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            let blue = CGFloat(rgb & 0x0000FF) / 255.0
            self.init(red: red, green: green, blue: blue, alpha: 1.0)

        case 4:
            // "RGBA" -> "RRGGBBAA"
            hexSanitized = Self.expandShorthand(hexSanitized)
            fallthrough
        case 8:
            // "RRGGBBAA" -> RGBA
            var rgba: UInt64 = 0
            Scanner(string: hexSanitized).scanHexInt64(&rgba)
            let red = CGFloat((rgba & 0xFF000000) >> 24) / 255.0
            let green = CGFloat((rgba & 0x00FF0000) >> 16) / 255.0
            let blue = CGFloat((rgba & 0x0000FF00) >> 8) / 255.0
            let alpha = CGFloat(rgba & 0x000000FF) / 255.0
            self.init(red: red, green: green, blue: blue, alpha: alpha)

        default:
            assertionFailure("UIColor(hex:) 接收到无效的 hex 字符串长度: \(hexSanitized.count)，原始值: \"\(hex)\"。支持 3/4/6/8 位。")
            self.init(red: 0, green: 0, blue: 0, alpha: 0)
        }
    }

    /// 将缩写 hex 展开为完整形式
    /// "RGB" -> "RRGGBB", "RGBA" -> "RRGGBBAA"
    private static func expandShorthand(_ hex: String) -> String {
        return hex.map { "\($0)\($0)" }.joined()
    }

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
}