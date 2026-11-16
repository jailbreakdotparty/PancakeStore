import Foundation
import NativeStore

public enum StoreProofError: LocalizedError {
    case unavailable

    public var errorDescription: String? {
        "AppleMediaServices did not provide the Store AMD type-2 headers on this device."
    }
}

/// Obtains a fresh Store-specific proof from iOS AppleMediaServices. AuthKit
/// CoreADI's I-MD pair must not be renamed and used as a Store AMD proof.
public func storeAMDProof(for endpoint: URL) throws -> [String: String] {
    let authPaths = ["/auth/v1/native", "/auth/v1/native/", "/auth/v1/native/fast", "/auth/v1/native/fast/"]
    let commercePath = "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct"
    let host = endpoint.host ?? ""
    let isAuth = host == "auth.itunes.apple.com" && authPaths.contains(endpoint.path)
    let suffix = "-buy.itunes.apple.com"
    let podNumber = host.hasSuffix(suffix) ? String(host.dropFirst().dropLast(suffix.count)) : ""
    let pod = host.hasPrefix("p") && !podNumber.isEmpty && podNumber.allSatisfy(\.isNumber)
    let isCommerce = (host == "buy.itunes.apple.com" || pod) && endpoint.path == commercePath
    guard endpoint.scheme == "https", endpoint.user == nil, endpoint.password == nil,
          (endpoint.port == nil || endpoint.port == 443), endpoint.fragment == nil,
          (isAuth || isCommerce) else {
        throw StoreProofError.unavailable
    }
    
    let headers = StoreAMDHeaders(endpoint) ?? [:]
    guard !headers.isEmpty else { throw StoreProofError.unavailable }
    return headers
}
