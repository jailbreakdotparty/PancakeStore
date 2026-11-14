//
//  AnisetteRequestHeaders.swift
//  AnisetteKit
//
//  Created by Magesh K on 07/09/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

import Foundation

public struct AnisetteRequestHeaders: Sendable, Codable, Equatable, Hashable {
    public var machineID: String? = nil
    public var oneTimePassword: String? = nil
    public var localUserID: String? = nil
    public var routingInfo: String? = nil
    public var deviceID: String? = nil
    public var serialNumber: String? = nil
    public var clientInfo: String? = nil
    public var userAgent: String? = nil
    public var date: Date? = nil
    public var clientTime: String? = nil
    public var locale: String? = nil
    public var timeZone: String? = nil
    public var contentType: String? = nil
    public var accept: String? = nil
    public var rawHeaders: [String: String] = [:]

    public init() {}

    public init(rawHeaders: [String: String]) {
        self = AnisetteHeadersDTO.toHeaders(from: rawHeaders)
    }

    public static var defaultHeaders: AnisetteRequestHeaders {
        AnisetteRequestHeaders().with {
            $0.localUserID  = AnisetteConstants.defaultLocalUserID
            $0.routingInfo  = AnisetteConstants.defaultRoutingInfo
            $0.serialNumber = AnisetteConstants.defaultSerialNumber
            $0.clientInfo   = AnisetteConstants.defaultClientInfo
            $0.userAgent    = AnisetteConstants.defaultUserAgent
            $0.locale       = AnisetteConstants.defaultLocale
            $0.timeZone     = AnisetteConstants.defaultTimeZone
            $0.contentType  = AnisetteConstants.Headers.contentTypePlist
            $0.accept       = AnisetteConstants.Headers.acceptAll
        }
    }

    public func applyingOverrides(_ overrides: AnisetteRequestHeaders?) -> AnisetteRequestHeaders {
        guard let overrides else { return self }
        var copy = self
        if let v = overrides.machineID       { copy.machineID       = v }
        if let v = overrides.oneTimePassword { copy.oneTimePassword = v }
        if let v = overrides.localUserID     { copy.localUserID     = v }
        if let v = overrides.routingInfo     { copy.routingInfo     = v }
        if let v = overrides.deviceID        { copy.deviceID        = v }
        if let v = overrides.serialNumber    { copy.serialNumber    = v }
        if let v = overrides.clientInfo      { copy.clientInfo      = v }
        if let v = overrides.userAgent       { copy.userAgent       = v }
        if let v = overrides.date            { copy.date            = v }
        if let v = overrides.clientTime      { copy.clientTime      = v }
        if let v = overrides.locale          { copy.locale          = v }
        if let v = overrides.timeZone        { copy.timeZone        = v }
        if let v = overrides.contentType     { copy.contentType     = v }
        if let v = overrides.accept          { copy.accept          = v }
        return copy
    }

    public func with(_ modify: (inout AnisetteRequestHeaders) throws -> Void) rethrows -> AnisetteRequestHeaders {
        var copy = self
        try modify(&copy)
        return copy
    }
}
