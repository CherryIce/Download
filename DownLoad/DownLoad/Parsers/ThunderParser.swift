//
//  ThunderParser.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation

/// 迅雷协议解析器
/// 支持 thunder:// 和 thunderp2p:// 格式的解析
class ThunderParser {

    /// 解析结果：包含解码后的真实 URL 和元信息
    struct ParseResult {
        let url: URL
        let isMagnetLink: Bool
        let isP2P: Bool
    }

    /// 解析迅雷链接（支持 thunder:// 和 thunderp2p://）
    func parse(thunderURL: String) throws -> ParseResult {
        let lowercased = thunderURL.lowercased()

        if lowercased.hasPrefix("thunderp2p://") {
            return try parseThunderP2P(thunderURL: thunderURL)
        } else if lowercased.hasPrefix("thunder://") {
            return try parseClassicThunder(thunderURL: thunderURL)
        } else {
            throw DownloadError.thunderProtocolError
        }
    }

    /// 解析经典迅雷链接 thunder://
    /// 格式：thunder://Base64(AA + 真实URL + ZZ)
    private func parseClassicThunder(thunderURL: String) throws -> ParseResult {
        // 1. 去掉前缀
        let encodedString = String(thunderURL.dropFirst("thunder://".count))

        // 2. Base64解码
        guard let data = Data(base64Encoded: encodedString) else {
            throw DownloadError.thunderProtocolError
        }

        guard let decodedString = String(data: data, encoding: .utf8) else {
            throw DownloadError.thunderProtocolError
        }

        // 3. 去掉AA前缀和ZZ后缀
        guard decodedString.hasPrefix("AA") && decodedString.hasSuffix("ZZ") else {
            throw DownloadError.thunderProtocolError
        }

        let realURLString = String(decodedString.dropFirst(2).dropLast(2))

        // 4. 创建URL
        guard let url = URL(string: realURLString) else {
            throw DownloadError.thunderProtocolError
        }

        Logger.info("Thunder URL decoded: \(realURLString)")

        // 5. 检查解码后是否为磁力链接
        let isMagnet = realURLString.lowercased().hasPrefix("magnet:")

        return ParseResult(url: url, isMagnetLink: isMagnet, isP2P: false)
    }

    /// 解析迅雷 P2P 链接 thunderp2p://
    /// 格式与 thunder:// 类似，也是 Base64 编码，但内部可能封装磁力链接或 BT hash
    private func parseThunderP2P(thunderURL: String) throws -> ParseResult {
        // 1. 去掉前缀
        let encodedString = String(thunderURL.dropFirst("thunderp2p://".count))

        // 2. Base64解码
        guard let data = Data(base64Encoded: encodedString) else {
            throw DownloadError.thunderProtocolError
        }

        guard let decodedString = String(data: data, encoding: .utf8) else {
            throw DownloadError.thunderProtocolError
        }

        Logger.info("ThunderP2P URL decoded: \(decodedString)")

        let lowerDecoded = decodedString.lowercased()

        // 情况 A：解码后是磁力链接
        if lowerDecoded.hasPrefix("magnet:") {
            guard let url = URL(string: decodedString) else {
                throw DownloadError.thunderProtocolError
            }
            return ParseResult(url: url, isMagnetLink: true, isP2P: true)
        }

        // 情况 B：解码后是 AA...ZZ 包装的普通 URL
        if decodedString.hasPrefix("AA") && decodedString.hasSuffix("ZZ") {
            let realURLString = String(decodedString.dropFirst(2).dropLast(2))
            guard let url = URL(string: realURLString) else {
                throw DownloadError.thunderProtocolError
            }
            Logger.info("ThunderP2P decoded to real URL: \(realURLString)")
            return ParseResult(url: url, isMagnetLink: false, isP2P: true)
        }

        // 情况 C：解码后是直接的 URL（无 AA/ZZ 包装）
        if let url = URL(string: decodedString), url.scheme != nil {
            Logger.info("ThunderP2P decoded to direct URL: \(decodedString)")
            return ParseResult(url: url, isMagnetLink: false, isP2P: true)
        }

        // 情况 D：无法识别的内容（可能是 BT hash 等）
        throw DownloadError.thunderProtocolError
    }

    /// 判断字符串是否为磁力链接
    static func isMagnetLink(_ url: String) -> Bool {
        return url.lowercased().hasPrefix("magnet:")
    }
}
