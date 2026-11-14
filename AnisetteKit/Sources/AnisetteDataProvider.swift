//
//  AnisetteDataProvider.swift
//  AnisetteKit
//
//  Created by Magesh K on 07/09/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

import Foundation
import anisette_core


public protocol AnisetteDataProvider: Sendable {
    var requiresLocalLibraries: Bool { get }
    func getAnisetteHeaders(libDir: String, provisioningDir: String, identifier: [UInt8], adiPb: [UInt8]) async throws -> AnisetteDataResponse
    func startProvision(libDir: String, provisioningDir: String, identifier: [UInt8], spim: [UInt8]) async throws -> (cpim: Data, session: UInt32)
    func endProvision(libDir: String, provisioningDir: String, identifier: [UInt8], session: UInt32, ptm: [UInt8], tk: [UInt8]) async throws -> Data
}

public typealias CStringPointer = UnsafeMutablePointer<CChar>

extension AnisetteDataProvider {
    func parseHeadersResponse(code: Int32, outPtr: CStringPointer?, providerName: String) throws -> AnisetteDataResponse {
        guard let ptr = outPtr else {
            throw AnisetteError.loaderFailed(reason: "\(providerName) loader returned nil (code: \(code))")
        }
        let dict = try parseJSONString(String(cString: ptr))
        if let err = dict["error"] {
            throw AnisetteError.adiError(code: code, description: err)
        }
        return try AnisetteDataResponse(from: dict)
    }

    func parseStartProvisionResponse(code: Int32, outPtr: CStringPointer?, providerName: String) throws -> (cpim: Data, session: UInt32) {
        guard let ptr = outPtr else {
            throw AnisetteError.loaderFailed(reason: "\(providerName) loader returned nil (code: \(code))")
        }
        let jsonData = String(cString: ptr).data(using: .utf8)!
        guard let dict = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw AnisetteError.invalidResponse(reason: "Bad JSON from start_provision")
        }
        if let err = dict["error"] as? String {
            throw AnisetteError.adiError(code: code, description: err)
        }
        guard let cpimBase64 = dict["cpim_base64"] as? String,
              let cpim = Data(base64Encoded: cpimBase64),
              let session = (dict["session"] as? NSNumber)?.uint32Value else 
        {
            throw AnisetteError.invalidResponse(reason: "Missing/invalid cpim_base64 or session")
        }
        return (cpim, session)
    }

    func parseEndProvisionResponse(code: Int32, outPtr: CStringPointer?, providerName: String) throws -> Data {
        guard let ptr = outPtr else {
            throw AnisetteError.loaderFailed(reason: "\(providerName) loader returned nil (code: \(code))")
        }
        let dict = try parseJSONString(String(cString: ptr))
        if let err = dict["error"] {
            throw AnisetteError.adiError(code: code, description: err)
        }
        guard let adiPbBase64 = dict["adi_pb_base64"], let adiPb = Data(base64Encoded: adiPbBase64) else {
            throw AnisetteError.invalidResponse(reason: "Missing/invalid adi_pb_base64")
        }
        return adiPb
    }

    private func parseJSONString(_ s: String) throws -> [String: String] {
        let data = s.data(using: .utf8)!
        return (try JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
    }
}

public struct UnicornAnisetteDataProvider: AnisetteDataProvider {
    public var requiresLocalLibraries: Bool { true }

    public init() {}

    public func getAnisetteHeaders(libDir: String, provisioningDir: String, identifier: [UInt8], adiPb: [UInt8]) throws -> AnisetteDataResponse {
        var outPtr: CStringPointer? = nil
        let res = get_anisette_headers_uc(libDir, provisioningDir, identifier, adiPb, UInt32(adiPb.count), &outPtr)
        defer { if let p = outPtr { free_c_string(p) } }
        return try parseHeadersResponse(code: res, outPtr: outPtr, providerName: "Unicorn")
    }

    public func startProvision(libDir: String, provisioningDir: String, identifier: [UInt8], spim: [UInt8]) throws -> (cpim: Data, session: UInt32) {
        var outPtr: CStringPointer? = nil
        let res = start_provision_uc(libDir, provisioningDir, identifier, spim, UInt32(spim.count), &outPtr)
        defer { if let p = outPtr { free_c_string(p) } }
        return try parseStartProvisionResponse(code: res, outPtr: outPtr, providerName: "Unicorn")
    }

    public func endProvision(libDir: String, provisioningDir: String, identifier: [UInt8], session: UInt32, ptm: [UInt8], tk: [UInt8]) throws -> Data {
        var outPtr: CStringPointer? = nil
        let res = end_provision_uc(libDir, provisioningDir, identifier, session, ptm, UInt32(ptm.count), tk, UInt32(tk.count), &outPtr)
        defer { if let p = outPtr { free_c_string(p) } }
        return try parseEndProvisionResponse(code: res, outPtr: outPtr, providerName: "Unicorn")
    }
}

#if os(macOS)
public struct NativeAnisetteDataProvider: AnisetteDataProvider {
    public var requiresLocalLibraries: Bool { true }

    public init() {}

    public func getAnisetteHeaders(libDir: String, provisioningDir: String, identifier: [UInt8], adiPb: [UInt8]) throws -> AnisetteDataResponse {
        var outPtr: CStringPointer? = nil
        let res = get_anisette_headers_c(libDir, provisioningDir, identifier, adiPb, UInt32(adiPb.count), &outPtr)
        defer { if let p = outPtr { free_c_string(p) } }
        return try parseHeadersResponse(code: res, outPtr: outPtr, providerName: "Native")
    }

    public func startProvision(libDir: String, provisioningDir: String, identifier: [UInt8], spim: [UInt8]) throws -> (cpim: Data, session: UInt32) {
        var outPtr: CStringPointer? = nil
        let res = start_provision_c(libDir, provisioningDir, identifier, spim, UInt32(spim.count), &outPtr)
        defer { if let p = outPtr { free_c_string(p) } }
        return try parseStartProvisionResponse(code: res, outPtr: outPtr, providerName: "Native")
    }

    public func endProvision(libDir: String, provisioningDir: String, identifier: [UInt8], session: UInt32, ptm: [UInt8], tk: [UInt8]) throws -> Data {
        var outPtr: CStringPointer? = nil
        let res = end_provision_c(libDir, provisioningDir, identifier, session, ptm, UInt32(ptm.count), tk, UInt32(tk.count), &outPtr)
        defer { if let p = outPtr { free_c_string(p) } }
        return try parseEndProvisionResponse(code: res, outPtr: outPtr, providerName: "Native")
    }
}
#endif
