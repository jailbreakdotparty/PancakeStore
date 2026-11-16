//
//  AnisetteKit.swift
//  AnisetteKit
//
//  Created by Magesh K on 20/07/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

import Foundation

// for linux, win
#if canImport(FoundationNetworking)
import FoundationNetworking

extension URLSession {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = self.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, let response = response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.unknown))
                }
            }
            task.resume()
        }
    }
}
#endif

extension UUID {
    var uuidBytes: [UInt8] {
        withUnsafeBytes(of: uuid) { Array($0) }
    }
}

public func safeTimeZoneAbbreviation(for timeZone: TimeZone, date: Date = Date()) -> String {
    guard let abbr = timeZone.abbreviation(for: date), !abbr.isEmpty else {
        return AnisetteConstants.defaultTimeZone
    }
    if abbr.contains("+") || abbr.contains("-") || abbr.contains(":") || abbr.count > 5 {
        return AnisetteConstants.defaultTimeZone
    }
    return abbr
}
