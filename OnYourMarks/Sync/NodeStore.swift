//
//  NodeStore.swift
//  OnYourMarks
//

import Foundation
import OSLog

/// This phone as the others see it.
nonisolated struct NodeIdentity: Equatable, Codable, Sendable {
    let id: NodeID
    var name: String
    var role: NodeRole
}

/// A phone the user chose to work with, under the name it last had.
nonisolated struct PairedNode: Equatable, Codable, Sendable {
    let id: NodeID
    var name: String
}

/// Keeps this phone's identity and its paired phones across launches.
struct NodeStore {
    private let identityKey = "nodeIdentity"
    private let pairedKey = "pairedNodes"
    private let defaults: UserDefaults

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OnYourMarks",
        category: "Config"
    )

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Created on first use, so the phone keeps its ID and code.
    func loadIdentity(defaultName: String) -> NodeIdentity {
        if let identity: NodeIdentity = load(identityKey) {
            return identity
        }

        let identity = NodeIdentity(id: NodeID(), name: defaultName, role: .controller)
        save(identity)
        return identity
    }

    func save(_ identity: NodeIdentity) {
        store(identity, at: identityKey)
    }

    func loadPaired() -> [PairedNode] {
        load(pairedKey) ?? []
    }

    func save(_ paired: [PairedNode]) {
        store(paired, at: pairedKey)
    }

    private func load<Value: Decodable>(_ key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }

        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            logger.error("Could not decode \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func store<Value: Encodable>(_ value: Value, at key: String) {
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            logger.error("Could not save \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
