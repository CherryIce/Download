//
//  Logger.swift
//  DownLoad
//
//  Created by hubin on 2026/4/29.
//

import Foundation
import os.log

struct Logger {
    private static let subsystem = "com.download.videodownloader"

    static func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let logger = OSLog(subsystem: subsystem, category: "Info")
        let fileName = (file as NSString).lastPathComponent
        os_log("[%@:%d] %@ - %@", log: logger, type: .info, fileName, line, function, message)
    }

    static func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let logger = OSLog(subsystem: subsystem, category: "Error")
        let fileName = (file as NSString).lastPathComponent
        os_log("[%@:%d] %@ - %@", log: logger, type: .error, fileName, line, function, message)
    }

    static func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        let logger = OSLog(subsystem: subsystem, category: "Debug")
        let fileName = (file as NSString).lastPathComponent
        os_log("[%@:%d] %@ - %@", log: logger, type: .debug, fileName, line, function, message)
        #endif
    }
}
