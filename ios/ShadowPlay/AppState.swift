import Foundation
import SwiftUI

/// Persisted app state: known PCs and which one is active.
/// Tokens live in the Keychain; everything else in UserDefaults.
@MainActor
final class AppState: ObservableObject {
    @Published var connections: [Connection] = [] {
        didSet { persist() }
    }

    @Published var activeServerId: String? {
        didSet { persist() }
    }

    var active: Connection? {
        guard let id = activeServerId else { return nil }
        return connections.first { $0.serverId == id }
    }

    var activeToken: String? {
        guard let id = activeServerId else { return nil }
        return Keychain.token(serverId: id)
    }

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "connections"),
           let saved = try? JSONDecoder().decode([Connection].self, from: data) {
            connections = saved
        }
        activeServerId = defaults.string(forKey: "activeServerId")
        if activeServerId != nil && active == nil {
            activeServerId = nil
        }
    }

    /// Saves a freshly paired PC and makes it active.
    func addPaired(server: ServerInfo, address: String, port: Int, token: String) {
        Keychain.saveToken(token, serverId: server.serverId)

        if let index = connections.firstIndex(where: { $0.serverId == server.serverId }) {
            connections[index].address = address
            connections[index].port = port
            connections[index].computerName = server.computerName
        } else {
            connections.append(Connection(
                serverId: server.serverId,
                computerName: server.computerName,
                address: address,
                port: port))
        }

        activeServerId = server.serverId
    }

    func setActive(_ connection: Connection) {
        guard Keychain.token(serverId: connection.serverId) != nil else { return }
        activeServerId = connection.serverId
    }

    /// Forgets a PC locally. (Revoking access itself must be done on the PC.)
    func forget(serverId: String) {
        Keychain.deleteToken(serverId: serverId)
        connections.removeAll { $0.serverId == serverId }
        if activeServerId == serverId {
            activeServerId = nil
        }
    }

    func updateAddress(serverId: String, address: String) {
        guard let index = connections.firstIndex(where: { $0.serverId == serverId }) else { return }
        if connections[index].address != address {
            connections[index].address = address
        }
    }

    private func persist() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(connections) {
            defaults.set(data, forKey: "connections")
        }
        if let id = activeServerId {
            defaults.set(id, forKey: "activeServerId")
        } else {
            defaults.removeObject(forKey: "activeServerId")
        }
    }
}

extension AppState {
    /// Builds a client for the active PC, or nil when unpaired.
    func makeClient() -> APIClient? {
        guard let connection = active else { return nil }
        return APIClient(address: connection.address, port: connection.port, token: activeToken)
    }
}
