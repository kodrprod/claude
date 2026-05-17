import Foundation
import APEX

// MARK: - Conversation

struct Conversation: Identifiable, Codable {
    let id: UUID
    var peerServerID: String
    var peerDisplayName: String
    var peerIdentityKeyData: Data
    var sessionID: String
    var lastMessagePreview: String
    var lastMessageDate: Date
    var unreadCount: Int
    var safetyNumberVerified: Bool

    init(
        peerServerID: String,
        peerDisplayName: String,
        peerIdentityKeyData: Data,
        sessionID: String = ""
    ) {
        self.id = UUID()
        self.peerServerID = peerServerID
        self.peerDisplayName = peerDisplayName
        self.peerIdentityKeyData = peerIdentityKeyData
        self.sessionID = sessionID
        self.lastMessagePreview = ""
        self.lastMessageDate = Date()
        self.unreadCount = 0
        self.safetyNumberVerified = false
    }
}

// MARK: - Message

struct Message: Identifiable, Codable {
    let id: UUID
    let conversationID: UUID
    let body: String
    let isOutgoing: Bool
    let timestamp: Date
    var status: MessageStatus
    var isHighSecurity: Bool

    init(
        conversationID: UUID,
        body: String,
        isOutgoing: Bool,
        isHighSecurity: Bool = false
    ) {
        self.id = UUID()
        self.conversationID = conversationID
        self.body = body
        self.isOutgoing = isOutgoing
        self.timestamp = Date()
        self.status = isOutgoing ? .sending : .received
        self.isHighSecurity = isHighSecurity
    }
}

enum MessageStatus: String, Codable {
    case sending
    case sent
    case delivered
    case read
    case failed
    case received
}

// MARK: - Stored Identity

struct StoredIdentity: Codable {
    let serverID: String
    let displayName: String
    let registrationID: UInt16
    let identityKeyData: Data
    let signingKeyData: Data
    let signedPreKeyData: Data
    let signedPreKeyID: UInt32
    let signedPreKeySignature: Data
    let createdAt: Date
}

// MARK: - Server Bundle (received from peer via server)

struct ReceivedBundle: Codable {
    let serverID: String
    let displayName: String
    let bundleData: Data   // encoded APEXPreKeyBundle
}
