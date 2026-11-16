import Foundation
import CryptoKit
import Compression
import MacADICore

public enum MacAnisetteFailure: LocalizedError {
    case invalidInstaller, badResponse(String), core(String)
    public var errorDescription: String? {
        switch self {
        case .invalidInstaller: "Apple's iTunes installer did not match the pinned CoreADI build"
        case .badResponse(let message): "Mac anisette provisioning: \(message)"
        case .core(let message): "Mac CoreADI: \(message)"
        }
    }
}

/// Jimpactor's Mac CoreADI machine implementation, vendored in MacADI/src.
/// The guest is x86_64 macOS; the host is arm64 iOS with interpreter-only Unicorn.
public actor ModernAnisetteClient {
    public static let clientInfo = "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
    public static let userAgent = "akd/1.0 CFNetwork/1404.0.5 Darwin/22.3.0"
    private static let installerURL = URL(string: "https://secure-appldnld.apple.com/itunes12/041-56365-20210413-79A5AC6D-6B0A-46EC-B399-5A381183E3BE/iTunes12.8.3.dmg")!
    private static let installerOffset = 184_678_769
    private static let installerLength = 3_471_595
    private static let payloadHash = "8a6c068c95036326eb2d2885fa60912ed0f7229d0939ae92934a70a3bb6cf025"
    private static let coreHash = "2eafc3c79c7f41a8afbfbeaaf23ee5dab5ad5bda55ec8e54dbc0ddf1d20ce630"
    private static let frameworkPath = "System/Library/PrivateFrameworks/CoreADI.framework/Versions/A/CoreADI"
    private static let dsid: Int64 = -2

    private struct Identity: Codable {
        var hostUUID: [UInt8]
        var deviceID: String
        var localUserID: String
        var serial: String

        static func create() -> Self {
            func hex(_ count: Int) -> String { (0..<count).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined() }
            let alphabet = Array("0123456789ABCDEFGHJKLMNPQRSTUVWXYZ")
            return Identity(hostUUID: (0..<16).map { _ in UInt8.random(in: 0...255) },
                            deviceID: "00006000-" + hex(8), localUserID: hex(16),
                            serial: "C02" + String((0..<9).map { _ in alphabet.randomElement()! }))
        }
    }

    private let root: URL
    private var handle: OpaquePointer?
    private var identity: Identity?

    public init(root: URL) { self.root = root }

    private func check(_ code: Int32) throws {
        guard code == 0 else {
            var buffer = [CChar](repeating: 0, count: 512)
            _ = adi_last_error(&buffer, buffer.count)
            throw MacAnisetteFailure.core("\(String(cString: buffer)) (\(code))")
        }
    }

    private func loadIdentity() throws -> Identity {
        if let identity { return identity }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("identity.json")
        if let data = try? Data(contentsOf: file), let loaded = try? JSONDecoder().decode(Identity.self, from: data), loaded.hostUUID.count == 16 {
            identity = loaded
            return loaded
        }
        let created = Identity.create()
        try JSONEncoder().encode(created).write(to: file, options: .atomic)
        identity = created
        print("[MacADI] New Mac identity: \(created.deviceID), serial \(created.serial)")
        return created
    }

    private static func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    /// Read only the 3.47 MB installer range containing Mac CoreADI; validate
    /// both the compressed payload and extracted binary against Jimpactor's pins.
    private func coreImage() async throws -> Data {
        let file = root.appendingPathComponent("CoreADI")
        if let saved = try? Data(contentsOf: file), Self.sha(saved) == Self.coreHash { return saved }
        print("[MacADI] Fetching x86_64 CoreADI from Apple's iTunes installer...")
        var request = URLRequest(url: Self.installerURL)
        request.setValue("bytes=\(Self.installerOffset)-\(Self.installerOffset + Self.installerLength - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.timeoutInterval = 60
        let (payload, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              payload.count == Self.installerLength, Self.sha(payload) == Self.payloadHash else {
            throw MacAnisetteFailure.invalidInstaller
        }
        let archive = try Self.inflateGzip(payload)
        let fat = try Self.cpioFile(archive, wanted: Self.frameworkPath)
        let image = try Self.x86Slice(fat)
        guard Self.sha(image) == Self.coreHash else { throw MacAnisetteFailure.invalidInstaller }
        try image.write(to: file, options: .atomic)
        print("[MacADI] Verified CoreADI (\(image.count) bytes)")
        return image
    }

    private static func inflateGzip(_ input: Data) throws -> Data {
        guard input.count > 18, input[0] == 0x1f, input[1] == 0x8b, input[2] == 8,
              input[3] == 0 else { throw MacAnisetteFailure.invalidInstaller }
        let size = Int(input[input.count-4]) | Int(input[input.count-3]) << 8 |
                   Int(input[input.count-2]) << 16 | Int(input[input.count-1]) << 24
        guard size > 0 && size <= 64 * 1024 * 1024 else { throw MacAnisetteFailure.invalidInstaller }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                    src.bindMemory(to: UInt8.self).baseAddress!.advanced(by: 10), input.count - 18,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw MacAnisetteFailure.invalidInstaller }
        return output
    }

    private static func cpioFile(_ bytes: Data, wanted: String) throws -> Data {
        var offset = 0
        while offset + 76 <= bytes.count {
            guard String(data: bytes.subdata(in: offset..<(offset + 6)), encoding: .ascii) == "070707",
                  let nameLength = Int(String(decoding: bytes[(offset+59)..<(offset+65)], as: UTF8.self), radix: 8),
                  let size = Int(String(decoding: bytes[(offset+65)..<(offset+76)], as: UTF8.self), radix: 8),
                  nameLength > 0, nameLength < 4096, size >= 0,
                  offset + 76 + nameLength + size <= bytes.count else { throw MacAnisetteFailure.invalidInstaller }
            let nameStart = offset + 76
            let nameBytes = bytes[nameStart..<(nameStart + nameLength - 1)]
            let name = String(decoding: nameBytes, as: UTF8.self)
            let start = nameStart + nameLength
            if name == wanted || name == "./" + wanted { return bytes.subdata(in: start..<(start+size)) }
            if name == "TRAILER!!!" { break }
            offset = start + size
        }
        throw MacAnisetteFailure.invalidInstaller
    }

    private static func x86Slice(_ fat: Data) throws -> Data {
        func word(_ n: Int) -> Int? {
            guard n + 4 <= fat.count else { return nil }
            return Int(fat[n]) << 24 | Int(fat[n+1]) << 16 | Int(fat[n+2]) << 8 | Int(fat[n+3])
        }
        guard word(0) == 0xcafebabe, let count = word(4), count <= (fat.count - 8) / 20 else { throw MacAnisetteFailure.invalidInstaller }
        for i in 0..<count {
            let entry = 8 + i * 20
            if word(entry) == 0x01000007, let start = word(entry+8), let size = word(entry+12),
               start <= fat.count, size <= fat.count - start {
                return fat.subdata(in: start..<(start+size))
            }
        }
        throw MacAnisetteFailure.invalidInstaller
    }

    private func open() async throws -> OpaquePointer {
        if let handle { return handle }
        let identity = try loadIdentity()
        let image = try await coreImage()
        var newHandle: OpaquePointer?
        try image.withUnsafeBytes { raw in
            try check(adi_open(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &newHandle))
        }
        guard let newHandle else { throw MacAnisetteFailure.core("null CoreADI handle") }
        do {
            try identity.hostUUID.withUnsafeBytes { raw in
                try check(adi_set_host_uuid(newHandle, raw.bindMemory(to: UInt8.self).baseAddress))
            }
            let storeURL = root.appendingPathComponent("store.bin")
            if let store = try? Data(contentsOf: storeURL) {
                try store.withUnsafeBytes { raw in
                    try check(adi_store_import(newHandle, raw.bindMemory(to: UInt8.self).baseAddress, raw.count))
                }
            }
        } catch { adi_close(newHandle); throw error }
        handle = newHandle
        return newHandle
    }

    private func saveStore(_ h: OpaquePointer) throws {
        var blob = AdiBuf(ptr: nil, len: 0)
        try check(adi_store_export(h, &blob))
        defer { adi_buf_free(blob) }
        let data = Data(bytes: blob.ptr!, count: blob.len)
        try data.write(to: root.appendingPathComponent("store.bin"), options: .atomic)
    }

    private static func data(_ buffer: AdiBuf) -> Data { Data(bytes: buffer.ptr!, count: buffer.len) }

    private func request(_ url: URL, method: String, identity: Identity, body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(Self.clientInfo, forHTTPHeaderField: "X-Mme-Client-Info")
        req.setValue(identity.deviceID, forHTTPHeaderField: "X-Mme-Device-Id")
        req.setValue(Data(identity.localUserID.utf8).base64EncodedString(), forHTTPHeaderField: "X-Apple-I-MD-LU")
        req.setValue(identity.serial, forHTTPHeaderField: "X-Apple-I-SRL-NO")
        req.setValue("UTC", forHTTPHeaderField: "X-Apple-I-TimeZone")
        req.setValue("en_US", forHTTPHeaderField: "X-Apple-Locale")
        req.setValue(ISO8601DateFormatter().string(from: Date()), forHTTPHeaderField: "X-Apple-I-Client-Time")
        if body != nil { req.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type") }
        return req
    }

    private func provisioningResponse(_ data: Data) throws -> [String: Any] {
        guard let outer = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let response = outer["Response"] as? [String: Any],
              let status = response["Status"] as? [String: Any],
              (status["ec"] as? NSNumber)?.intValue == 0 else {
            throw MacAnisetteFailure.badResponse("Apple refused provisioning or returned an invalid plist")
        }
        return response
    }

    private func field(_ response: [String: Any], _ key: String) throws -> Data {
        if let data = response[key] as? Data { return data }
        if let text = response[key] as? String, let data = Data(base64Encoded: text) { return data }
        throw MacAnisetteFailure.badResponse("missing \(key)")
    }

    private func provision(_ h: OpaquePointer, identity: Identity) async throws {
        print("[MacADI] Provisioning Mac identity with Apple...")
        let lookup = URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!
        let (lookupData, _) = try await URLSession.shared.data(for: request(lookup, method: "GET", identity: identity))
        guard let plist = try PropertyListSerialization.propertyList(from: lookupData, format: nil) as? [String: Any],
              let urls = plist["urls"] as? [String: String],
              let start = urls["midStartProvisioning"].flatMap(URL.init(string:)),
              let finish = urls["midFinishProvisioning"].flatMap(URL.init(string:)) else {
            throw MacAnisetteFailure.badResponse("lookup missing provisioning URLs")
        }
        let empty: [String: Any] = ["Header": [:] as [String: String], "Request": [:] as [String: String]]
        let startBody = try PropertyListSerialization.data(fromPropertyList: empty, format: .xml, options: 0)
        let (spimData, _) = try await URLSession.shared.data(for: request(start, method: "POST", identity: identity, body: startBody))
        let spim = try field(provisioningResponse(spimData), "spim")
        var cpim = AdiBuf(ptr: nil, len: 0)
        var session: UInt32 = 0
        try spim.withUnsafeBytes { raw in
            try check(adi_provisioning_begin(h, Self.dsid, raw.bindMemory(to: UInt8.self).baseAddress,
                  raw.count, &cpim, &session))
        }
        defer { adi_buf_free(cpim) }
        let finishBody: [String: Any] = ["Header": [:] as [String: String], "Request": ["cpim": Self.data(cpim).base64EncodedString()]]
        let encoded = try PropertyListSerialization.data(fromPropertyList: finishBody, format: .xml, options: 0)
        let (finishData, _) = try await URLSession.shared.data(for: request(finish, method: "POST", identity: identity, body: encoded))
        let answer = try provisioningResponse(finishData)
        let ptm = try field(answer, "ptm")
        let tk = try field(answer, "tk")
        let routing: UInt64?
        if let number = answer["X-Apple-I-MD-RINFO"] as? NSNumber { routing = number.uint64Value }
        else if let text = answer["X-Apple-I-MD-RINFO"] as? String { routing = UInt64(text) }
        else { routing = nil }
        guard let routing, routing != 0 else { throw MacAnisetteFailure.badResponse("missing routing info") }
        try ptm.withUnsafeBytes { p in try tk.withUnsafeBytes { t in
            try check(adi_provisioning_finish(h, Self.dsid, session,
                p.bindMemory(to: UInt8.self).baseAddress, p.count,
                t.bindMemory(to: UInt8.self).baseAddress, t.count, routing))
        } }
        try saveStore(h)
        print("[MacADI] Provisioned Mac CoreADI; routing \(routing)")
    }

    /// Fresh Mac machine proof, persisted after each use. `getHeaders` is actor
    /// isolated: the non-Send emulator is always accessed serially.
    public func getHeaders() async throws -> [String: String] {
        let identity = try loadIdentity()
        let h = try await open()
        var mid = AdiBuf(ptr: nil, len: 0), otp = AdiBuf(ptr: nil, len: 0), routing: UInt64 = 0
        var rc = adi_headers(h, Self.dsid, &mid, &otp, &routing)
        if rc == -2 { // ADI_ERR_NOT_PROVISIONED
            try await provision(h, identity: identity)
            rc = adi_headers(h, Self.dsid, &mid, &otp, &routing)
        }
        try check(rc)
        defer { adi_buf_free(mid); adi_buf_free(otp) }
        guard mid.len > 0, otp.len > 0 else { throw MacAnisetteFailure.core("empty MID or OTP") }
        try saveStore(h)
        return [
            "X-Mme-Device-Id": identity.deviceID,
            "X-Apple-I-MD-LU": Data(identity.localUserID.utf8).base64EncodedString(),
            "X-Apple-I-SRL-NO": identity.serial,
            "X-Mme-Client-Info": Self.clientInfo,
            "X-Apple-I-Client-Time": ISO8601DateFormatter().string(from: Date()),
            "X-Apple-I-TimeZone": "UTC", "X-Apple-Locale": "en_US",
            "X-Apple-I-MD-M": Self.data(mid).base64EncodedString(),
            "X-Apple-I-MD": Self.data(otp).base64EncodedString(),
            "X-Apple-I-MD-RINFO": String(routing),
        ]
    }

    /// Drop the machine identity and CoreADI store. Once an identity has
    /// completed a Store (SP) login, Apple answers its later machine-anisette
    /// logins with HTTP 500, and the Store DSID -1 state cannot be persisted;
    /// so every full login starts from a fresh identity.
    public func resetIdentity() {
        if let handle { adi_close(handle) }
        handle = nil
        identity = nil
        for name in ["identity.json", "store.bin"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
        print("[MacADI] Starting a fresh Mac identity for this login")
    }

    /// Store anisette lives under DSID -1 (ipatool storeAnisetteDSID = ^uint64(0)).
    private static let storeDSID: Int64 = -1

    /// Store AMD pair (X-Apple-AMD / X-Apple-AMD-M) from the Store DSID, or nil
    /// until Apple's SP action has been answered with `provisionStore`.
    public func storeProof() async throws -> [String: String]? {
        let h = try await open()
        var mid = AdiBuf(ptr: nil, len: 0), otp = AdiBuf(ptr: nil, len: 0), routing: UInt64 = 0
        let rc = adi_headers(h, Self.storeDSID, &mid, &otp, &routing)
        if rc == -2 { return nil } // ADI_ERR_NOT_PROVISIONED
        try check(rc)
        defer { adi_buf_free(mid); adi_buf_free(otp) }
        guard mid.len > 0, otp.len > 0 else { throw MacAnisetteFailure.core("empty Store MID or OTP") }
        try saveStore(h)
        return [
            "X-Apple-AMD": Self.data(otp).base64EncodedString(),
            "X-Apple-AMD-M": Self.data(mid).base64EncodedString(),
        ]
    }

    /// Answer the Store auth endpoint's SP machine action (ipatool
    /// storeauth.ProvisionStoreAnisette): X-Apple-AMD-Data is the spim, the
    /// cpim goes to `endpoint` as clientData, settingInfo/transportKey finish it.
    /// `identity` is the machine anisette; its I-MD proofs and RINFO are dropped.
    public func provisionStore(challenge: String, identity: [String: String], endpoint: URL, userAgent: String) async throws {
        guard let spim = Data(base64Encoded: challenge.trimmingCharacters(in: .whitespaces)), !spim.isEmpty else {
            throw MacAnisetteFailure.badResponse("invalid Store provisioning challenge")
        }
        let h = try await open()
        _ = adi_erase(h, Self.storeDSID) // a stale Store identity blocks ProvisioningStart
        var cpim = AdiBuf(ptr: nil, len: 0)
        var session: UInt32 = 0
        try spim.withUnsafeBytes { raw in
            try check(adi_provisioning_begin(h, Self.storeDSID, raw.bindMemory(to: UInt8.self).baseAddress,
                                             raw.count, &cpim, &session))
        }
        let clientData = Self.data(cpim).base64EncodedString()
        adi_buf_free(cpim)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        for (key, value) in identity where !["x-apple-i-md", "x-apple-i-md-m", "x-apple-i-md-rinfo"].contains(key.lowercased()) {
            req.setValue(value, forHTTPHeaderField: key)
        }
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = try PropertyListSerialization.data(fromPropertyList: ["clientData": clientData], format: .xml, options: 0)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("--- store provisioning: HTTP \(status) from \(endpoint.host ?? "?")\(endpoint.path); sent \(req.allHTTPHeaderFields?.keys.sorted().joined(separator: ", ") ?? "")")
        if let http = response as? HTTPURLResponse {
            for (key, value) in http.allHeaderFields {
                let name = String(describing: key)
                if name.lowercased().hasPrefix("x-apple-") || name.lowercased() == "content-type" {
                    print("    \(name): \(["content-type", "x-apple-amd-action"].contains(name.lowercased()) ? "\(value)" : "<redacted>")")
                }
            }
        }
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            print("    plist keys: \(plist.keys.sorted().joined(separator: ", "))")
            for key in ["failureType", "customerMessage", "errorMessage", "status", "error"] {
                if let value = plist[key] { print("    \(key): \(value)") }
            }
        } else if let text = String(data: data.prefix(512), encoding: .utf8), !text.isEmpty {
            print("    body preview: \(text.replacingOccurrences(of: "\n", with: " "))")
        }
        guard status == 200 else { throw MacAnisetteFailure.badResponse("Store provisioning returned HTTP \(status)") }
        guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw MacAnisetteFailure.badResponse("Store provisioning returned an invalid plist")
        }
        let settingInfo = try field(result, "settingInfo")
        let transportKey = try field(result, "transportKey")
        if result["keybag"] != nil { print("[MacADI] Store provisioning returned a FairPlay keybag (not imported)") }
        try settingInfo.withUnsafeBytes { s in try transportKey.withUnsafeBytes { t in
            try check(adi_provisioning_finish(h, Self.storeDSID, session,
                s.bindMemory(to: UInt8.self).baseAddress, s.count,
                t.bindMemory(to: UInt8.self).baseAddress, t.count, 0))
        } }
        try saveStore(h)
        print("[MacADI] Provisioned Store anisette (DSID -1)")
    }
}
