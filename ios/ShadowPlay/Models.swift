import Foundation

// Wire-exact models for the ShadowPlay desktop API (protocol v1).
// See docs/IOS_HANDOFF.md for the authoritative contract.

struct QrPayload: Codable {
    let v: Int
    let serverId: String
    let computerName: String
    let lanAddress: String
    let port: Int
    let pairingCode: String
}

struct Clip: Codable, Identifiable, Hashable {
    let id: String
    let fileName: String
    let sizeBytes: Int64
    let lastWriteTimeUtc: Date
}

struct ServerInfo: Codable {
    let serverId: String
    let computerName: String
    let protocolVersion: Int
    let startedUtc: Date
    let clipCount: Int
}

struct PairResponse: Codable {
    let token: String
    let deviceId: String
    let server: ServerInfo
}

/// A paired PC as persisted on the phone.
struct Connection: Codable, Identifiable, Hashable {
    var id: String { serverId }
    var serverId: String
    var computerName: String
    /// Last known LAN address; refreshed whenever a request succeeds.
    var address: String
    var port: Int
}

extension JSONDecoder {
    /// The desktop app (System.Text.Json) emits ISO-8601 offsets, sometimes with
    /// fractional seconds. Accept both.
    static let shadowPlay: JSONDecoder = {
        let decoder = JSONDecoder()

        func makeFormatter(withFractionalSeconds: Bool) -> ISO8601DateFormatter {
            let formatter = ISO8601DateFormatter()
            var options: ISO8601DateFormatter.Options = [.withInternetDateTime]
            if withFractionalSeconds { options.insert(.withFractionalSeconds) }
            formatter.formatOptions = options
            return formatter
        }

        let fractional = makeFormatter(withFractionalSeconds: true)
        let plain = makeFormatter(withFractionalSeconds: false)

        decoder.dateDecodingStrategy = .custom { container in
            let raw = try container.singleValueContainer().decode(String.self)
            if let date = fractional.date(from: raw) ?? plain.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "Unparseable date: \(raw)"))
        }

        return decoder
    }()
}
