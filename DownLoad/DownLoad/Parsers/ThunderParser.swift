//
//  ThunderParser.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation

/// 迅雷协议解析器
class ThunderParser {

    /// 解析迅雷链接
    func parse(thunderURL: String) throws -> URL {
        // 1. 验证格式
        guard thunderURL.lowercased().hasPrefix("thunder://") else {
            throw DownloadError.thunderProtocolError
        }

        // 2. 去掉前缀
        let encodedString = String(thunderURL.dropFirst("thunder://".count))

        // 3. Base64解码
        guard let data = Data(base64Encoded: encodedString) else {
            throw DownloadError.thunderProtocolError
        }

        guard let decodedString = String(data: data, encoding: .utf8) else {
            throw DownloadError.thunderProtocolError
        }

        // 4. 去掉AA前缀和ZZ后缀
        guard decodedString.hasPrefix("AA") && decodedString.hasSuffix("ZZ") else {
            throw DownloadError.thunderProtocolError
        }

        let realURLString = String(decodedString.dropFirst(2).dropLast(2))

        // 5. 创建URL
        guard let url = URL(string: realURLString) else {
            throw DownloadError.thunderProtocolError
        }

        Logger.info("Thunder URL decoded: \(realURLString)")

        return url
    }
}
