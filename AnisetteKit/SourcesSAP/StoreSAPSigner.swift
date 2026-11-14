import Foundation

/// App-facing adapter around the vendored ipaverse SAP state machine.
/// A signer must remain alive across native-auth redirects and retries;
/// each request body is signed *after* serialization and before sending.
public final class StoreSAPSigner {
    private let signer: SAPSigner

    private init(_ signer: SAPSigner) { self.signer = signer }

    public static func create(setupURL: URL, certificateURL: URL, version: UInt32, guid: String) async throws -> StoreSAPSigner {
        guard setupURL.scheme == "https", setupURL.host == "fpinit.itunes.apple.com",
              certificateURL.scheme == "https", certificateURL.host == "s.mzstatic.com",
              guid.count == 12 else { throw SAPSignerError.invalidHardwareID }
        let chars = Array(guid)
        let hardwareID = try stride(from: 0, to: chars.count, by: 2).map { offset -> UInt8 in
            guard let byte = UInt8(String(chars[offset...offset+1]), radix: 16) else {
                throw SAPSignerError.invalidHardwareID
            }
            return byte
        }
        print("[SAP] Fetching and validating Apple signing assets...")
        let bundle = try await SAPAssets.load()
        print("[SAP] Starting SAP setup (version \(version))...")
        let signer = try await SAPSigner.create(setupURL: setupURL, certificateURL: certificateURL,
                                                 version: version, hardwareID: hardwareID, bundle: bundle)
        print("[SAP] Signing session established")
        return StoreSAPSigner(signer)
    }

    public func sign(_ body: Data) throws -> String {
        try signer.sign(body).base64EncodedString()
    }

    public func close() { signer.close() }
}
