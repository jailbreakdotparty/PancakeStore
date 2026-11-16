//
//  FairPlayDecrypt.swift
//  Decrypt an App Store IPA on-device using the hardware FairPlay keys.
//
//  Wraps the vendored FairPlayed core (fpcore.c / zipio.c) via the
//  LCFairPlayPipeline Objective-C orchestrator in AnisetteKit's FairPlayKit.
//  Decryption uses mremap_encrypted(cryptid=2) and only works on a physical
//  arm64 device whose Media account can read the SINF keys — never in a
//  simulator or on this Linux build host.
//

import Foundation
import FairPlayKit

enum FairPlayDecryptor {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Decrypt a signed-structure App Store IPA (its SC_Info SINFs already in
    /// place, as `downloadIPAForVersion` writes them) into a new IPA whose
    /// every Mach-O has `cryptid == 0`. Returns the decrypted IPA URL.
    @discardableResult
    static func decrypt(ipaAt input: URL) throws -> URL {
        let fm = FileManager.default
        let output = input.deletingPathExtension().appendingPathExtension("decrypted.ipa")
        try? fm.removeItem(at: output)

        // fairplayd resolves the SINF path under its own sandbox, and which
        // container it can read differs by device. Try temp first, then
        // Documents; the pipeline re-extracts for each root.
        let stagingRoots = [
            fm.temporaryDirectory,
            fm.urls(for: .documentDirectory, in: .userDomainMask)[0],
        ]

        do {
            let result = try LCFairPlayPipeline.decryptIPA(
                at: input,
                stagingRoots: stagingRoots,
                outputURL: output,
                progress: { phase, done, total in
                    print("[FairPlay] \(phase) \(done)/\(total)")
                }
            )
            print("[FairPlay] Decrypted IPA at \(result.path)")
            return result
        } catch {
            let ns = error as NSError
            for line in (ns.userInfo[LCFairPlayDiagnosticsKey] as? [String]) ?? [] {
                print("[FairPlay] \(line)")
            }
            for root in (ns.userInfo[LCFairPlayAttemptedRootsKey] as? [String]) ?? [] {
                print("[FairPlay] attempted root: \(root)")
            }
            throw Failure(message: ns.localizedDescription)
        }
    }
}
