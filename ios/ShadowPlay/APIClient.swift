import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case unauthorized
    case pairingRejected
    case clipNotFound
    case forbidden
    case http(Int, String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The PC address is not valid."
        case .unauthorized: return "Access was revoked or the session expired. Pair again on your PC."
        case .pairingRejected: return "Pairing code invalid, expired or already used. Generate a new code on the PC."
        case .clipNotFound: return "That clip is no longer available on the PC."
        case .forbidden: return "Your phone is not on the same network as the PC. Join the same Wi-Fi."
        case .http(let status, let message):
            return message ?? "Request failed (HTTP \(status))."
        }
    }
}

/// Thin async client for the desktop LAN API (protocol v1).
struct APIClient {
    var address: String
    var port: Int
    var token: String?

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder.shadowPlay.decode(T.self, from: data)
    }

    private static func errorMessage(_ data: Data?) -> String? {
        guard let data, let apiError = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return apiError["error"]
    }

    private var base: URL? {
        URL(string: "http://\(address):\(port)/api/v1")
    }

    private func request(_ path: String) throws -> URLRequest {
        guard let base, let url = URL(string: path, relativeTo: base) else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Throws `.unauthorized` for any auth failure so callers can route to re-pairing.
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(-1, nil)
        }

        switch http.statusCode {
        case 200...299:
            return (data, http)
        case 401: throw APIError.unauthorized
        case 403: throw APIError.forbidden
        case 404: throw APIError.clipNotFound
        case 409: throw APIError.pairingRejected
        default: throw APIError.http(http.statusCode, Self.errorMessage(data))
        }
    }

    // MARK: - Endpoints

    func health() async throws -> Bool {
        let response = try await send(request("/health"))
        return response.1.statusCode == 200
    }

    func clips() async throws -> [Clip] {
        let (data, _) = try await send(request("/clips"))
        return try Self.decode([Clip].self, from: data)
    }

    func serverInfo() async throws -> ServerInfo {
        let (data, _) = try await send(request("/server"))
        return try Self.decode(ServerInfo.self, from: data)
    }

    /// Exchanges a pairing code for a long-lived token.
    static func pair(address: String, port: Int, code: String, deviceName: String) async throws -> PairResponse {
        guard let url = URL(string: "http://\(address):\(port)/api/v1/pair/exchange") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30 // server delays every exchange by ~300 ms by design
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "pairingCode": code,
            "deviceName": deviceName,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.http(-1, nil) }

        switch http.statusCode {
        case 200...299:
            return try Self.decode(PairResponse.self, from: data)
        case 400: throw APIError.invalidURL
        default:
            if Self.errorMessage(data) == "pairing_code_invalid_or_expired" {
                throw APIError.pairingRejected
            }
            throw APIError.http(http.statusCode, Self.errorMessage(data))
        }
    }

    /// Authenticated download URL for streaming (AVPlayer) or downloading.
    /// Note: AVPlayer cannot attach custom headers; for streaming we rely on the fact
    /// that URLSession-based playback is used via a proxy-less approach in PlayerView
    /// (header injection is handled there). For plain downloads use `downloadRequest`.
    func downloadRequest(for clip: Clip) throws -> URLRequest {
        try request("/clips/\(clip.id)/download")
    }
}
