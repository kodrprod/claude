import Foundation
import APEX

// MARK: - ServerClient
//
// Replace SERVER_BASE_URL with your actual server endpoint.
// The server needs to implement:
//   POST /register         — upload pre-key bundle + registration
//   GET  /bundle/{userID}  — fetch a peer's pre-key bundle
//   POST /send             — deliver an envelope
//   GET  /inbox            — poll for pending envelopes
//
// A minimal reference server implementation is included in
// the setup guide (Server/README.md).

actor ServerClient {
    static let shared = ServerClient()

    // ── Replace this with your server URL ──────────────────────────────
    private let baseURL = URL(string: "https://YOUR_SERVER_URL")!
    // ───────────────────────────────────────────────────────────────────

    private let session = URLSession.shared

    // MARK: - Register / upload bundle

    func register(serverID: String, displayName: String, bundleData: Data) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("register"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = RegistrationRequest(serverID: serverID, displayName: displayName, bundle: bundleData)
        req.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ServerError.registrationFailed
        }
    }

    // MARK: - Fetch peer bundle

    func fetchBundle(serverID: String) async throws -> ReceivedBundle {
        let url = baseURL.appendingPathComponent("bundle/\(serverID)")
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode(ReceivedBundle.self, from: data)
    }

    // MARK: - Send envelope

    func send(envelope: APEXEnvelope) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("send"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try APEX.encodeEnvelope(envelope)
        let (_, _) = try await session.data(for: req)
    }

    // MARK: - Poll inbox

    func fetchInbox(serverID: String) async throws -> [Data] {
        let url = baseURL.appendingPathComponent("inbox/\(serverID)")
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode([Data].self, from: data)
    }
}

// MARK: - Request / Error types

private struct RegistrationRequest: Encodable {
    let serverID: String
    let displayName: String
    let bundle: Data
}

enum ServerError: LocalizedError {
    case registrationFailed
    case bundleNotFound
    case deliveryFailed

    var errorDescription: String? {
        switch self {
        case .registrationFailed: return "Registration failed. Check server URL."
        case .bundleNotFound:     return "Peer not found on server."
        case .deliveryFailed:     return "Message delivery failed."
        }
    }
}
