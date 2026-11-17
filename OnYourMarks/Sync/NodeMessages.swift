//
//  NodeMessages.swift
//  OnYourMarks
//
//  What phones say to each other. Every message travels in an envelope
//  with the protocol version, the sender and its clock epoch.
//

import Foundation

/// One phone taking part, the same across launches.
nonisolated struct NodeID: Hashable, Codable, Sendable, Comparable {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    /// Four characters to tell phones apart by eye: shown on the phone
    /// itself and next to it in the others' lists. Letters and digits that
    /// can't be mistaken for each other.
    var shortCode: String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let bytes = withUnsafeBytes(of: rawValue.uuid) { Array($0) }
        let value = bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }

        return String((0..<Self.shortCodeLength).map { alphabet[Int(value >> (5 * UInt32($0))) & 31] })
    }

    private static let shortCodeLength = 4

    static func < (lhs: NodeID, rhs: NodeID) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }
}

/// What a phone does in a start. Roles are chosen on each phone; one
/// phone can have several later (a camera that also plays the gun).
nonisolated enum NodeRole: String, Codable, Sendable, CaseIterable {
    /// Runs the start and decides.
    case controller
    /// Watches the athletes.
    case camera
    /// Plays the commands and the gun.
    case speaker
}

/// How a phone presents itself, in its Bonjour record and in `hello`.
nonisolated struct NodeAnnouncement: Equatable, Codable, Sendable {
    let id: NodeID
    let name: String
    let role: NodeRole
    let protocolVersion: Int

    /// Bonjour TXT record keys.
    private enum Key {
        static let id = "id"
        static let name = "name"
        static let role = "role"
        static let version = "v"
    }

    var txtRecord: [String: String] {
        [Key.id: id.rawValue.uuidString, Key.name: name, Key.role: role.rawValue, Key.version: String(protocolVersion)]
    }

    init(id: NodeID, name: String, role: NodeRole, protocolVersion: Int = NodeProtocol.version) {
        self.id = id
        self.name = name
        self.role = role
        self.protocolVersion = protocolVersion
    }

    init?(txtRecord: [String: String]) {
        guard
            let id = txtRecord[Key.id].flatMap(UUID.init(uuidString:)),
            let role = txtRecord[Key.role].flatMap(NodeRole.init(rawValue:)),
            let version = txtRecord[Key.version].flatMap(Int.init)
        else { return nil }

        self.init(id: NodeID(id), name: txtRecord[Key.name] ?? "", role: role, protocolVersion: version)
    }
}

nonisolated enum NodeProtocol {
    /// Raised whenever a message changes so that an older phone can't read
    /// it. Phones with another version are listed but not talked to.
    static let version = 1

    /// The Bonjour service; listed under `NSBonjourServices` in Info.plist.
    static let serviceType = "_onyourmarks._udp"

    /// A datagram larger than this may be fragmented, which costs time and
    /// loses the whole message if one fragment is lost. Messages stay
    /// far below; a larger one is not sent.
    static let maximumDatagramSize = 1200
}

/// Everything a phone sends. New kinds of message become cases here
/// (detector events, "play the gun at this time"), so they can be
/// recorded and replayed like the rest.
nonisolated enum NodeMessage: Equatable, Codable, Sendable {
    /// Sent when a phone finds another, so each knows the other's name
    /// and role even without its Bonjour record.
    case hello(NodeAnnouncement)
    case syncRequest(SyncRequest)
    case syncReply(SyncReply)
}

nonisolated struct NodeEnvelope: Equatable, Codable, Sendable {
    let version: Int
    let sender: NodeID
    /// The sender's clock epoch when it sent this; a reply's is the one
    /// its stamps belong to.
    let epoch: ClockEpoch
    let message: NodeMessage

    init(sender: NodeID, epoch: ClockEpoch, message: NodeMessage, version: Int = NodeProtocol.version) {
        self.version = version
        self.sender = sender
        self.epoch = epoch
        self.message = message
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Another protocol version's message fails as such: only `version`
    /// is read from it.
    static func decode(_ data: Data) -> Result<NodeEnvelope, NodeDecodingFailure> {
        let decoder = JSONDecoder()

        if let envelope = try? decoder.decode(NodeEnvelope.self, from: data) {
            guard envelope.version == NodeProtocol.version else { return .failure(.otherVersion(envelope.version)) }
            return .success(envelope)
        }

        if let header = try? decoder.decode(VersionHeader.self, from: data), header.version != NodeProtocol.version {
            return .failure(.otherVersion(header.version))
        }

        return .failure(.unreadable)
    }

    private struct VersionHeader: Decodable {
        let version: Int
    }
}

nonisolated enum NodeDecodingFailure: Error, Equatable {
    case unreadable
    case otherVersion(Int)
}
