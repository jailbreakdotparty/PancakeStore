//
//  AnisetteKitTests.swift
//  AnisetteKit
//
//  Created by Magesh K on 20/07/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

import Testing
import Foundation
@testable import AnisetteKit

struct AnisetteKitTests {

    @Test
    func unicornAnisetteProvisioningAndHeaders() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("AnisetteKitTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        print("[Test] Initializing Anisette at fresh temp directory: \(tempDir.path)")
        fflush(stdout)
        let libURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/lib/arm64-v8a")
        let anisette = try AnisetteClient(
            provisioningDir: tempDir,
            clientInfo: AnisetteConstants.defaultClientInfo,
            provider: UnicornAnisetteDataProvider()
        ) {
            libURL
        }
        let identifier = UUID()

        print("[Test] 1. Testing UNICORN runProvisioningFlow (actual online provisioning flow)...")
        fflush(stdout)
        let adiPbUC = try await anisette.runProvisioningFlow(identifier: identifier, provider: UnicornAnisetteDataProvider())
        print("[Test] UNICORN PROVISIONING SUCCESS! Generated adi.pb size = \(adiPbUC.count) bytes")
        fflush(stdout)

        #expect(adiPbUC.count > 100, "Generated adi.pb size should be > 100 bytes")

        print("[Test] 2. Testing UNICORN getAnisetteData on freshly provisioned adi.pb...")
        fflush(stdout)
        let (headers, _) = try await anisette.getAnisetteData(identifier: identifier)
        print("[Test] UNICORN GET HEADERS SUCCESS! Received Headers:")
        for (key, val) in headers {
            print("  \(key): \(val)")
        }
        fflush(stdout)

        #expect(!(headers["X-Apple-I-MD-M"]?.isEmpty ?? true), "X-Apple-I-MD-M should not be empty")
        #expect(!(headers["X-Apple-I-MD"]?.isEmpty ?? true), "X-Apple-I-MD should not be empty")
        #expect(headers["X-Apple-I-MD-RINFO"] == "17106176", "X-Apple-I-MD-RINFO should match expected 17106176")
    }

    @Test
    func anisetteRequestHeadersCustomization() {
        let h1 = AnisetteRequestHeaders().with {
            $0.deviceID = "TEST_DEV_ID"
            $0.clientInfo = "TEST_CLIENT_INFO"
        }
        #expect(h1.deviceID == "TEST_DEV_ID")
        #expect(h1.clientInfo == "TEST_CLIENT_INFO")

        let h2 = AnisetteRequestHeaders.defaultHeaders.with {
            $0.deviceID = "CUSTOM_DEV_ID"
        }
        #expect(h2.deviceID == "CUSTOM_DEV_ID")
        #expect(h2.clientInfo == AnisetteConstants.defaultClientInfo)
        #expect(h2.routingInfo == AnisetteConstants.defaultRoutingInfo)

        let h3 = h2.with {
            $0.routingInfo = "999999"
        }
        #expect(h3.deviceID == "CUSTOM_DEV_ID")
        #expect(h3.routingInfo == "999999")

        let h4 = h1.with {
            $0.serialNumber = "12345"
        }
        #expect(h4.deviceID == "TEST_DEV_ID")
        #expect(h4.serialNumber == "12345")
    }

    @Test
    func anisetteDataResponseStructure() {
        let resp = AnisetteDataResponse(oneTimePassword: "OTP", machineID: "MID")
        #expect(resp.oneTimePassword == "OTP")
        #expect(resp.machineID == "MID")
    }

    @Test
    func anisetteHeadersDTORoundtrip() {
        let headers = AnisetteRequestHeaders().with {
            $0.machineID = "M_TEST"
            $0.oneTimePassword = "OTP_TEST"
            $0.localUserID = "LU_TEST"
            $0.routingInfo = "RINFO_TEST"
            $0.deviceID = "DEV_TEST"
            $0.serialNumber = "SRL_TEST"
            $0.clientInfo = "CI_TEST"
            $0.userAgent = "UA_TEST"
            $0.locale = "en_US"
            $0.timeZone = "UTC"
        }

        let dict = AnisetteHeadersDTO.toDictionary(from: headers)
        #expect(dict[AnisetteConstants.Headers.machineID] == "M_TEST")
        #expect(dict[AnisetteConstants.Headers.oneTimePassword] == "OTP_TEST")
        #expect(dict[AnisetteConstants.Headers.localUserID] == "LU_TEST")
        #expect(dict[AnisetteConstants.Headers.routingInfo] == "RINFO_TEST")
        #expect(dict[AnisetteConstants.Headers.deviceID] == "DEV_TEST")
        #expect(dict[AnisetteConstants.Headers.serialNumber] == "SRL_TEST")
        #expect(dict[AnisetteConstants.Headers.clientInfo] == "CI_TEST")
        #expect(dict[AnisetteConstants.Headers.userAgent] == "UA_TEST")
        #expect(dict[AnisetteConstants.Headers.locale] == "en_US")
        #expect(dict[AnisetteConstants.Headers.timeZone] == "UTC")

        let restored = AnisetteHeadersDTO.toHeaders(from: dict)
        #expect(restored.machineID == "M_TEST")
        #expect(restored.oneTimePassword == "OTP_TEST")
        #expect(restored.localUserID == "LU_TEST")
        #expect(restored.routingInfo == "RINFO_TEST")
        #expect(restored.deviceID == "DEV_TEST")
        #expect(restored.serialNumber == "SRL_TEST")
        #expect(restored.clientInfo == "CI_TEST")
        #expect(restored.userAgent == "UA_TEST")
        #expect(restored.locale == "en_US")
        #expect(restored.timeZone == "UTC")
    }
}
