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
import SwiftUI
import PartyUI
import UIKit

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
        session = URLSession.shared
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
        let authCookiesEnc1 = NSKeyedArchiver.archivedData(withRootObject: authCookies!)
        let authCookiesEnc = authCookiesEnc1.base64EncodedString()
        let out: [String: Any] = [
            "appleId": appleId,
            "password": password,
            "guid": guid,
            "accountName": accountName,
            "authHeaders": authHeaders,
            "authCookies": authCookiesEnc,
            "pod": pod
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
    
    // pancakestore is saved! thanks ipatool!
    // admittedly i kinda owe this hoorah to that vibecoded ass pull-request, i had to stoop to its level too :(
    // oh well. - skadz, 2.24.26
    
    // if i had a nickel for every time this app has been broken by random apple backend changes
    // and i've had to copy some AI-slopped pull request fix from ipatool to fix it
    // i'd have two nickels.
    // see you all on round three. - Skadz, 6.11.26
    func getBagEndpoint() async -> String {
        let fallback = "https://auth.itunes.apple.com/auth/v1/native/"
        
        if guid == nil {
            guid = generateGuid(appleId: appleId)
        }
        guard let guid = guid else { return fallback }

        var request = URLRequest(url: URL(string: "https://init.itunes.apple.com/bag.xml?guid=\(guid)")!)
        request.httpMethod = "GET"
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.setValue("Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6", forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard !data.isEmpty else { print("no data for bag.xml, returning fallback value..."); return fallback }

            // i'm sorry i'm sorry please don't hit me i know i know
            if let xmlString = String(data: data, encoding: .utf8),
               let plistStart = xmlString.range(of: "<plist"),
               let plistEnd = xmlString.range(of: "</plist>") {
                let plistSection = String(xmlString[plistStart.lowerBound..<plistEnd.upperBound])
                if let cleanData = plistSection.data(using: .utf8),
                   let plist = try PropertyListSerialization.propertyList(from: cleanData, options: [], format: nil) as? [String: Any],
                   let urlBag = plist["urlBag"] as? [String: Any],
                   let endpoint = urlBag["authenticateAccount"] as? String {
                    print("bag: \(endpoint)")
                    return endpoint
                }
            }
        } catch {
            print("failed to get bag endpoint!! \(error)")
        }

        print("failed to get bag, returning fallback value...")
        return fallback
    }

    func legacyAuthenticate(requestCode: Bool = false) -> Bool {
        @ObservedObject var store = StoreData.shared
        
        if self.guid == nil {
            self.guid = generateGuid(appleId: appleId)
        }

        var req = [
            "appleId": appleId,
            "password": password,
            "guid": guid!,
            "rmp": "0",
            "why": "signIn"
        ]
        
        // bunch of clauded bullshit, idea skidded from ipatool issue #513
        // since this is the same time we're adding the russian localization, and we already have the "brazil fix":
        // i title this one, "russia fix"
        // Skadz 7.25.26
        func attemptGetPod(url: URL, completion: @escaping (Bool, Data?, HTTPURLResponse?) -> Void) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.allHTTPHeaderFields = [
                "Accept": "*/*",
                "Content-Type": "application/x-www-form-urlencoded",
                "User-Agent": "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"
            ]
            request.httpBody = try! JSONSerialization.data(withJSONObject: req, options: [])

            let dataTask = session.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self else { return }

                if let error = error {
                    print("error \(error.localizedDescription)")
                    completion(false, nil, nil)
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(false, nil, nil)
                    return
                }

//                print("requested from \(url.absoluteString)")
                print("Status: \(httpResponse.statusCode)")
                let newURL = httpResponse.url ?? url
                print("New URL: \(newURL)")

                if let pod = httpResponse.value(forHTTPHeaderField: "pod") {
                    print("pod gotten: \(pod)")
                    self.pod = pod
                    completion(true, data, httpResponse)
                } else {
                    if newURL == url {
                        print("sent to iTunes purgatory :(")
                        completion(false, data, httpResponse)
                        return
                    }
                    print("russia fix")
                    attemptGetPod(url: newURL, completion: completion)
                }
            }
            dataTask.resume()
        }
        
        Task {
            let authURL = await getBagEndpoint()
            
            var url = URL(string: authURL)!
            let urlString = url.absoluteString
            if !urlString.hasSuffix("/") {
                print("brazil fix")
                url = URL(string: urlString.appending("/"))!
            }
            
            var ret = false
            
            attemptGetPod(url: url) { success, data, response in
                if !success {
                    print("failed to get pod!! this either means that you need to get a 2fa code or that you can't log in with this apple id.")
                    ret = false
                }

                if let data = data {
                    do {
                        let resp = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: Any]
                        if let dsPersonId = resp["dsPersonId"] as? String, let passwordToken = resp["passwordToken"] as? String, !dsPersonId.isEmpty, !passwordToken.isEmpty {
                            print("Authentication successful!")
                            let download_queue_info = resp["download-queue-info"] as! [String: Any]
                            let dsid = download_queue_info["dsid"] as! Int
                            let storeFront = response?.value(forHTTPHeaderField: "x-set-apple-store-front")
                            print("Store front: \(storeFront!)")
                            self.authHeaders = [
                                "X-Dsid": String(dsid),
                                "iCloud-Dsid": String(dsid),
                                "X-Apple-Store-Front": storeFront!,
                                "X-Token": resp["passwordToken"] as! String
                            ]
                            self.authCookies = self.session.configuration.httpCookieStorage?.cookies
                            let accountInfo = resp["accountInfo"] as! [String: Any]
                            let address = accountInfo["address"] as! [String: String]
                            self.accountName = address["firstName"]! + " " + address["lastName"]!
                            self.saveAuthInfo()
                            ret = true
                            store.isLoggedIn = true
                        } else if (resp["customerMessage"] as! String).contains("Configurator_message") {
                            store.sent2FA = true
                            print("need 2fa...")
                            ret = false
                        } else {
                            let errorMessage = resp["customerMessage"] as! String
                            print("Authentication failed: \(errorMessage)")
                            DispatchQueue.main.async {
                                let format = String(localized: "alert.login.failed.message")
                                let message = String(format: format, errorMessage)
                                
                                Alertinator.shared.alert(
                                    title: String(localized: "alert.login.failed.title"),
                                    body: message
                                )
                            }
                        }
                    } catch {
                        print("Error: \(error)")
                    }
                }
            }
            return ret
        }
        
        return false
    }

    func volumeStoreDownloadProduct(appId: String, appVerId: String = "") -> [String: Any] {
        var req = [
            "creditDisplay": "",
            "guid": self.guid!,
            "salableAdamId": appId,
        ]
        if appVerId != "" {
            req["externalVersionId"] = appVerId
        }
        let url = URL(string: "https://p\(pod!)-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=\(self.guid!)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = [
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"
        ]
        request.httpBody = try! JSONSerialization.data(withJSONObject: req, options: [])
        print("Setting headers")
        for (key, value) in self.authHeaders! {
            let normalizedKey = key.lowercased()
            let isSensitive = ["x-token", "x-dsid", "icloud-dsid", "cookie", "authorization"].contains(normalizedKey)
            print("Setting header \(key): \(isSensitive ? "<redacted>" : value)")
            request.addValue(value, forHTTPHeaderField: key)
        }
        print("Setting cookies")
        self.session.configuration.httpCookieStorage?.setCookies(self.authCookies!, for: url, mainDocumentURL: nil)

        var resp = [String: Any]()
        let datatask = session.dataTask(with: request) { (data, response, error) in
            if let error = error {
                print("error 2 \(error.localizedDescription)")
                return
            }
            if let data = data {
                do {
                    print("Got response")
                    let resp1 = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: Any]
                    if resp1["cancel-purchase-batch"] != nil {
                        print("Failed to download product: \(resp1["customerMessage"] as! String)")
                    }
                    resp = resp1
                } catch {
                    print("Error: \(error)")
                }
            }
        }
        datatask.resume()
        while datatask.state != .completed {
            sleep(1)
        }
        print("Got download response")
        return resp
    }

    func download(appId: String, appVer: String = "", isRedownload: Bool = false) -> [String: Any] {
        return self.volumeStoreDownloadProduct(appId: appId, appVerId: appVer)
    }

    func downloadToPath(url: String, path: String) -> Void {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "GET"
        let datatask = session.dataTask(with: req) { (data, response, error) in
            if let error = error {
                print("error 3 \(error.localizedDescription)")
                return
            }
            if let data = data {
                do {
                    try data.write(to: URL(fileURLWithPath: path))
                } catch {
                    print("Error: \(error)")
                }
            }
        }
        datatask.resume()
        while datatask.state != .completed {
            sleep(1)
        }
        print("Downloaded to \(path)")
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
    
    @MainActor
    func authenticate(authCode: String = "") async -> Bool {
        let store = StoreData.shared
        print("Authenticating to iTunes Store using embedded ipatool native Store flow...")

        // A previously completed native login is already stored inside the
        // existing SEP-encrypted authinfo container. Restore the legacy fields
        // used by the current download UI without re-submitting credentials.
        if authCode.isEmpty,
           let saved = EncryptedKeychainWrapper.getAuthInfo(),
           (saved["nativeAuthVersion"] as? Int) == 1,
           saved["nativeAccount"] != nil,
           storeClient.tryLoadAuthInfo() {
            store.isLoggedIn = true
            store.sent2FA = false
            return true
        }

        let saved = EncryptedKeychainWrapper.getAuthInfo() ?? [:]
        let keychainState = saved["nativeKeychain"] as? [String: String] ?? [:]
        var cookieState = [NativeIPAToolCookieRecord]()
        if let encodedCookies = saved["nativeCookies"] as? String,
           let data = Data(base64Encoded: encodedCookies),
           let decoded = try? JSONDecoder().decode([NativeIPAToolCookieRecord].self, from: data) {
            cookieState = decoded
        }

        let request = NativeIPAToolRequest(
            email: appleId,
            password: password,
            authCode: authCode,
            deviceIdentifier: NativeIPAToolBridge.deviceIdentifier(),
            hardwareID: saved["nativeHardwareAddress"] as? String ?? "",
            homeDirectory: NSHomeDirectory(),
            keychain: keychainState,
            cookies: cookieState
        )

        // The Go Store authentication flow performs multiple network and
        // emulation steps. Run it away from the SwiftUI main thread.
        let response = await Task.detached(priority: .userInitiated) {
            NativeIPAToolBridge.login(request)
        }.value

        let receivedCookies = NativeIPAToolBridge.cookies(from: response.cookies)
        let archivedCookies = NSKeyedArchiver.archivedData(withRootObject: receivedCookies)
        var authHeaders = [String: String]()
        if let account = response.account {
            if let dsid = account.directoryServicesIdentifier, !dsid.isEmpty {
                authHeaders["X-Dsid"] = dsid
                authHeaders["iCloud-Dsid"] = dsid
            }
            if let storefront = account.storeFront, !storefront.isEmpty {
                authHeaders["X-Apple-Store-Front"] = storefront
            }
            if let token = account.passwordToken, !token.isEmpty {
                authHeaders["X-Token"] = token
            }
        }

        var stored: [String: Any] = [
            "nativeAuthVersion": 1,
            "nativeAuthPending2FA": response.authCodeRequired || (!authCode.isEmpty && !response.success),
            "appleId": appleId,
            "password": password,
            "guid": response.hardwareID?.replacingOccurrences(of: ":", with: "") ?? (saved["guid"] as? String ?? ""),
            "nativeHardwareAddress": response.hardwareID ?? (saved["nativeHardwareAddress"] as? String ?? ""),
            "accountName": response.account?.name ?? (saved["accountName"] as? String ?? ""),
            "authHeaders": authHeaders,
            "authCookies": archivedCookies.base64EncodedString(),
            "pod": response.account?.pod ?? (saved["pod"] as? String ?? ""),
            "nativeKeychain": response.keychain,
            "nativeCookies": (try? JSONEncoder().encode(response.cookies).base64EncodedString()) ?? ""
        ]
        if let account = response.account,
           let accountData = try? JSONEncoder().encode(account),
           let accountObject = try? JSONSerialization.jsonObject(with: accountData) {
            stored["nativeAccount"] = accountObject
        }
        if let encoded = try? JSONSerialization.data(withJSONObject: stored, options: []) {
            EncryptedKeychainWrapper.saveAuthInfo(base64: encoded.base64EncodedString())
        }

        storeClient.guid = response.hardwareID?.replacingOccurrences(of: ":", with: "") ?? storeClient.guid
        storeClient.authHeaders = authHeaders
        storeClient.authCookies = receivedCookies
        storeClient.pod = response.account?.pod
        storeClient.accountName = response.account?.name

        if response.success, response.account != nil {
            print("Native Store authentication successful")
            store.isLoggedIn = true
            store.sent2FA = false
            return true
        }

        if response.authCodeRequired {
            print("Apple requires a 2FA verification code")
            store.isLoggedIn = false
            store.sent2FA = true
            return false
        }

        print("Native Store authentication failed: \(response.error ?? "unknown error")")
        store.isLoggedIn = false
        if !authCode.isEmpty { store.sent2FA = true }
        return false
    }

    func getVersionIDList(appId: String) -> [String] {
        print("Retrieving download info for appId \(appId)...")

        guard let saved = EncryptedKeychainWrapper.getAuthInfo(),
              (saved["nativeAuthVersion"] as? Int) == 1,
              let keychain = saved["nativeKeychain"] as? [String: String],
              let encodedCookies = saved["nativeCookies"] as? String,
              let cookieData = Data(base64Encoded: encodedCookies),
              let cookies = try? JSONDecoder().decode([NativeIPAToolCookieRecord].self, from: cookieData) else {
            print("Failed to restore native Store state for version lookup; sign in again")
            return []
        }

        let hardwareID = saved["nativeHardwareAddress"] as? String ?? ""
        let request = NativeIPAToolVersionsRequest(
            appId: appId,
            deviceIdentifier: NativeIPAToolBridge.deviceIdentifier(),
            hardwareID: hardwareID,
            homeDirectory: NSHomeDirectory(),
            keychain: keychain,
            cookies: cookies
        )
        let response = NativeIPAToolBridge.listVersions(request)

        // Store AMD proof generation rotates the saved Anisette state. Persist
        // the updated native state returned by ipatool before the next request.
        if !response.keychain.isEmpty {
            var updated = saved
            updated["nativeKeychain"] = response.keychain
            if let data = try? JSONEncoder().encode(response.cookies) {
                updated["nativeCookies"] = data.base64EncodedString()
                let archivedCookies = NativeIPAToolBridge.cookies(from: response.cookies)
                updated["authCookies"] = NSKeyedArchiver.archivedData(withRootObject: archivedCookies).base64EncodedString()
                storeClient.authCookies = archivedCookies
            }
            if let data = try? JSONSerialization.data(withJSONObject: updated, options: []) {
                // JSONSerialization already returned the UTF-8 JSON bytes.
                // Base64-encode the Data directly rather than converting it to
                // String and calling a Data-only API on that String.
                EncryptedKeychainWrapper.saveAuthInfo(base64: data.base64EncodedString())
            }
        }

        guard response.success else {
            print("Failed to get version IDs: \(response.error ?? "unknown App Store error")")
            return []
        }

        let versionIDs = response.externalVersionIdentifiers
        print("Got available version ids: \(versionIDs)")
        return versionIDs
    }

    func downloadIPAForVersion(appId: String, appVerId: String) async throws -> NativeIPAToolDownloadResponse {
        print("Downloading App Store IPA for app \(appId), version \(appVerId) through embedded ipatool")

        guard let saved = EncryptedKeychainWrapper.getAuthInfo(),
              (saved["nativeAuthVersion"] as? Int) == 1,
              let keychain = saved["nativeKeychain"] as? [String: String],
              let encodedCookies = saved["nativeCookies"] as? String,
              let cookieData = Data(base64Encoded: encodedCookies),
              let cookies = try? JSONDecoder().decode([NativeIPAToolCookieRecord].self, from: cookieData) else {
            throw NSError(
                domain: "PancakeStoreDownload",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Native App Store session is missing. Sign in again before downloading."]
            )
        }

        let hardwareID = saved["nativeHardwareAddress"] as? String ?? ""
        let outputURL = fm.temporaryDirectory.appendingPathComponent("app.ipa", isDirectory: false)
        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }

        let request = NativeIPAToolDownloadRequest(
            appId: appId,
            externalVersionID: appVerId,
            outputPath: outputURL.path,
            deviceIdentifier: NativeIPAToolBridge.deviceIdentifier(),
            hardwareID: hardwareID,
            homeDirectory: NSHomeDirectory(),
            keychain: keychain,
            cookies: cookies
        )

        // The Go bridge performs the full Store download and FairPlay patching.
        // Keep the potentially long network operation off the main thread.
        let response = await Task.detached(priority: .userInitiated) {
            NativeIPAToolBridge.download(request)
        }.value

        // AMD/Anisette state may rotate during Store requests. Save it even
        // when the download failed so a retry can continue with fresh state.
        if !response.keychain.isEmpty {
            var updated = saved
            updated["nativeKeychain"] = response.keychain
            if let data = try? JSONEncoder().encode(response.cookies) {
                updated["nativeCookies"] = data.base64EncodedString()
                let archivedCookies = NativeIPAToolBridge.cookies(from: response.cookies)
                updated["authCookies"] = NSKeyedArchiver.archivedData(withRootObject: archivedCookies).base64EncodedString()
                storeClient.authCookies = archivedCookies
            }
            if let data = try? JSONSerialization.data(withJSONObject: updated, options: []) {
                EncryptedKeychainWrapper.saveAuthInfo(base64: data.base64EncodedString())
            }
        }

        guard response.success else {
            throw NSError(
                domain: "PancakeStoreDownload",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: response.error ?? "The App Store download failed without an error message."]
            )
        }

        guard let destinationPath = response.destinationPath,
              fm.fileExists(atPath: destinationPath) else {
            throw NSError(
                domain: "PancakeStoreDownload",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "ipatool reported success, but the downloaded IPA file is missing."]
            )
        }

        print("App Store IPA downloaded: \(destinationPath)")
        print("IPA metadata: bundle=\(response.bundleIdentifier ?? "unknown"), version=\(response.shortVersion ?? response.bundleVersion ?? "unknown")")
        return response
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
