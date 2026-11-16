//
//  AnisetteServer.swift
//  Serve WaffleStore's local CoreADI anisette to SideStore (and any other
//  anisette consumer) over the classic anisette-server JSON protocol:
//
//      GET /  ->  { "X-Apple-I-MD": ..., "X-Apple-I-MD-M": ..., ... }
//
//  Point SideStore's custom anisette server URL at http://127.0.0.1:<port>/.
//
//  The server uses its OWN persistent Mac identity (a dedicated CoreADI store),
//  not the per-login throwaway identity the App Store login flow creates and
//  wipes — SideStore needs a device anisette that stays stable across its auth.
//

import Foundation
import Network
import MacAnisetteKit

final class AnisetteServer: @unchecked Sendable {
    static let shared = AnisetteServer()

    /// Fixed loopback port so the SideStore URL never changes.
    static let port: UInt16 = 6969

    private let modern = ModernAnisetteClient(
        root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AnisetteServer", isDirectory: true))
    private let queue = DispatchQueue(label: "com.jbdotparty.PancakeStore.anisette-server")
    private var listener: NWListener?

    var endpointURL: String { "http://127.0.0.1:\(Self.port)/" }

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // Loopback only: never expose the device's anisette on the network.
            params.requiredInterfaceType = .loopback
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state { print("[Anisette] listener failed: \(error)") }
            }
            listener.start(queue: queue)
            print("[Anisette] serving local anisette at \(endpointURL)")
        } catch {
            print("[Anisette] could not start server: \(error)")
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else { conn.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            Task {
                let (status, body) = await self.response(for: path)
                let headers = """
                HTTP/1.1 \(status)\r
                Content-Type: application/json\r
                Content-Length: \(body.utf8.count)\r
                Connection: close\r
                \r

                """
                let payload = Data((headers + body).utf8)
                conn.send(content: payload, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }

    /// Classic anisette-server body. getHeaders() already returns the canonical
    /// field names; add X-Apple-I-MD-DateTime which some clients expect.
    private func response(for path: String) async -> (String, String) {
        guard path == "/" || path.hasPrefix("/?") else { return ("404 Not Found", "{}") }
        do {
            var headers = try await modern.getHeaders()
            if headers["X-Apple-I-MD-DateTime"] == nil {
                headers["X-Apple-I-MD-DateTime"] = headers["X-Apple-I-Client-Time"]
            }
            let data = try JSONSerialization.data(withJSONObject: headers, options: [.sortedKeys])
            return ("200 OK", String(decoding: data, as: UTF8.self))
        } catch {
            print("[Anisette] header generation failed: \(error)")
            return ("500 Internal Server Error", "{\"error\":\"anisette unavailable\"}")
        }
    }
}
