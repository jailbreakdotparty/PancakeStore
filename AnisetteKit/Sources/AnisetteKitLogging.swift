//
//  AnisetteKitLogging.swift
//  AnisetteKit
//
//  Created by Magesh K on 17/08/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

import Foundation
import anisette_core

public enum AnisetteKitLogging {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var isEnabled: Bool = false

    public static var isLoggingEnabled: Bool {
        lock.withLock { isEnabled }
    }

    public static func setLogging(_ enabled: Bool) {
        lock.withLock { isEnabled = enabled }
        anisetteCoreSetLogging(enabled ? 1 : 0)
        #if os(Windows)
        if enabled {
            _putenv("UNICORN_LOG_LEVEL=0xFFFFFFFF")
            _putenv("UNICORN_LOG_DETAIL_LEVEL=2")
        } else {
            _putenv("UNICORN_LOG_LEVEL=0")
        }
        #else
        if enabled {
            setenv("UNICORN_LOG_LEVEL", "0xFFFFFFFF", 1)
            setenv("UNICORN_LOG_DETAIL_LEVEL", "2", 1)
        } else {
            setenv("UNICORN_LOG_LEVEL", "0", 1)
        }
        #endif
    }
}

private func getFastTimestamp() -> String {
    let now = Date()
    let cal = Calendar.current
    let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: now)
    let ms = (comps.nanosecond ?? 0) / 1_000_000
    return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03d",
                  comps.year ?? 0, comps.month ?? 0, comps.day ?? 0,
                  comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0,
                  ms)
}

private func getTag(level: String) -> String {
    let timestamp = getFastTimestamp()
    return "\(timestamp) \(level): "
}

public func debugLog(_ text: @autoclosure () -> String) {
    let message = formatLogMessage(text())
    if !message.isEmpty && message.allSatisfy({ $0 == "\n" || $0 == "\r" }) {
        print(message, terminator: "")
    } else {
        print("\(getTag(level: "[D]"))\(message)")
    }
}

public func verboseLog(_ text: @autoclosure () -> String) {
    if AnisetteKitLogging.isLoggingEnabled {
        let message = formatLogMessage(text())
        if !message.isEmpty && message.allSatisfy({ $0 == "\n" || $0 == "\r" }) {
            print(message, terminator: "")
        } else {
            print("\(getTag(level: "[V]"))\(message)")
        }
    }
}

public func formatLogMessage(_ message: String) -> String {
    guard message.contains("UserInfo=") || 
          message.contains("NSURLErrorDomain") || 
          message.contains("NSErrorFailingURLStringKey=") ||
          message.contains("Error Domain=") else 
    {
        return message
    }
    
    var failingURL: String? = nil
    if let urlMatch = message.range(of: "NSErrorFailingURLStringKey=([^,}\\s]+)", options: .regularExpression) {
        let extracted = String(message[urlMatch])
        failingURL = extracted.replacingOccurrences(of: "NSErrorFailingURLStringKey=", with: "")
    } else if let urlMatch = message.range(of: "NSErrorFailingURL=([^,}\\s]+)", options: .regularExpression) {
        let extracted = String(message[urlMatch])
        failingURL = extracted.replacingOccurrences(of: "NSErrorFailingURL=", with: "")
    }
    
    var domain: String? = nil
    if let domainMatch = message.range(of: "Error Domain=([^\\s,]+)", options: .regularExpression) {
        let extracted = String(message[domainMatch])
        domain = extracted.replacingOccurrences(of: "Error Domain=", with: "")
    }
    
    var code: String? = nil
    if let codeMatch = message.range(of: "Code=(-?\\d+)", options: .regularExpression) {
        let extracted = String(message[codeMatch])
        code = extracted.replacingOccurrences(of: "Code=", with: "")
    }
    
    var desc: String? = nil
    if let descMatch = message.range(of: "\"([^\"]+)\"", options: .regularExpression) {
        desc = String(message[descMatch]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    } else if let descMatch = message.range(of: "NSLocalizedDescription=([^,}\n]+)", options: .regularExpression) {
        desc = String(message[descMatch]).replacingOccurrences(of: "NSLocalizedDescription=", with: "")
    }
    
    var streamCode: String? = nil
    if let streamMatch = message.range(of: "_kCFStreamErrorCodeKey=(\\d+)", options: .regularExpression) {
        streamCode = String(message[streamMatch]).replacingOccurrences(of: "_kCFStreamErrorCodeKey=", with: "")
    }
    
    var header = message
    if let range = message.range(of: "Error Domain=") {
        header = String(message[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    } else if let range = message.range(of: "UserInfo=") {
        header = String(message[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if header.hasSuffix(",") || header.hasSuffix(":") {
        header = String(header.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if header.contains("Failed to load image data") && header.contains("Error loading image") {
        header = header.replacingOccurrences(of: ": Failed to load image data", with: "")
    }
    if let desc = desc, !header.contains(desc) {
        header += ": \(desc)"
    }
    
    var bullets: [String] = [header]
    if let url = failingURL, !url.isEmpty {
        bullets.append("  • url: '\(url)'")
    }
    if let dom = domain, !dom.isEmpty {
        bullets.append("  • domain: '\(dom)'")
    }
    if let c = code {
        bullets.append("  • code: \(c)")
    }
    if let stream = streamCode {
        bullets.append("  • streamErrorCode: \(stream)")
    }
    
    return bullets.joined(separator: "\n")
}
