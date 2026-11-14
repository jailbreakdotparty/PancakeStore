//
//  AnisetteDataResponse.swift
//  AnisetteKit
//
//  Created by Magesh K on 07/09/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

import Foundation

public struct AnisetteDataResponse: Sendable, Codable, Equatable, Hashable {
    public let oneTimePassword: String
    public let machineID: String

    public init(oneTimePassword: String, machineID: String) {
        self.oneTimePassword = oneTimePassword
        self.machineID = machineID
    }

    public init(from dictionary: [String: String]) throws {
        guard let otp = dictionary[AnisetteConstants.Headers.oneTimePassword],
              let mid = dictionary[AnisetteConstants.Headers.machineID] else 
        {
            throw AnisetteError.invalidResponse(reason: "Missing \(AnisetteConstants.Headers.oneTimePassword) or \(AnisetteConstants.Headers.machineID) from response")
        }
        self.oneTimePassword = otp
        self.machineID = mid
    }
}
