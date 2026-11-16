// Mac CoreADI identity and provisioning are implemented in AnisetteKit's
// MacAnisetteKit product (vendored Jimpactor adi-core, interpreter-only Unicorn).
import Foundation
import MacAnisetteKit

enum StoreAnisetteError: LocalizedError {
    case missingMachineAnisette, missingStoreProof
    var errorDescription: String? {
        switch self {
        case .missingMachineAnisette: "Mac CoreADI did not return the machine anisette (X-Apple-I-MD / X-Apple-I-MD-M)."
        case .missingStoreProof: "Store provisioning finished but CoreADI has no Store AMD proof."
        }
    }
}

final class StoreAnisette: @unchecked Sendable {
    static let shared = StoreAnisette()
    private let modern = ModernAnisetteClient(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacAnisette-v2", isDirectory: true)) // fresh identity; earlier builds left broken state
    private let lock = NSLock()
    private var preparation: Task<Void, Error>?

    private func waitForPreparation() async throws {
        let task: Task<Void, Error> = lock.withLock {
            if let preparation { return preparation }
            let task = Task { _ = try await modern.getHeaders() }
            preparation = task
            return task
        }
        do {
            try await task.value
        } catch {
            lock.withLock { preparation = nil }
            throw error
        }
    }

    /// Starts the Mac CoreADI download/provisioning at app launch. Subsequent
    /// requests use the same per-install identity and persisted CoreADI store.
    func prepare() async {
        do {
            try await waitForPreparation()
            print("[MacADI] Ready")
        } catch {
            print("[MacADI] Startup failed: \(error.localizedDescription)")
        }
    }

    func identityHeaders() async throws -> [String: String] {
        // getHeaders provisions the machine itself when needed.
        try await modern.getHeaders()
    }

    /// See ModernAnisetteClient.resetIdentity: a full login needs a machine
    /// identity that has never completed a Store login.
    func startFreshIdentity() async {
        lock.withLock { preparation = nil }
        await modern.resetIdentity()
    }

    static func storeHeaders(from identity: [String: String], endpoint: URL) throws -> [String: String] {
        // ipatool's native login (pkg/appstore/appstore_login.go loginRequest):
        // the machine anisette is sent to the Store auth endpoint with
        // X-Apple-I-MD / X-Apple-I-MD-M RENAMED to X-Apple-AMD / X-Apple-AMD-M,
        // dropping the I-MD names and keeping the rest (RINFO, LU, client time,
        // device id, client info). The AMSAnisette type-2 framework call is only
        // used for the later commerce download, never for login.
        var headers = identity.filter {
            !["x-apple-i-md", "x-apple-i-md-m"].contains($0.key.lowercased())
        }
        guard let otp = identity.first(where: { $0.key.lowercased() == "x-apple-i-md" })?.value,
              let mid = identity.first(where: { $0.key.lowercased() == "x-apple-i-md-m" })?.value,
              !otp.isEmpty, !mid.isEmpty else {
            throw StoreAnisetteError.missingMachineAnisette
        }
        headers["X-Apple-AMD"] = otp
        headers["X-Apple-AMD-M"] = mid
        return headers
    }

    // ipatool constants.go privateAppStoreProvisioningURL / storeAuthenticationUserAgent.
    static let storeProvisioningURL = URL(string: "https://auth.itunes.apple.com/auth/v1/otp/1.5/finish")!
    static let storeProvisioningUserAgent = "Configurator/2.21 (Macintosh; OS X 27.0.1; 26A434) AppleWebKit/0625.2.5.11.6"

    /// Store AMD pair from a previous SP provisioning, or nil (never throws:
    /// a missing/broken Store identity just means the full RP/SP login runs).
    func cachedStoreProof() async -> [String: String]? {
        do {
            return try await modern.storeProof()
        } catch {
            print("[MacADI] No cached Store proof: \(error.localizedDescription)")
            return nil
        }
    }

    /// Answers Apple's SP machine action with Store-specific ADI provisioning.
    func provisionStore(challenge: String, identity: [String: String]) async throws {
        try await modern.provisionStore(challenge: challenge, identity: identity,
                                        endpoint: Self.storeProvisioningURL,
                                        userAgent: Self.storeProvisioningUserAgent)
    }

    /// Fresh Store AMD pair after SP provisioning.
    func storeProof() async throws -> [String: String] {
        guard let proof = try await modern.storeProof() else { throw StoreAnisetteError.missingStoreProof }
        return proof
    }

    /// The commerce download uses the Store AMD pair once SP provisioning has
    /// run; before that, the relabeled machine anisette the login used.
    func storeAMDProof(for endpoint: URL) async throws -> [String: String] {
        if let proof = await cachedStoreProof() { return proof }
        let identity = try await identityHeaders()
        return try Self.storeHeaders(from: identity, endpoint: endpoint)
    }
}
