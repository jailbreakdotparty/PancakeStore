//
//  AnisetteError.swift
//  AnisetteKit
//
//  Created by Magesh K on 07/09/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

import Foundation

public enum AnisetteError: LocalizedError, Equatable, Sendable {
    case invalidArgument
    case loaderFailed(reason: String)
    case symbolMissing(name: String)
    case readFailure
    case invalidResponse(reason: String)
    case adiError(code: Int32, description: String)
    case librariesNotFound(reason: String)
    case httpError(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidArgument:
            return "Invalid argument passed to Anisette provider."
        case .loaderFailed(let reason):
            return "Native loader failure: \(reason)"
        case .symbolMissing(let name):
            return "Required native ADI symbol '\(name)' missing."
        case .readFailure:
            return "Failed to read generated provisioning data (adi.pb)."
        case .invalidResponse(let reason):
            return "Invalid response from Apple provisioning service: \(reason)"
        case .adiError(let code, let description):
            return "ADI native error (\(code)): \(description)"
        case .librariesNotFound(let reason):
            return "ADI libraries missing: \(reason)"
        case .httpError(let statusCode, let message):
            return "HTTP error (\(statusCode)): \(message)"
        }
    }
}
