//
//  NetworkMonitor.swift
//  DownLoad
//
//  Created on 2026/6/20.
//

import Foundation
import Combine
import Network

/// 网络状态
enum NetworkStatus: Equatable {
    case unavailable          // 无网络
    case wifi                 // WiFi 连接
    case cellular             // 蜂窝连接
    case unknown              // 未知状态

    var isAvailable: Bool {
        self != .unavailable
    }

    var isCellular: Bool {
        self == .cellular
    }
}

/// 网络监控器
/// 使用 NWPathMonitor 实时监控网络状态变化，通过 Combine 发布状态变更事件
final class NetworkMonitor {

    static let shared = NetworkMonitor()

    // MARK: - Published Properties

    /// 当前网络状态（Combine 发布，记录真实网络状态）
    let currentStatus = CurrentValueSubject<NetworkStatus, Never>(.unknown)

    /// 网络状态变更事件流（仅在真实网络状态变化时触发）
    let statusChanged = PassthroughSubject<NetworkStatus, Never>()

    /// 是否允许蜂窝网络下载（默认 true，用户可在设置中关闭）
    var isCellularAllowed: Bool = true {
        didSet {
            // 当蜂窝策略变更时，重新评估网络可用性
            evaluateNetworkAvailability()
        }
    }

    /// 网络是否可用于下载（综合判断：有网络 + 蜂窝策略）
    var isNetworkAvailableForDownload: Bool {
        let status = currentStatus.value
        if status == .unavailable { return false }
        if status == .cellular && !isCellularAllowed { return false }
        return true
    }

    // MARK: - Private Properties

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.video.downloader.network.monitor", qos: .utility)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            let status: NetworkStatus
            switch path.status {
            case .satisfied:
                if path.usesInterfaceType(.wifi) {
                    status = .wifi
                } else if path.usesInterfaceType(.cellular) {
                    status = .cellular
                } else {
                    // 其他接口类型（如有线等）视为可用
                    status = .wifi
                }
            case .unsatisfied:
                status = .unavailable
            case .requiresConnection:
                status = .unavailable
            @unknown default:
                status = .unknown
            }

            // 在主线程发布状态变更
            DispatchQueue.main.async {
                let oldStatus = self.currentStatus.value
                self.currentStatus.send(status)

                if oldStatus != status {
                    AppLogger.info("Network status changed: \(oldStatus) -> \(status)")
                    self.statusChanged.send(status)
                }
            }
        }

        monitor.start(queue: monitorQueue)
    }

    deinit {
        monitor.cancel()
    }

    // MARK: - Private Methods

    /// 当蜂窝下载策略变更时，重新评估网络可用性
    /// 如果当前是蜂窝网络且不允许蜂窝下载，发送不可用通知
    private func evaluateNetworkAvailability() {
        let status = currentStatus.value
        if status == .cellular {
            if !isCellularAllowed {
                AppLogger.info("Cellular download disabled, network treated as unavailable for downloads")
                // 发送蜂窝受限事件，触发引擎暂停下载
                DispatchQueue.main.async {
                    self.statusChanged.send(status)
                }
            } else {
                AppLogger.info("Cellular download enabled, network available for downloads")
                // 发送蜂窝可用事件，触发引擎恢复下载
                DispatchQueue.main.async {
                    self.statusChanged.send(status)
                }
            }
        }
    }
}
