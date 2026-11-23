import Foundation
import UIKit

struct NativeIPAToolCookie: Codable, Sendable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expires: Int64
    let maxAge: Int?
    let secure: Bool?
    let httpOnly: Bool?
}

struct NativeIPAToolCookieRecord: Codable, Sendable {
    let url: String
    let cookies: [NativeIPAToolCookie]
}

struct NativeIPAToolAccount: Codable, Sendable {
    let email: String?
    let passwordToken: String?
    let directoryServicesIdentifier: String?
    let name: String?
    let storeFront: String?
    let password: String?
    let pod: String?
}

struct NativeIPAToolRequest: Codable, Sendable {
    let email: String
    let password: String
    let authCode: String
    let deviceIdentifier: String
    let hardwareID: String
    let homeDirectory: String
    let keychain: [String: String]
    let cookies: [NativeIPAToolCookieRecord]
}

struct NativeIPAToolVersionsRequest: Codable, Sendable {
    let appId: String
    let deviceIdentifier: String
    let hardwareID: String
    let homeDirectory: String
    let keychain: [String: String]
    let cookies: [NativeIPAToolCookieRecord]
}

struct NativeIPAToolDownloadRequest: Codable, Sendable {
    let appId: String
    let externalVersionID: String
    let outputPath: String
    let deviceIdentifier: String
    let hardwareID: String
    let homeDirectory: String
    let keychain: [String: String]
    let cookies: [NativeIPAToolCookieRecord]
}

struct NativeIPAToolDownloadResponse: Codable, Sendable {
    let success: Bool
    let error: String?
    let destinationPath: String?
    let bundleIdentifier: String?
    let bundleVersion: String?
    let shortVersion: String?
    let displayName: String?
    let keychain: [String: String]
    let cookies: [NativeIPAToolCookieRecord]

    init(
        success: Bool,
        error: String?,
        destinationPath: String?,
        bundleIdentifier: String?,
        bundleVersion: String?,
        shortVersion: String?,
        displayName: String?,
        keychain: [String: String],
        cookies: [NativeIPAToolCookieRecord]
    ) {
        self.success = success
        self.error = error
        self.destinationPath = destinationPath
        self.bundleIdentifier = bundleIdentifier
        self.bundleVersion = bundleVersion
        self.shortVersion = shortVersion
        self.displayName = displayName
        self.keychain = keychain
        self.cookies = cookies
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = (try? container.decode(Bool.self, forKey: .success)) ?? false
        error = try? container.decode(String.self, forKey: .error)
        destinationPath = try? container.decode(String.self, forKey: .destinationPath)
        bundleIdentifier = try? container.decode(String.self, forKey: .bundleIdentifier)
        bundleVersion = try? container.decode(String.self, forKey: .bundleVersion)
        shortVersion = try? container.decode(String.self, forKey: .shortVersion)
        displayName = try? container.decode(String.self, forKey: .displayName)
        keychain = (try? container.decode([String: String].self, forKey: .keychain)) ?? [:]
        cookies = (try? container.decode([NativeIPAToolCookieRecord].self, forKey: .cookies)) ?? []
    }
}

struct NativeIPAToolVersionsResponse: Codable, Sendable {
    let success: Bool
    let error: String?
    let externalVersionIdentifiers: [String]
    let latestExternalVersionID: String?
    let keychain: [String: String]
    let cookies: [NativeIPAToolCookieRecord]

    init(
        success: Bool,
        error: String?,
        externalVersionIdentifiers: [String],
        latestExternalVersionID: String?,
        keychain: [String: String],
        cookies: [NativeIPAToolCookieRecord]
    ) {
        self.success = success
        self.error = error
        self.externalVersionIdentifiers = externalVersionIdentifiers
        self.latestExternalVersionID = latestExternalVersionID
        self.keychain = keychain
        self.cookies = cookies
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = (try? container.decode(Bool.self, forKey: .success)) ?? false
        error = try? container.decode(String.self, forKey: .error)
        externalVersionIdentifiers = (try? container.decode([String].self, forKey: .externalVersionIdentifiers)) ?? []
        latestExternalVersionID = try? container.decode(String.self, forKey: .latestExternalVersionID)
        keychain = (try? container.decode([String: String].self, forKey: .keychain)) ?? [:]
        cookies = (try? container.decode([NativeIPAToolCookieRecord].self, forKey: .cookies)) ?? []
    }
}

struct NativeIPAToolResponse: Codable, Sendable {
    let success: Bool
    let authCodeRequired: Bool
    let error: String?
    let account: NativeIPAToolAccount?
    let keychain: [String: String]
    let cookies: [NativeIPAToolCookieRecord]
    let hardwareID: String?

    init(
        success: Bool,
        authCodeRequired: Bool,
        error: String?,
        account: NativeIPAToolAccount?,
        keychain: [String: String],
        cookies: [NativeIPAToolCookieRecord],
        hardwareID: String?
    ) {
        self.success = success
        self.authCodeRequired = authCodeRequired
        self.error = error
        self.account = account
        self.keychain = keychain
        self.cookies = cookies
        self.hardwareID = hardwareID
    }

    // Error responses must remain readable even when an older/newer Go bridge
    // omits optional state fields. Preserve the actual Go error instead of
    // replacing it with a generic JSONDecoder "missing key" message.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = (try? container.decode(Bool.self, forKey: .success)) ?? false
        authCodeRequired = (try? container.decode(Bool.self, forKey: .authCodeRequired)) ?? false
        error = try? container.decode(String.self, forKey: .error)
        account = try? container.decode(NativeIPAToolAccount.self, forKey: .account)
        keychain = (try? container.decode([String: String].self, forKey: .keychain)) ?? [:]
        cookies = (try? container.decode([NativeIPAToolCookieRecord].self, forKey: .cookies)) ?? []
        hardwareID = try? container.decode(String.self, forKey: .hardwareID)
    }
}

enum NativeIPAToolBridge {
    static func login(_ request: NativeIPAToolRequest) -> NativeIPAToolResponse {
        do {
            let encoded = try JSONEncoder().encode(request)
            guard let json = String(data: encoded, encoding: .utf8) else {
                return failure("Could not encode the native authentication request")
            }

            print("[SwiftBridge] entering embedded ipatool C bridge")
            let pointer = json.withCString { raw in
                PancakeIPAToolLogin(UnsafeMutablePointer(mutating: raw))
            }
            print("[SwiftBridge] embedded ipatool C bridge returned")
            guard let pointer else {
                return failure("The embedded ipatool bridge returned no result")
            }
            defer { PancakeIPAToolFree(pointer) }

            let responseData = Data(String(cString: pointer).utf8)
            let responseKeys = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
            let keySummary = responseKeys?.keys.sorted().joined(separator: ",") ?? "unavailable"
            print("[SwiftBridge] response bytes: \(responseData.count); fields: \(keySummary)")
            return try JSONDecoder().decode(NativeIPAToolResponse.self, from: responseData)
        } catch {
            return failure("Could not decode native authentication result: \(error.localizedDescription)")
        }
    }

    static func listVersions(_ request: NativeIPAToolVersionsRequest) -> NativeIPAToolVersionsResponse {
        do {
            let encoded = try JSONEncoder().encode(request)
            guard let json = String(data: encoded, encoding: .utf8) else {
                throw NSError(domain: "PancakeIPAToolBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode the version-list request"])
            }

            print("[SwiftBridge] requesting App Store version history through ipatool")
            let pointer = json.withCString { raw in
                PancakeIPAToolListVersions(UnsafeMutablePointer(mutating: raw))
            }
            guard let pointer else {
                throw NSError(domain: "PancakeIPAToolBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "The embedded ipatool bridge returned no version-list result"])
            }
            defer { PancakeIPAToolFree(pointer) }

            let responseData = Data(String(cString: pointer).utf8)
            print("[SwiftBridge] version-list response bytes: \(responseData.count)")
            return try JSONDecoder().decode(NativeIPAToolVersionsResponse.self, from: responseData)
        } catch {
            print("[SwiftBridge] version-list bridge error: \(error.localizedDescription)")
            return NativeIPAToolVersionsResponse(
                success: false,
                error: error.localizedDescription,
                externalVersionIdentifiers: [],
                latestExternalVersionID: nil,
                keychain: [:],
                cookies: []
            )
        }
    }

    static func download(_ request: NativeIPAToolDownloadRequest) -> NativeIPAToolDownloadResponse {
        do {
            let encoded = try JSONEncoder().encode(request)
            guard let json = String(data: encoded, encoding: .utf8) else {
                throw NSError(domain: "PancakeIPAToolBridge", code: 10, userInfo: [NSLocalizedDescriptionKey: "Could not encode the App Store download request"])
            }

            print("[SwiftBridge] requesting App Store IPA through ipatool")
            let pointer = json.withCString { raw in
                PancakeIPAToolDownload(UnsafeMutablePointer(mutating: raw))
            }
            guard let pointer else {
                throw NSError(domain: "PancakeIPAToolBridge", code: 11, userInfo: [NSLocalizedDescriptionKey: "The embedded ipatool bridge returned no download result"])
            }
            defer { PancakeIPAToolFree(pointer) }

            let responseData = Data(String(cString: pointer).utf8)
            print("[SwiftBridge] download response bytes: \(responseData.count)")
            return try JSONDecoder().decode(NativeIPAToolDownloadResponse.self, from: responseData)
        } catch {
            print("[SwiftBridge] download bridge error: \(error.localizedDescription)")
            return NativeIPAToolDownloadResponse(
                success: false,
                error: error.localizedDescription,
                destinationPath: nil,
                bundleIdentifier: nil,
                bundleVersion: nil,
                shortVersion: nil,
                displayName: nil,
                keychain: [:],
                cookies: []
            )
        }
    }

    static func deviceIdentifier() -> String {
        let key = "PancakeStore.ipatool.deviceIdentifier"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let value = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    static func cookies(from records: [NativeIPAToolCookieRecord]) -> [HTTPCookie] {
        records.flatMap { record in
            record.cookies.compactMap { item in
                var properties: [HTTPCookiePropertyKey: Any] = [
                    .name: item.name,
                    .value: item.value,
                    .domain: item.domain,
                    .path: item.path.isEmpty ? "/" : item.path
                ]
                if item.secure == true { properties[.secure] = "TRUE" }
                if item.httpOnly == true { properties[.init("HttpOnly")] = "TRUE" }
                if item.expires > 0 { properties[.expires] = Date(timeIntervalSince1970: TimeInterval(item.expires)) }
                return HTTPCookie(properties: properties)
            }
        }
    }

    private static func failure(_ message: String) -> NativeIPAToolResponse {
        NativeIPAToolResponse(
            success: false,
            authCodeRequired: false,
            error: message,
            account: nil,
            keychain: [:],
            cookies: [],
            hardwareID: nil
        )
    }
}
