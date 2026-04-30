//
//  M3U8Parser.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation

/// M3U8解析器
class M3U8Parser {

    /// 解析M3U8文件
    func parse(content: String, baseURL: URL) throws -> M3U8Playlist {
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // 检查M3U8标识
        guard lines.first == "#EXTM3U" else {
            throw DownloadError.invalidM3U8Format
        }

        // 判断是Master Playlist还是Media Playlist
        if isMasterPlaylist(lines: lines) {
            return try parseMasterPlaylist(lines: lines, baseURL: baseURL)
        } else {
            return try parseMediaPlaylist(lines: lines, baseURL: baseURL)
        }
    }

    // MARK: - Private Methods

    /// 判断是否为Master Playlist
    private func isMasterPlaylist(lines: [String]) -> Bool {
        return lines.contains { line in
            line.hasPrefix("#EXT-X-STREAM-INF")
        }
    }

    /// 解析Master Playlist（多码率列表）
    private func parseMasterPlaylist(lines: [String], baseURL: URL) throws -> M3U8MasterPlaylist {
        var variants: [M3U8Variant] = []

        for i in 0..<lines.count {
            let line = lines[i]

            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                // 解析变体流信息
                let bandwidth = extractBandwidth(from: line)
                let resolution = extractResolution(from: line)

                // 下一行是URL
                if i + 1 < lines.count {
                    let urlString = lines[i + 1]
                    guard let url = resolveURL(urlString, baseURL: baseURL) else {
                        continue
                    }
                    variants.append(M3U8Variant(
                        bandwidth: bandwidth,
                        resolution: resolution,
                        url: url
                    ))
                }
            }
        }

        guard !variants.isEmpty else {
            throw DownloadError.invalidM3U8Format
        }

        return M3U8MasterPlaylist(variants: variants)
    }

    /// 解析Media Playlist（TS片段列表）
    private func parseMediaPlaylist(lines: [String], baseURL: URL) throws -> M3U8MediaPlaylist {
        var segments: [M3U8Segment] = []
        var duration: Double = 0
        var encryptionInfo: M3U8Encryption?
        var targetDuration: Double = 0
        var version: Int?

        for i in 0..<lines.count {
            let line = lines[i]

            // 解析版本
            if line.hasPrefix("#EXT-X-VERSION:") {
                version = Int(line.replacingOccurrences(of: "#EXT-X-VERSION:", with: ""))
            }

            // 解析目标时长
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = Double(line.replacingOccurrences(of: "#EXT-X-TARGETDURATION:", with: "")) ?? 0
            }

            // 解析加密信息
            if line.hasPrefix("#EXT-X-KEY:") {
                encryptionInfo = try parseEncryptionInfo(line: line, baseURL: baseURL)
            }

            // 解析片段时长
            if line.hasPrefix("#EXTINF:") {
                let durationString = line.replacingOccurrences(of: "#EXTINF:", with: "")
                duration = Double(durationString.components(separatedBy: ",").first ?? "0") ?? 0
            }

            // 解析片段URL（不以#开头的行）
            if !line.hasPrefix("#") && line.count > 0 {
                guard let url = resolveURL(line, baseURL: baseURL) else {
                    continue
                }
                segments.append(M3U8Segment(
                    url: url,
                    duration: duration,
                    encryption: encryptionInfo
                ))
            }
        }

        guard !segments.isEmpty else {
            throw DownloadError.invalidM3U8Format
        }

        let isEncrypted = segments.contains { $0.encryption != nil }

        return M3U8MediaPlaylist(
            segments: segments,
            targetDuration: targetDuration,
            isEncrypted: isEncrypted,
            version: version
        )
    }

    /// 解析加密信息
    private func parseEncryptionInfo(line: String, baseURL: URL) throws -> M3U8Encryption? {
        // 示例: #EXT-X-KEY:METHOD=AES-128,URI="key.key",IV=0x...

        guard line.contains("METHOD=") else {
            return nil
        }

        // 提取加密方法
        let method: M3U8EncryptionMethod
        if line.contains("METHOD=AES-128") {
            method = .aes128
        } else if line.contains("METHOD=SAMPLE-AES") {
            method = .sampleAES
        } else {
            method = .none
        }

        // 提取密钥URI
        guard let uriMatch = extractValue(line: line, key: "URI") else {
            return nil
        }

        let keyURL: URL
        if uriMatch.hasPrefix("http") {
            keyURL = URL(string: uriMatch)!
        } else {
            keyURL = baseURL.deletingLastPathComponent().appendingPathComponent(uriMatch)
        }

        // 提取IV（初始化向量）
        var iv: Data? = nil
        if let ivHex = extractValue(line: line, key: "IV") {
            let hex = ivHex.replacingOccurrences(of: "0x", with: "")
            iv = Data(hex: hex)
        }

        return M3U8Encryption(method: method, keyURL: keyURL, iv: iv)
    }

    /// 从行中提取带宽
    private func extractBandwidth(from line: String) -> Int {
        guard let bandwidthString = extractValue(line: line, key: "BANDWIDTH") else {
            return 0
        }
        return Int(bandwidthString) ?? 0
    }

    /// 从行中提取分辨率
    private func extractResolution(from line: String) -> String? {
        return extractValue(line: line, key: "RESOLUTION")
    }

    /// 从行中提取指定键的值
    private func extractValue(line: String, key: String) -> String? {
        let pattern = key + "=(.+?)(,|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range) else {
            return nil
        }

        let valueRange = Range(match.range(at: 1), in: line)!
        var value = String(line[valueRange])

        // 去除引号
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        return value
    }

    /// 解析相对URL
    private func resolveURL(_ urlString: String, baseURL: URL) -> URL? {
        if urlString.hasPrefix("http") {
            return URL(string: urlString)
        } else {
            return baseURL.deletingLastPathComponent().appendingPathComponent(urlString)
        }
    }
}

// MARK: - Data Extension for Hex String

extension Data {
    init(hex: String) {
        let hexString = hex.replacingOccurrences(of: " ", with: "").lowercased()
        var data = Data(capacity: hexString.count / 2)

        var index = hexString.startIndex
        while index < hexString.endIndex {
            let nextIndex = hexString.index(index, offsetBy: 2)
            if nextIndex > hexString.endIndex {
                break
            }

            let byteString = String(hexString[index..<nextIndex])
            if let byte = UInt8(byteString, radix: 16) {
                data.append(byte)
            }

            index = nextIndex
        }

        self = data
    }
}
