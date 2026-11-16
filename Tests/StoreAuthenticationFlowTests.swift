import Foundation

private struct Response {
    var action: String?
    var data: String = "challenge"
}

@main
struct StoreAuthenticationFlowTests {
    static func main() async throws {
        let identity = ["X-Apple-I-MD": "otp", "X-Apple-I-MD-M": "mid", "X-Apple-I-MD-RINFO": "routing", "X-Mme-Device-Id": "device"]
        var sent = [[String: String]]()
        var provisioned = false
        let response: Response = try await StoreAuthenticationFlow.run(
            cachedProof: { nil },
            identity: { identity },
            provision: { challenge, headers in
                precondition(challenge == "challenge")
                precondition(headers == identity, "SP must retain the original identity")
                provisioned = true
            },
            storeProof: { ["X-Apple-AMD": "store-otp", "X-Apple-AMD-M": "store-mid"] },
            send: { headers in
                sent.append(headers)
                return Response(action: sent.count == 1 ? "RP" : sent.count == 2 ? "SP" : nil)
            },
            action: { response in response.action.map { ($0, response.data) } }
        )
        precondition(response.action == nil && provisioned && sent.count == 3)
        precondition(sent[0]["X-Apple-AMD"] == "otp" && sent[0]["X-Apple-AMD-M"] == "mid")
        precondition(sent[0]["X-Apple-I-MD"] == nil && sent[0]["X-Apple-I-MD-M"] == nil)
        precondition(sent[0]["X-Apple-I-MD-RINFO"] == "routing")
        precondition(sent[1] == ["X-Mme-Device-Id": "device"], "RP must drop both proofs AND routing info")
        precondition(sent[2] == ["X-Apple-AMD": "store-otp", "X-Apple-AMD-M": "store-mid"])
        print("PASS RP -> SP -> provisioned Store proof")

        // A cached Store proof is tried before general-machine provisioning.
        var cacheSends = 0
        let cached: Response = try await StoreAuthenticationFlow.run(
            cachedProof: { ["X-Apple-AMD": "cached", "X-Apple-AMD-M": "cached-mid"] },
            identity: { fatalError("cached Store proof must not reprovision the machine") },
            provision: { _, _ in fatalError("unexpected provisioning") },
            storeProof: { fatalError("unexpected new proof") },
            send: { headers in
                precondition(headers["X-Apple-AMD"] == "cached")
                cacheSends += 1
                return Response(action: nil)
            },
            action: { response in response.action.map { ($0, response.data) } }
        )
        precondition(cached.action == nil && cacheSends == 1)
        print("PASS cached proof skips machine provisioning")

        // A rejected cached Store proof falls back to the full RP -> SP flow.
        var fallbackSent = [[String: String]]()
        var fallbackProvisioned = false
        let fallback: Response = try await StoreAuthenticationFlow.run(
            cachedProof: { ["X-Apple-AMD": "stale", "X-Apple-AMD-M": "stale-mid"] },
            identity: { identity },
            provision: { _, _ in fallbackProvisioned = true },
            storeProof: { ["X-Apple-AMD": "fresh", "X-Apple-AMD-M": "fresh-mid"] },
            send: { headers in
                fallbackSent.append(headers)
                return Response(action: [2: "RP", 3: "SP"][fallbackSent.count] ?? (fallbackSent.count == 1 ? "RP" : nil))
            },
            action: { response in response.action.map { ($0, response.data) } }
        )
        precondition(fallback.action == nil && fallbackProvisioned && fallbackSent.count == 4)
        precondition(fallbackSent[0]["X-Apple-AMD"] == "stale" && fallbackSent[1]["X-Apple-AMD"] == "otp")
        precondition(fallbackSent[3]["X-Apple-AMD"] == "fresh")
        print("PASS rejected cached proof reruns RP/SP")

        // Unknown actions / direct SP remain terminal, and repeated RP cannot loop.
        for actions in [["SP"], ["UNKNOWN"], ["RP", "RP"], ["RP", "UNKNOWN"], ["RP", ""]] {
            var index = 0
            let final: Response = try await StoreAuthenticationFlow.run(
                cachedProof: { nil }, identity: { identity },
                provision: { _, _ in fatalError("unexpected provisioning for \(actions)") },
                storeProof: { fatalError("unexpected proof for \(actions)") },
                send: { _ in
                    precondition(index < actions.count, "unbounded machine-action retry")
                    let current = actions[index]
                    index += 1
                    return Response(action: current.isEmpty ? nil : current)
                },
                action: { response in response.action.map { ($0, response.data) } }
            )
            precondition(index == actions.count)
            precondition(final.action == (actions.last!.isEmpty ? nil : actions.last!))
        }
        print("PASS terminal actions and bounded RP retry")

        let lowercase = StoreAuthenticationFlow.requestHeaders(from: [
            "x-apple-i-md": "otp", "x-apple-i-md-m": "mid", "x-apple-i-md-rinfo": "route"
        ])
        precondition(lowercase["X-Apple-AMD"] == "otp" && lowercase["X-Apple-AMD-M"] == "mid")
        precondition(lowercase["x-apple-i-md"] == nil && lowercase["x-apple-i-md-m"] == nil)
        precondition(lowercase["x-apple-i-md-rinfo"] == "route")
        print("PASS case-insensitive proof translation")

        enum ProvisioningFailure: Error { case refused }
        var failureSends = 0
        do {
            let _: Response = try await StoreAuthenticationFlow.run(
                cachedProof: { nil }, identity: { identity },
                provision: { _, _ in throw ProvisioningFailure.refused },
                storeProof: { fatalError("must not request a proof after provisioning failed") },
                send: { _ in
                    failureSends += 1
                    return Response(action: failureSends == 1 ? "RP" : "SP")
                },
                action: { response in response.action.map { ($0, response.data) } }
            )
            fatalError("provisioning error was swallowed")
        } catch ProvisioningFailure.refused {
            precondition(failureSends == 2)
        }
        print("PASS provisioning errors propagate without another login")
    }
}
