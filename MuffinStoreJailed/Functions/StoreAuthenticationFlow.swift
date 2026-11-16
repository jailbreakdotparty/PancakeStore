// Native port of ipatool v2.8.0 pkg/appstore/appstore_native_login.go.
// Copyright (c) 2021 Majd Alfhaily. MIT; see AnisetteKit/SourcesSAP/LICENSE.ipatool.
import Foundation

/// Keep the machine identity intact until each request is built: RP removes
/// the original I-MD proofs, not an already-renamed AMD dictionary. Each retry
/// runs a complete login round, including its signed redirects / attempt-2.
enum StoreAuthenticationFlow {
    static func run<Response>(
        cachedProof: () async throws -> [String: String]?,
        identity: () async throws -> [String: String],
        provision: (String, [String: String]) async throws -> Void,
        storeProof: () async throws -> [String: String],
        send: ([String: String]) async throws -> Response,
        action: (Response) -> (action: String, data: String)?
    ) async throws -> Response {
        if let proof = try await cachedProof() {
            let cached = try await send(requestHeaders(from: proof))
            guard action(cached) != nil else { return cached }
            // Apple rejected the persisted Store identity; start over below.
        }
        let original = try await identity()
        let first = try await send(requestHeaders(from: original))
        guard action(first)?.action == "RP" else { return first }

        let retryHeaders = original.filter {
            !["x-apple-i-md", "x-apple-i-md-m", "x-apple-i-md-rinfo"].contains($0.key.lowercased())
        }
        let retry = try await send(requestHeaders(from: retryHeaders))
        guard let challenge = action(retry), challenge.action == "SP" else { return retry }

        try await provision(challenge.data, original)
        let proof = try await storeProof()
        return try await send(requestHeaders(from: proof))
    }

    static func requestHeaders(from identity: [String: String]) -> [String: String] {
        var headers = identity.filter {
            !["x-apple-i-md", "x-apple-i-md-m"].contains($0.key.lowercased())
        }
        if let otp = identity.first(where: { $0.key.lowercased() == "x-apple-i-md" })?.value, !otp.isEmpty {
            headers["X-Apple-AMD"] = otp
        }
        if let mid = identity.first(where: { $0.key.lowercased() == "x-apple-i-md-m" })?.value, !mid.isEmpty {
            headers["X-Apple-AMD-M"] = mid
        }
        return headers
    }
}
