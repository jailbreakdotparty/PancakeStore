//
//  IPATool.swift
//  MuffinStoreJailed
//
//  Created by Mineek on 19/10/2024.
//

// Heavily inspired by ipatool-py.
// https://github.com/NyaMisty/ipatool-py

import Foundation
import CommonCrypto
import Zip
import SwiftUI
import PartyUI
import SAPKit

extension Data {
    var hexString: String {
        return map { String(format: "%02x", $0) }.joined()
    }
}

class SHA1 {
    static func hash(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest)
    }
}

extension String {
    subscript (i: Int) -> String {
        return String(self[index(startIndex, offsetBy: i)])
    }

    subscript (r: Range<Int>) -> String {
        let start = index(startIndex, offsetBy: r.lowerBound)
        let end = index(startIndex, offsetBy: r.upperBound)
        return String(self[start..<end])
    }
}

/// Store requests must not follow redirects automatically: login redirects keep
/// the same signed payload and are allowlisted (ipatool NoRedirects).
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum StoreConstants {
    // Configurator 2.21 gets the native auth endpoint from the bag (ipatool v2.8.0).
    static let userAgent = "Configurator/2.21 (Macintosh; OS X 27.0.1; 26A434) AppleWebKit/0625.2.5.11.6"
    static let nativeAuthHost = "auth.itunes.apple.com"
    static let nativeAuthPaths: Set<String> = ["/auth/v1/native", "/auth/v1/native/", "/auth/v1/native/fast", "/auth/v1/native/fast/"]
    static let legacyAuthPath = "/WebObjects/MZFinance.woa/wa/authenticate"
    static let fallbackAuthEndpoint = "https://auth.itunes.apple.com/auth/v1/native"
    static let badLoginMessage = "MZFinance.BadLogin.Configurator_message"
    static let invalidCredentials = "-5000"
    static let maxRedirects = 4
}

struct StoreBag {
    let endpoint: URL
    let sapSetup: URL
    let sapCertificate: URL
    let sapVersion: UInt32
}

struct StoreResponse {
    var status: Int
    var headers: [String: String]
    var plist: [String: Any]
    var url: URL

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// X-Apple-AMD-Action (RP = drop routing info, SP = Store provisioning).
    var machineAction: (action: String, data: String)? {
        guard let action = header("X-Apple-AMD-Action")?.trimmingCharacters(in: .whitespaces), !action.isEmpty else { return nil }
        return (action, header("X-Apple-AMD-Data")?.trimmingCharacters(in: .whitespaces) ?? "")
    }
}

class StoreClient {
    var session: URLSession
    var appleId: String
    var password: String
    var guid: String?
    var accountName: String?
    var authHeaders: [String: String]?
    var authCookies: [HTTPCookie]?
    var pod: String?

    init(appleId: String, password: String) {
        session = URLSession(configuration: .default, delegate: NoRedirectDelegate(), delegateQueue: nil)
        self.appleId = appleId
        self.password = password
        self.guid = nil
        self.accountName = nil
        self.authHeaders = nil
        self.authCookies = nil
        self.pod = nil
    }

    func generateGuid(appleId: String) -> String {
        print("Generating GUID")
        let DEFAULT_GUID = "000C2941396B"
        let GUID_DEFAULT_PREFIX = 2
        let GUID_SEED = "CAFEBABE"
        let GUID_POS = 10

        let h = SHA1.hash((GUID_SEED + appleId + GUID_SEED).data(using: .utf8)!).hexString
        let defaultPart = DEFAULT_GUID.prefix(GUID_DEFAULT_PREFIX)
        let hashPart = h[GUID_POS..<GUID_POS + (DEFAULT_GUID.count - GUID_DEFAULT_PREFIX)]
        let guid = (defaultPart + hashPart).uppercased()

        print("Came up with GUID: \(guid)")
        return guid
    }

    func saveAuthInfo() -> Void {
        let authCookiesEnc1 = NSKeyedArchiver.archivedData(withRootObject: authCookies ?? [])
        let authCookiesEnc = authCookiesEnc1.base64EncodedString()
        let out: [String: Any] = [
            "appleId": appleId,
            "password": password,
            "guid": guid ?? NSNull(),
            "accountName": accountName ?? NSNull(),
            "authHeaders": authHeaders ?? NSNull(),
            "authCookies": authCookiesEnc,
            "pod": pod ?? NSNull()
        ]
        let data = try! JSONSerialization.data(withJSONObject: out, options: [])
        let base64 = data.base64EncodedString()
        EncryptedKeychainWrapper.saveAuthInfo(base64: base64)
    }

    func tryLoadAuthInfo() -> Bool {
        if let base64 = EncryptedKeychainWrapper.loadAuthInfo() {
            let data = Data(base64Encoded: base64)!
            let out = try! JSONSerialization.jsonObject(with: data, options: []) as! [String: Any]
            appleId = out["appleId"] as! String
            password = out["password"] as! String
            guid = out["guid"] as? String
            accountName = out["accountName"] as? String
            authHeaders = out["authHeaders"] as? [String: String]
            let authCookiesEnc = out["authCookies"] as! String
            let authCookiesEnc1 = Data(base64Encoded: authCookiesEnc)!
            authCookies = NSKeyedUnarchiver.unarchiveObject(with: authCookiesEnc1) as? [HTTPCookie]
            pod = out["pod"] as? String
            print("Loaded auth info")
            return true
        }
        print("No auth info found, need to authenticate")
        return false
    }

    // MARK: - Bag

    // The live bag selects the native endpoint and SAP setup for the same
    // Configurator identity. Never fall back to an unsigned login URL.
    func getBag() async throws -> StoreBag {
        if guid == nil { guid = generateGuid(appleId: appleId) }
        guard let guid else { throw "Store GUID is missing" }
        var request = URLRequest(url: URL(string: "https://init.itunes.apple.com/bag.xml?ix=6&guid=\(guid)")!)
        request.httpMethod = "GET"
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.setValue(StoreConstants.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let xmlString = String(data: data, encoding: .utf8),
              let plistStart = xmlString.range(of: "<plist"),
              let plistEnd = xmlString.range(of: "</plist>"),
              let cleanData = String(xmlString[plistStart.lowerBound..<plistEnd.upperBound]).data(using: .utf8),
              let plist = try PropertyListSerialization.propertyList(from: cleanData, options: [], format: nil) as? [String: Any] else {
            throw "Apple's Store bag is unavailable"
        }
        let values = plist["urlBag"] as? [String: Any] ?? plist
        guard let advertised = values["authenticateAccount"] as? String,
              let endpoint = Self.normalizeAuthEndpoint(advertised),
              let setupString = values["sign-sap-setup"] as? String,
              let certificateString = values["sign-sap-setup-cert"] as? String,
              let setup = URL(string: setupString), let certificate = URL(string: certificateString),
              let versionString = values["sign-sap-version"] as? String,
              let version = UInt32(versionString) else {
            throw "Apple's Store bag is missing a supported authentication or SAP endpoint"
        }
        print("bag auth: \(endpoint.host ?? "?")\(endpoint.path); SAP version \(version)")
        return StoreBag(endpoint: endpoint, sapSetup: setup, sapCertificate: certificate, sapVersion: version)
    }

    /// Native endpoints keep their advertised path; the legacy MZFinance
    /// endpoint needs its trailing slash ("brazil fix").
    static func normalizeAuthEndpoint(_ endpoint: String) -> URL? {
        guard var components = URLComponents(string: endpoint), components.scheme == "https",
              let host = components.host?.lowercased() else { return nil }
        if host == StoreConstants.nativeAuthHost {
            return StoreConstants.nativeAuthPaths.contains(components.path) ? components.url : nil
        }
        if host == "buy.itunes.apple.com" || host.hasSuffix("-buy.itunes.apple.com") {
            components.path = StoreConstants.legacyAuthPath + "/"
            return components.url
        }
        return nil
    }

    static func resolveRedirect(from base: URL, location: String) -> URL? {
        guard let target = URL(string: location.trimmingCharacters(in: .whitespaces), relativeTo: base)?.absoluteURL,
              let host = target.host?.lowercased(), target.scheme == "https" else { return nil }
        if host == StoreConstants.nativeAuthHost {
            return StoreConstants.nativeAuthPaths.contains(target.path) ? target : nil
        }
        if host == "buy.itunes.apple.com" || host.hasSuffix("-buy.itunes.apple.com") {
            let path = target.path
            return path == StoreConstants.legacyAuthPath || path == StoreConstants.legacyAuthPath + "/" ? target : nil
        }
        return nil
    }

    // MARK: - Login

    private func loginBody(attempt: Int) throws -> Data {
        let body: [String: Any] = [
            "appleId": appleId,
            "attempt": String(attempt),
            "guid": guid!,
            // 2FA codes are appended to the password by the caller.
            "password": password.replacingOccurrences(of: " ", with: ""),
            "rmp": "0",
            "why": "signIn"
        ]
        return try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
    }

    private func send(_ request: URLRequest, debugLabel: String? = nil) async throws -> StoreResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw "invalid response" }
        var headers = [String: String]()
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key)] = String(describing: value)
        }
        let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]) ?? [:]
        if let debugLabel {
            print("--- \(debugLabel): HTTP \(http.statusCode) from \(request.url?.host ?? "?")\(request.url?.path ?? "")")
            let interesting = headers.filter { key, _ in
                let k = key.lowercased()
                return k.hasPrefix("x-apple-") || k == "location" || k == "pod" || k == "www-authenticate" || k == "content-type" || k == "retry-after"
            }
            for (key, value) in interesting.sorted(by: { $0.key < $1.key }) {
                // Proofs, session metadata and correlation IDs must not enter the
                // copyable in-app log. Names are enough to debug a 204 response.
                let printable = ["content-type", "x-apple-amd-action", "retry-after"].contains(key.lowercased()) ? value : "<redacted>"
                print("    \(key): \(printable)")
            }
            print("    body: \(data.count) bytes")
            if !plist.isEmpty {
                print("    plist keys: \(plist.keys.sorted().joined(separator: ", "))")
                for key in ["failureType", "customerMessage", "errorMessage", "m-allowed", "dialog"] {
                    if let value = plist[key] { print("    \(key): \(value)") }
                }
            } else if !data.isEmpty, let text = String(data: data.prefix(512), encoding: .utf8) {
                print("    body preview: \(text.replacingOccurrences(of: "\n", with: " "))")
            }
            print("---")
        }
        return StoreResponse(status: http.statusCode, headers: headers, plist: plist, url: request.url!)
    }

    /// One login round: follows allowlisted redirects with the same attempt and
    /// retries once with attempt 2 on Apple's first-attempt -5000.
    private func sendLogin(endpoint: URL, headers: [String: String], signer: StoreSAPSigner) async throws -> StoreResponse {
        var url = endpoint
        var attempt = 1
        var redirects = 0
        while true {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
            request.setValue(StoreConstants.userAgent, forHTTPHeaderField: "User-Agent")
            let body = try loginBody(attempt: attempt)
            request.httpBody = body
            request.setValue(try signer.sign(body), forHTTPHeaderField: "X-Apple-ActionSignature")

            let sentProof = headers.keys.filter { $0.lowercased().hasPrefix("x-apple-") || $0.lowercased().hasPrefix("x-mme-") }.sorted()
            print("login attempt \(attempt) -> \(url.host ?? "?")\(url.path); SAP signed; proof headers: \(sentProof.joined(separator: ", "))")
            let response = try await send(request, debugLabel: "login")
            print("Status: \(response.status) (\(url.host ?? "?"))")
            if response.machineAction != nil {
                return response
            }
            if (300..<400).contains(response.status) {
                guard redirects < StoreConstants.maxRedirects,
                      let location = response.header("Location"),
                      let next = Self.resolveRedirect(from: url, location: location) else {
                    throw "unsupported authentication redirect (HTTP \(response.status))"
                }
                redirects += 1
                print("redirected to \(next.host ?? "?")")
                url = next
                continue
            }
            if attempt == 1, response.plist["failureType"] as? String == StoreConstants.invalidCredentials {
                attempt += 1
                continue
            }
            return response
        }
    }

    /// Login with Store AMD proofs (ipatool nativeLogin): first pass sends the
    /// full anisette identity; RP drops routing info and retries; SP runs Store
    /// provisioning, then retries with the fresh AMD pair only.
    private func performLogin() async throws -> StoreResponse {
        if guid == nil {
            guid = generateGuid(appleId: appleId)
        }
        let bag = try await getBag()
        let endpoint = bag.endpoint
        print("auth endpoint: \(endpoint.absoluteString)")

        let signer = try await StoreSAPSigner.create(setupURL: bag.sapSetup, certificateURL: bag.sapCertificate,
                                                      version: bag.sapVersion, guid: guid!)
        defer { signer.close() }
        let anisette = StoreAnisette.shared
        let identity = try await anisette.identityHeaders()
        print("anisette identity headers: \(identity.keys.sorted().joined(separator: ", "))")
        print("  X-Apple-I-MD present: \(identity["X-Apple-I-MD"] != nil), X-Apple-I-MD-M present: \(identity["X-Apple-I-MD-M"] != nil), RINFO: \(identity["X-Apple-I-MD-RINFO"] ?? "none")")
        let headers = try StoreAnisette.storeHeaders(from: identity, endpoint: endpoint)

        // ipatool provisions the machine anisette up front (gsa MidService) and
        // treats any authentication machine action as terminal, not a mid-login
        // RP/SP provisioning step. Return the first response; a machineAction
        // surfaces as a clean error in authenticate().
        return try await sendLogin(endpoint: endpoint, headers: headers, signer: signer)
    }

    static func directoryServicesID(from response: StoreResponse) -> String? {
        if let queue = response.plist["download-queue-info"] as? [String: Any], let dsid = queue["dsid"] {
            return "\(dsid)"
        }
        if let dsid = response.plist["dsPersonId"] as? String, !dsid.isEmpty {
            return dsid
        }
        if let dsid = response.header("X-Dsid")?.trimmingCharacters(in: .whitespaces), !dsid.isEmpty {
            return dsid
        }
        // The native endpoint may only expose the DSID in mz_at0-/mz_at_ssl- cookie names.
        if let cookies = response.header("Set-Cookie"),
           let match = cookies.range(of: #"mz_at(?:0|_ssl)-([0-9]+)="#, options: .regularExpression) {
            return cookies[match].components(separatedBy: "-").last?.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        }
        return nil
    }

    func authenticate(requestCode: Bool = false) -> Bool {
        let store = StoreData.shared

        Task {
            func fail(_ message: String) {
                print("Authentication failed: \(message)")
                DispatchQueue.main.async {
                    let format = String(localized: "alert.login.failed.message")
                    Alertinator.shared.alert(
                        title: String(localized: "alert.login.failed.title"),
                        body: String(format: format, message)
                    )
                }
            }

            let response: StoreResponse
            do {
                response = try await performLogin()
            } catch {
                fail((error as? LocalizedError)?.errorDescription ?? "\(error)")
                return
            }

            if let action = response.machineAction {
                fail("Apple requested an unsupported machine action (\(action.action))")
                return
            }

            let resp = response.plist
            let customerMessage = resp["customerMessage"] as? String ?? ""
            let failureType = resp["failureType"] as? String ?? ""
            let passwordToken = resp["passwordToken"] as? String ?? ""

            if failureType.isEmpty && customerMessage.contains("Configurator_message") {
                print("need 2fa...")
                DispatchQueue.main.async { store.sent2FA = true }
                return
            }
            if !failureType.isEmpty || response.status != 200 || passwordToken.isEmpty {
                let diagnostic: String
                if response.status == 204 && customerMessage.isEmpty {
                    diagnostic = "Apple returned HTTP 204 with no body despite a SAP-signed request. Check the Store AMD device proof and the bag's native auth path."
                } else {
                    diagnostic = customerMessage.isEmpty ? "HTTP \(response.status), failure type \(failureType.isEmpty ? "none" : failureType)" : customerMessage
                }
                fail(diagnostic)
                return
            }
            guard let dsid = Self.directoryServicesID(from: response) else {
                fail("Apple returned no directory services identifier")
                return
            }
            guard let storeFront = response.header("X-Set-Apple-Store-Front") ?? response.header("X-Apple-Request-Store-Front") else {
                fail("Apple returned no storefront")
                return
            }

            print("Authentication successful!")
            print("Store front: \(storeFront)")
            self.pod = response.header("pod")
            self.authHeaders = [
                "X-Dsid": dsid,
                "iCloud-Dsid": dsid,
                "X-Apple-Store-Front": storeFront,
                "X-Token": passwordToken
            ]
            self.authCookies = self.session.configuration.httpCookieStorage?.cookies
            if let accountInfo = resp["accountInfo"] as? [String: Any],
               let address = accountInfo["address"] as? [String: Any] {
                let first = address["firstName"] as? String ?? ""
                let last = address["lastName"] as? String ?? ""
                self.accountName = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
            }
            self.saveAuthInfo()
            DispatchQueue.main.async { store.isLoggedIn = true }
        }

        return false
    }

    // MARK: - Download

    /// Runs an async operation from the synchronous download path, blocking
    /// the caller (the work itself runs off the caller's thread).
    private func blocking<T>(_ operation: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        Task.detached {
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    func volumeStoreDownloadProduct(appId: String, appVerId: String = "") -> [String: Any] {
        guard let guid = self.guid, let authHeaders = self.authHeaders else {
            print("Not authenticated")
            return [:]
        }
        var req: [String: Any] = [
            "creditDisplay": "",
            "guid": guid,
            "salableAdamId": appId,
            "serialNumber": "0",
        ]
        if appVerId != "" {
            req["externalVersionId"] = appVerId
        }
        let podPrefix = (pod?.isEmpty == false) ? "p\(pod!)-" : ""
        let url = URL(string: "https://\(podPrefix)buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=\(guid)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try! PropertyListSerialization.data(fromPropertyList: req, format: .xml, options: 0)
        print("Setting headers")
        for (key, value) in authHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            // Attach the relabeled machine anisette (same form ipatool's login
            // sends). ipatool runs the AMSAnisette type-2 framework here; this is
            // the minimal native equivalent.
            let proof = try blocking { try await StoreAnisette.shared.storeAMDProof(for: url) }
            for (key, value) in proof {
                request.setValue(value, forHTTPHeaderField: key)
            }
        } catch {
            print("Failed to attach Store anisette: \(error)")
            return [:]
        }
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        request.setValue(StoreConstants.userAgent, forHTTPHeaderField: "User-Agent")
        if let cookies = self.authCookies {
            print("Setting cookies")
            self.session.configuration.httpCookieStorage?.setCookies(cookies, for: url, mainDocumentURL: nil)
        }

        do {
            let response = try blocking { try await self.send(request) }
            print("Got download response (HTTP \(response.status))")
            if let action = response.machineAction {
                print("Download rejected with AMD action \(action.action)")
            }
            if response.plist["cancel-purchase-batch"] != nil || response.plist["failureType"] != nil {
                print("Failed to download product: \(response.plist["customerMessage"] as? String ?? "unknown error")")
            }
            return response.plist
        } catch {
            print("error 2 \(error)")
            return [:]
        }
    }

    func download(appId: String, appVer: String = "", isRedownload: Bool = false) -> [String: Any] {
        return self.volumeStoreDownloadProduct(appId: appId, appVerId: appVer)
    }

    func downloadToPath(url: String, path: String) -> Bool {
        do {
            let (location, response) = try blocking {
                try await URLSession.shared.download(for: URLRequest(url: URL(string: url)!))
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                print("error 3 HTTP \(status)")
                return false
            }
            try? fm.removeItem(atPath: path)
            try fm.moveItem(at: location, to: URL(fileURLWithPath: path))
            print("Downloaded to \(path)")
            return true
        } catch {
            print("error 3 \(error)")
            return false
        }
    }
}

class IPATool {
    var session: URLSession
    var appleId: String
    var password: String
    var storeClient: StoreClient
    
    init(appleId: String, password: String) {
        print("init!")
        session = URLSession.shared
        self.appleId = appleId
        self.password = password
        storeClient = StoreClient(appleId: appleId, password: password)
    }
    
    func authenticate(requestCode: Bool = false) -> Bool {
        print("Authenticating to iTunes Store...")
        if !storeClient.tryLoadAuthInfo() {
            return storeClient.authenticate(requestCode: requestCode)
        } else {
            return true
        }
    }

    func getVersionIDList(appId: String) -> [String] {
        print("Retrieving download info for appId \(appId)...")
        let downResp = storeClient.download(appId: appId, isRedownload: true)
        let songList = downResp["songList"] as? [[String: Any]] ?? []
        if songList.count == 0 {
            print("Failed to get id list!")
            return []
        }
        let downInfo = songList[0]
        let metadata = downInfo["metadata"] as? [String: Any] ?? [:]
        let appVerIds = metadata["softwareVersionExternalIdentifiers"] as? [Int] ?? []
        print("Got available version ids: \(appVerIds.description)")
        return appVerIds.map { String($0) }
    }

    func downloadIPAForVersion(appId: String, appVerId: String) -> String {
        print("Downloading IPA for app \(appId) version \(appVerId)")
        let downResp = storeClient.download(appId: appId, appVer: appVerId)
        let songList = downResp["songList"] as? [[String: Any]] ?? []
        if songList.count == 0 {
            print("Failed to get app download info!")
            return ""
        }
        let downInfo = songList[0]
        let url = downInfo["URL"] as! String
        print("Got download URL: \(url)")
        let tempDir = fm.temporaryDirectory
        let path = tempDir.appendingPathComponent("app.ipa").path
        if fm.fileExists(atPath: path) {
            print("Removing existing file at \(path)")
            try! fm.removeItem(atPath: path)
        }
        if !storeClient.downloadToPath(url: url, path: path) {
            print("Failed to download IPA!")
            return ""
        }
        Zip.addCustomFileExtension("ipa")
        let path3 = URL(fileURLWithPath: path)
        let fileExtension = path3.pathExtension
        let fileName = path3.lastPathComponent
        let directoryName = fileName.replacingOccurrences(of: ".\(fileExtension)", with: "")
        let documentsUrl = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationUrl = documentsUrl.appendingPathComponent(directoryName, isDirectory: true)
        if fm.fileExists(atPath: destinationUrl.path) {
            print("Removing existing folder at \(destinationUrl.path)")
            try! fm.removeItem(at: destinationUrl)
        }
        
        let unzipDirectory = try! Zip.quickUnzipFile(path3)
        var metadata = downInfo["metadata"] as! [String: Any]
        let metadataPath = unzipDirectory.appendingPathComponent("iTunesMetadata.plist").path
        metadata["apple-id"] = appleId
        metadata["userName"] = appleId
        (metadata as NSDictionary).write(toFile: metadataPath, atomically: true)
        print("Wrote iTunesMetadata.plist")
        var appContentDir = ""
        let payloadDir = unzipDirectory.appendingPathComponent("Payload")
        for entry in try! fm.contentsOfDirectory(atPath: payloadDir.path) {
            if entry.hasSuffix(".app") {
                print("Found app content dir: \(entry)")
                appContentDir = "Payload/" + entry
                break
            }
        }
        print("Found app content dir: \(appContentDir)")
        let scManifestData = try! Data(contentsOf: unzipDirectory.appendingPathComponent(appContentDir).appendingPathComponent("SC_Info").appendingPathComponent("Manifest.plist"))
        let scManifest = try! PropertyListSerialization.propertyList(from: scManifestData, options: [], format: nil) as! [String: Any]
        let sinfsDict = downInfo["sinfs"] as! [[String: Any]]
        if let sinfPaths = scManifest["SinfPaths"] as? [String] {
            for (i, sinfPath) in sinfPaths.enumerated() {
                let sinfData = sinfsDict[i]["sinf"] as! Data
                try! sinfData.write(to: unzipDirectory.appendingPathComponent(appContentDir).appendingPathComponent(sinfPath))
                print("Wrote sinf to \(sinfPath)")
            }
        } else {
            print("Manifest.plist does not exist! Assuming it is an old app without one...")
            let infoListData = try! Data(contentsOf: unzipDirectory.appendingPathComponent(appContentDir).appendingPathComponent("Info.plist"))
            let infoList = try! PropertyListSerialization.propertyList(from: infoListData, options: [], format: nil) as! [String: Any]
            let sinfPath = appContentDir + "/SC_Info/" + (infoList["CFBundleExecutable"] as! String) + ".sinf"
            let sinfData = sinfsDict[0]["sinf"] as! Data
            try! sinfData.write(to: unzipDirectory.appendingPathComponent(sinfPath))
            print("Wrote sinf to \(sinfPath)")
        }
        print("Downloaded IPA to \(unzipDirectory.path)")
        return unzipDirectory.path
    }
}

class EncryptedKeychainWrapper {
    static func generateAndStoreKey() -> Void {
        self.deleteKey()
        print("Generating key")
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: "com.jbdotparty.PancakeStore.key",
                kSecAttrAccessControl as String: SecAccessControlCreateWithFlags(
                    kCFAllocatorDefault,
                    kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                    [.privateKeyUsage],
                    nil
                )!
            ]
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(query as CFDictionary, &error) else {
            print("Failed to generate key!")
            return
        }
        print("Generated key!")
        print("Getting public key")
        let pubKey = SecKeyCopyPublicKey(privateKey)!
        print("Got public key")
        let pubKeyData = SecKeyCopyExternalRepresentation(pubKey, &error)! as Data
        let pubKeyBase64 = pubKeyData.base64EncodedString()
        print("Public key: \(pubKeyBase64)")
    }

    static func deleteKey() -> Void {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: "com.jbdotparty.PancakeStore.key"
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func saveAuthInfo(base64: String) -> Void {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: "com.jbdotparty.PancakeStore.key",
            kSecReturnRef as String: true
        ]
        var keyRef: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &keyRef)
        if status != errSecSuccess {
            print("Failed to get key!")
            return
        }
        print("Got key!")
        let key = keyRef as! SecKey
        print("Getting public key")
        let pubKey = SecKeyCopyPublicKey(key)!
        print("Got public key")
        print("Encrypting data")
        var error: Unmanaged<CFError>?
        guard let encryptedData = SecKeyCreateEncryptedData(pubKey, .eciesEncryptionCofactorVariableIVX963SHA256AESGCM, base64.data(using: .utf8)! as CFData, &error) else {
            print("Failed to encrypt data!")
            return
        }
        print("Encrypted data")
        let path = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("authinfo").path
        fm.createFile(atPath: path, contents: encryptedData as Data, attributes: nil)
        print("Saved encrypted auth info")
    }

    static func loadAuthInfo() -> String? {
        //@ObservedObject var store = StoreData.shared
        
        let path = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("authinfo").path
        if !fm.fileExists(atPath: path) {
            return nil
        }
        let data = fm.contents(atPath: path)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: "com.jbdotparty.PancakeStore.key",
            kSecReturnRef as String: true
        ]
        var keyRef: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &keyRef)
        if status != errSecSuccess {
            print("Failed to get key! Aborting login...")
            //store.sent2FA = false
            // this is where login can abort
            return nil
        }
        print("Got key!")
        let key = keyRef as! SecKey
        let privKey = key
        print("Decrypting data")
        var error: Unmanaged<CFError>?
        guard let decryptedData = SecKeyCreateDecryptedData(privKey, .eciesEncryptionCofactorVariableIVX963SHA256AESGCM, data as CFData, &error) else {
            print("Failed to decrypt data!")
            return nil
        }
        print("Decrypted data")
        return String(data: decryptedData as Data, encoding: .utf8)
    }

    static func deleteAuthInfo() -> Void {
        let path = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("authinfo").path
        try! fm.removeItem(atPath: path)
    }

    static func hasAuthInfo() -> Bool {
        return loadAuthInfo() != nil
    }

    static func getAuthInfo() -> [String: Any]? {
        if let base64 = loadAuthInfo() {
            let data = Data(base64Encoded: base64)!
            let out = try! JSONSerialization.jsonObject(with: data, options: []) as! [String: Any]
            return out
        }
        return nil
    }

    static func nuke() -> Void {
        deleteAuthInfo()
        deleteKey()
    }
}
