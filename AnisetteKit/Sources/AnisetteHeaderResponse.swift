//
//  AnisetteHeaderResponse.swift
//  AnisetteKit
//
//  Created by Magesh K on 07/09/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

import Foundation

public struct AnisetteHeaderResponse: Sendable, Codable, Equatable, Hashable {
    public let oneTimePassword: String
    public let machineID: String

    public init(oneTimePassword: String, machineID: String) {
        self.oneTimePassword = oneTimePassword
        self.machineID = machineID
    }
}
