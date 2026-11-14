// Mac CoreADI identity and provisioning are implemented in AnisetteKit's
// MacAnisetteKit product (vendored Jimpactor adi-core, interpreter-only Unicorn).
import Foundation
import MacAnisetteKit

enum StoreAnisetteError: LocalizedError {
    case missingMachineAnisette
    var errorDescription: String? {
        "Mac CoreADI did not return the machine anisette (X-Apple-I-MD / X-Apple-I-MD-M)."
    }
}

final class StoreAnisette: @unchecked Sendable {
    static let shared = StoreAnisette()
    private let mac = MacAnisetteClient(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacAnisette", isDirectory: true))
    private let lock = NSLock()
    private var preparation: Task<Void, Error>?

    private func waitForPreparation() async throws {
        let task: Task<Void, Error> = lock.withLock {
            if let preparation { return preparation }
            let task = Task { _ = try await mac.getHeaders() }
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
        try await waitForPreparation()
        return try await mac.getHeaders()
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

    /// The commerce download reuses the same relabeled machine anisette as the
    /// login request. (ipatool runs the AMSAnisette type-2 framework here; the
    /// relabeled machine proof is the minimal native equivalent.)
    func storeAMDProof(for endpoint: URL) async throws -> [String: String] {
        let identity = try await identityHeaders()
        return try Self.storeHeaders(from: identity, endpoint: endpoint)
    }
}
