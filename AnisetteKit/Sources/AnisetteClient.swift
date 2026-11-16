//
//  AnisetteClient.swift
//  AnisetteKit
//
//  Created by Magesh K on 07/09/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import anisette_core

public enum ProvisioningStorage: Equatable, Sendable {
    case disk
    case memory(existingBlob: Data? = nil)
}

public protocol AnisetteClientProtocol: Sendable {
    func getAnisetteData(
        identifier: UUID,
        storage: ProvisioningStorage,
        headers customHeaders: AnisetteRequestHeaders?
    ) async throws -> (headers: [String: String], newBlob: Data?)
}

public extension AnisetteClientProtocol {
    func getAnisetteData(
        identifier: UUID,
        storage: ProvisioningStorage = .disk,
        headers customHeaders: AnisetteRequestHeaders? = nil
    ) async throws -> (headers: [String: String], newBlob: Data?) {
        try await getAnisetteData(
            identifier: identifier,
            storage: storage,
            headers: customHeaders
        )
    }
}
public typealias LibraryDirectoryResolver = @Sendable () throws -> URL

public class AnisetteClient: AnisetteClientProtocol, @unchecked Sendable {

    let libDir: URL?
    let provisioningDir: URL
    public let clientInfo: String
    public let userAgent: String
    public let lookupURL: URL
    public let requiredLibraries: [String]
    public let provider: any AnisetteDataProvider

    let routingInfoLock = NSLock()
    var routingInfoCache = [UUID: String]()

    public init(
        provisioningDir: URL,
        clientInfo: String = AnisetteConstants.defaultClientInfo,
        userAgent: String = AnisetteConstants.defaultUserAgent,
        lookupURL: URL = AnisetteConstants.URLs.grandSlamLookup,
        requiredLibraries: [String] = AnisetteConstants.Libraries.requiredNames,
        provider: (any AnisetteDataProvider)? = nil,
        libraryDirectoryResolver: LibraryDirectoryResolver? = nil
    ) throws {
        self.provisioningDir = provisioningDir
        self.clientInfo = clientInfo
        self.userAgent = userAgent
        self.lookupURL = lookupURL
        self.requiredLibraries = requiredLibraries

        let resolvedProvider: any AnisetteDataProvider = provider ?? {
            #if os(macOS)
            return NativeAnisetteDataProvider()
            #else
            return UnicornAnisetteDataProvider()
            #endif
        }()
        self.provider = resolvedProvider

        if resolvedProvider.requiresLocalLibraries {
            guard let resolver = libraryDirectoryResolver else {
                throw AnisetteError.librariesNotFound(
                    reason: "A libraryDirectoryResolver is required for \(type(of: resolvedProvider))."
                )
            }
            let resolvedDir = try resolver()
            guard Self.validateLibrariesExist(at: resolvedDir, requiredLibraries: requiredLibraries) else {
                let bulletedLibs = requiredLibraries.map { "  • \($0)" }.joined(separator: "\n")
                throw AnisetteError.librariesNotFound(
                    reason: """
                    Required ADI shared libraries could not be found at: \(resolvedDir.path)
                    \(bulletedLibs)
                    """
                )
            }
            self.libDir = resolvedDir
        } else {
            self.libDir = try? libraryDirectoryResolver?()
        }
    }

    public static func validateLibrariesExist(at directory: URL, requiredLibraries: [String] = AnisetteConstants.Libraries.requiredNames) -> Bool {
        guard let isDir = (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory, isDir else {
            return false
        }
        let fm = FileManager.default
        return requiredLibraries.allSatisfy { libName in
            fm.fileExists(atPath: directory.appendingPathComponent(libName).path)
        }
    }

    public func getAnisetteData(
        identifier: UUID,
        storage: ProvisioningStorage = .disk,
        headers customHeaders: AnisetteRequestHeaders? = nil
    ) async throws -> (headers: [String: String], newBlob: Data?) {
        try await fetchHeaders(identifier: identifier, storage: storage, customHeaders: customHeaders, provider: self.provider)
    }
}

extension AnisetteClient {
    private func getCachedRoutingInfo(for identifier: UUID) -> String? {
        routingInfoLock.withLock {
            routingInfoCache[identifier]
        }
    }

    private func setCachedRoutingInfo(_ rinfo: String, for identifier: UUID) {
        routingInfoLock.withLock {
            routingInfoCache[identifier] = rinfo
        }
    }

    private func fetchHeaders(
        identifier: UUID,
        storage: ProvisioningStorage,
        customHeaders: AnisetteRequestHeaders?,
        provider: any AnisetteDataProvider
    ) async throws -> (headers: [String: String], newBlob: Data?) {
        let (adiPbData, generatedBlob, cleanup) = try await resolveProvisioningBlob(
            identifier: identifier,
            storage: storage,
            headers: customHeaders
        ) {
            try await self.runProvisioningFlow(identifier: identifier, headers: customHeaders, provider: provider)
        }
        defer { cleanup() }

        let response = try await provider.getAnisetteHeaders(
            libDir: libDir?.path ?? "",
            provisioningDir: provisioningDir.path,
            identifier: identifier.uuidBytes,
            adiPb: [UInt8](adiPbData)
        )

        let headers = AnisetteRequestHeaders.defaultHeaders
            .applyingOverrides(customHeaders)
            .with {
                $0.oneTimePassword = response.oneTimePassword
                $0.machineID       = response.machineID
                if $0.deviceID == nil { $0.deviceID = identifier.uuidString.uppercased() }
                if let storedRinfo = getStoredRoutingInfo(for: identifier) { $0.routingInfo = storedRinfo }
                if $0.date == nil && $0.clientTime == nil { $0.date = Date() }
                if customHeaders?.clientInfo == nil { $0.clientInfo = self.clientInfo }
                if customHeaders?.userAgent == nil { $0.userAgent = self.userAgent }
            }

        return (AnisetteHeadersDTO.toDictionary(from: headers), generatedBlob)
    }

    private func resolveProvisioningBlob(
        identifier: UUID,
        storage: ProvisioningStorage,
        headers customHeaders: AnisetteRequestHeaders? = nil,
        provisioner: () async throws -> Data
    ) async throws -> (data: Data, generated: Data?, cleanup: () -> Void) {
        let uuidProvDir = provisioningDir.appendingPathComponent(identifier.uuidString.lowercased())
        let adiPbURL = uuidProvDir.appendingPathComponent(AnisetteConstants.Files.adiPb)
        let rinfoURL = uuidProvDir.appendingPathComponent(AnisetteConstants.Files.rinfo)

        let cleanup: () -> Void = {
            if case .memory = storage {
                try? FileManager.default.removeItem(at: adiPbURL)
                try? FileManager.default.removeItem(at: rinfoURL)
                try? FileManager.default.removeItem(at: uuidProvDir)
            }
        }

        if let customRinfo = customHeaders?.routingInfo, !customRinfo.isEmpty {
            setCachedRoutingInfo(customRinfo, for: identifier)
        }

        switch storage {
        case .disk:
            if !FileManager.default.fileExists(atPath: adiPbURL.path) {
                verboseLog("[AnisetteKit] Native adi.pb missing. Starting automatic local provisioning...")
                let newBlob = try await provisioner()
                try FileManager.default.createDirectory(at: uuidProvDir, withIntermediateDirectories: true, attributes: nil)
                try newBlob.write(to: adiPbURL)
                verboseLog("[AnisetteKit] Provisioning successful! Saved adi.pb locally.")
                return (newBlob, newBlob, cleanup)
            } else {
                let data = try Data(contentsOf: adiPbURL)
                return (data, nil, cleanup)
            }

        case .memory(let existing):
            if let provided = existing, !provided.isEmpty {
                return (provided, nil, cleanup)
            } else {
                verboseLog("[AnisetteKit] Native adi.pb missing in-memory. Starting automatic local provisioning in-memory...")
                let newBlob = try await provisioner()
                return (newBlob, newBlob, cleanup)
            }
        }
    }

    private func getStoredRoutingInfo(for identifier: UUID) -> String? {
        if let cached = getCachedRoutingInfo(for: identifier) {
            return cached
        }
        let uuidProvDir = provisioningDir.appendingPathComponent(identifier.uuidString.lowercased())
        let rinfoURL = uuidProvDir.appendingPathComponent(AnisetteConstants.Files.rinfo)
        if let saved = try? String(contentsOf: rinfoURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            setCachedRoutingInfo(saved, for: identifier)
            return saved
        }
        return nil
    }

    func runProvisioningFlow(
        identifier: UUID,
        headers customHeaders: AnisetteRequestHeaders? = nil,
        provider: any AnisetteDataProvider
    ) async throws -> Data {
        verboseLog("[AnisetteKit] Fetching provisioning URLs from Apple lookup...")
        let lookupURL = self.lookupURL
        let lookupReq = createRequest(url: lookupURL, identifier: identifier, httpMethod: "GET", routingInfo: nil as String?, headers: customHeaders)

        let (lookupData, lookupResp) = try await sendRequest(lookupReq, step: "Lookup", endpointName: "Apple lookup")
        var activeRoutingInfo = extractRoutingInfo(from: lookupResp, data: lookupData) ?? customHeaders?.routingInfo

        guard let plist = try PropertyListSerialization.propertyList(from: lookupData, options: [], format: nil) as? [String: Any],
              let urls = plist["urls"] as? [String: String],
              let startURLString = urls["midStartProvisioning"],
              let startURL = URL(string: startURLString),
              let endURLString = urls["midFinishProvisioning"],
              let endURL = URL(string: endURLString) else {
            debugLog("[AnisetteKit] ERROR: Failed to parse provisioning URLs from lookup")
            throw AnisetteError.invalidResponse(reason: "Failed to parse provisioning URLs from lookup")
        }
        verboseLog("[AnisetteKit] Got start URL: \(startURLString)")

        verboseLog("[AnisetteKit] Fetching SPIM from Apple...")
        let (spim, spimRinfo) = try await fetchSpim(startURL: startURL, identifier: identifier, routingInfo: activeRoutingInfo, headers: customHeaders)
        if let spimRinfo = spimRinfo { activeRoutingInfo = spimRinfo }
        verboseLog("[AnisetteKit] Got SPIM (\(spim.count) bytes). Running local start_provision...")

        let provResult = try await provider.startProvision(
            libDir: libDir?.path ?? "",
            provisioningDir: provisioningDir.path,
            identifier: identifier.uuidBytes,
            spim: [UInt8](spim)
        )
        verboseLog("[AnisetteKit] start_provision OK — session=\(provResult.session), cpim=\(provResult.cpim.count) bytes")

        verboseLog("[AnisetteKit] Sending CPIM to Apple finish provisioning...")
        let (ptm, tk, ptmRinfo) = try await fetchPtmTk(endURL: endURL, cpim: provResult.cpim, identifier: identifier, routingInfo: activeRoutingInfo, headers: customHeaders)
        if let ptmRinfo = ptmRinfo { activeRoutingInfo = ptmRinfo }
        verboseLog("[AnisetteKit] Got PTM (\(ptm.count) bytes) and TK (\(tk.count) bytes). Running local end_provision...")

        let adiPb = try await provider.endProvision(
            libDir: libDir?.path ?? "",
            provisioningDir: provisioningDir.path,
            identifier: identifier.uuidBytes,
            session: provResult.session,
            ptm: [UInt8](ptm),
            tk: [UInt8](tk)
        )
        verboseLog("[AnisetteKit] end_provision OK — adi.pb size=\(adiPb.count) bytes")

        if let finalRinfo = activeRoutingInfo {
            setCachedRoutingInfo(finalRinfo, for: identifier)
            let uuidProvDir = provisioningDir.appendingPathComponent(identifier.uuidString.lowercased())
            try? FileManager.default.createDirectory(at: uuidProvDir, withIntermediateDirectories: true, attributes: nil)
            let rinfoURL = uuidProvDir.appendingPathComponent(AnisetteConstants.Files.rinfo)
            try? finalRinfo.write(to: rinfoURL, atomically: true, encoding: String.Encoding.utf8)
        }

        return adiPb
    }

    private func extractRoutingInfo(from response: URLResponse?, data: Data? = nil) -> String? {
        if let httpResp = response as? HTTPURLResponse {
            for (k, v) in httpResp.allHeaderFields {
                if String(describing: k).caseInsensitiveCompare(AnisetteConstants.Headers.routingInfo) == .orderedSame,
                   let str = v as? String, !str.isEmpty {
                    return str
                }
            }
        }
        if let data = data,
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let responseDict = plist["Response"] as? [String: Any] {
            if let str = responseDict["routing-info"] as? String, !str.isEmpty {
                return str
            }
            if let num = responseDict["routing-info"] as? NSNumber {
                return num.stringValue
            }
        }
        return nil
    }

    private func sendRequest(_ req: URLRequest, step: String, endpointName: String) async throws -> (data: Data, response: URLResponse) {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? -1
        verboseLog("[AnisetteKit] \(step) HTTP status: \(statusCode)")
        guard statusCode == 200 else {
            throw AnisetteError.httpError(statusCode: statusCode, message: "\(endpointName) endpoint returned HTTP \(statusCode)")
        }
        return (data, resp)
    }

    private func createRequest(
        url: URL,
        identifier: UUID,
        httpMethod: String,
        routingInfo: String?,
        headers customHeaders: AnisetteRequestHeaders?
    ) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = httpMethod

        let headers = AnisetteRequestHeaders.defaultHeaders
            .applyingOverrides(customHeaders)
            .with {
                if $0.deviceID == nil { $0.deviceID = identifier.uuidString.uppercased() }
                if let routingInfo { $0.routingInfo = routingInfo }
                if $0.date == nil && $0.clientTime == nil { $0.date = Date() }
                if customHeaders?.clientInfo == nil { $0.clientInfo = self.clientInfo }
                if customHeaders?.userAgent == nil { $0.userAgent = self.userAgent }
            }

        let dict = AnisetteHeadersDTO.toDictionary(from: headers)
        for (k, v) in dict {
            req.setValue(v, forHTTPHeaderField: k)
        }

        return req
    }

    private func fetchSpim(startURL: URL, identifier: UUID, routingInfo: String? = nil, headers customHeaders: AnisetteRequestHeaders? = nil) async throws -> (spim: Data, routingInfo: String?) {
        var req = createRequest(url: startURL, identifier: identifier, httpMethod: "POST", routingInfo: routingInfo, headers: customHeaders)
        req.httpBody = try? PropertyListSerialization.data(fromPropertyList: ["Header": [:], "Request": [:]] as [String: Any], format: .xml, options: 0)

        let (data, resp) = try await sendRequest(req, step: "fetchSpim", endpointName: "Apple SPIM")
        let discoveredRinfo = extractRoutingInfo(from: resp, data: data)

        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let response = plist["Response"] as? [String: Any],
              let spimString = response["spim"] as? String,
              let spimData = Data(base64Encoded: spimString) else {
            debugLog("[AnisetteKit] fetchSpim ERROR: plist keys: \((try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])?.keys.joined(separator: ", ") ?? "?")")
            throw AnisetteError.invalidResponse(reason: "Failed to parse spim from Apple response")
        }
        verboseLog("[AnisetteKit] fetchSpim got spim (\(spimData.count) bytes)")
        return (spimData, discoveredRinfo)
    }

    private func fetchPtmTk(endURL: URL, cpim: Data, identifier: UUID, routingInfo: String? = nil, headers customHeaders: AnisetteRequestHeaders? = nil) async throws -> (ptm: Data, tk: Data, routingInfo: String?) {
        var req = createRequest(url: endURL, identifier: identifier, httpMethod: "POST", routingInfo: routingInfo, headers: customHeaders)
        req.httpBody = try? PropertyListSerialization.data(fromPropertyList: ["Header": [:], "Request": ["cpim": cpim.base64EncodedString()]] as [String: Any], format: .xml, options: 0)

        verboseLog("[AnisetteKit] fetchPtmTk posting cpim to Apple...")
        let (data, resp) = try await sendRequest(req, step: "fetchPtmTk", endpointName: "Apple PTM/TK")
        let discoveredRinfo = extractRoutingInfo(from: resp, data: data)

        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let response = plist["Response"] as? [String: Any],
              let ptmString = response["ptm"] as? String,
              let tkString = response["tk"] as? String,
              let ptm = Data(base64Encoded: ptmString),
              let tk = Data(base64Encoded: tkString) else {
            debugLog("[AnisetteKit] fetchPtmTk ERROR: plist keys: \((try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])?.keys.joined(separator: ", ") ?? "?")")
            throw AnisetteError.invalidResponse(reason: "Failed to parse ptm/tk from Apple response")
        }
        verboseLog("[AnisetteKit] fetchPtmTk got ptm (\(ptm.count) bytes), tk (\(tk.count) bytes)")
        return (ptm, tk, discoveredRinfo)
    }
}
