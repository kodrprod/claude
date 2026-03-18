// APEXMessage.swift
// APEX Protocol — Wire Message Format
//
// APEX messages have a layered structure:
//
//   ┌─────────────────────────────────────────────────────────────┐
//   │  APEX Envelope (outer, sent to server)                      │
//   │  ┌───────────────────────────────────────────────────────┐  │
//   │  │  Sealed Sender Container                              │  │
//   │  │  ┌─────────────────────────────────────────────────┐  │  │
//   │  │  │  Inner Envelope (authenticated sender identity) │  │  │
//   │  │  │  ┌─────────────────────────────────────────┐   │  │  │
//   │  │  │  │  APEX Data Message (actual content)     │   │  │  │
//   │  │  │  │  Encrypted with Double Ratchet          │   │  │  │
//   │  │  │  └─────────────────────────────────────────┘   │  │  │
//   │  │  └─────────────────────────────────────────────────┘  │  │
//   │  └───────────────────────────────────────────────────────┘  │
//   └─────────────────────────────────────────────────────────────┘
//
// Message types:
//   0x01 - PreKey message (first message in session, contains X3DH data)
//   0x02 - Normal message (ongoing Double Ratchet message)
//   0x03 - Key exchange ack (Bob's first response, triggers full ratchet)
//   0x04 - Control message (key rotation, delivery receipts, etc.)
//   0x05 - Group sender-key message
//
// APEX novel feature: Priority Metadata
//   Optional encrypted metadata allows the client to communicate delivery
//   priority (normal/high/silent) to the server without revealing content.
//   The metadata is encrypted with a separate key derived from the session.

import Foundation
import CryptoKit

// MARK: - Message Type

public enum APEXMessageType: UInt8, Codable {
    case preKey   = 0x01
    case normal   = 0x02
    case ack      = 0x03
    case control  = 0x04
    case group    = 0x05
}

// MARK: - APEX Data Message (innermost layer)

/// The actual message content, encrypted by the Double Ratchet.
/// This is what the Double Ratchet encrypts — everything else is outer framing.
public struct APEXDataMessage: Codable, Sendable {
    /// Plaintext body (text, binary, etc.)
    public var body: Data
    /// Content type hint (MIME-like): "text/plain", "image/jpeg", etc.
    public var contentType: String
    /// Optional reply-to message ID (for threading)
    public var replyToID: String?
    /// Client-side timestamp (epoch milliseconds)
    public var timestamp: Int64
    /// Unique message ID (UUID, client-generated)
    public var messageID: String
    /// Optional expiry interval in seconds (for disappearing messages)
    public var expiresInSeconds: UInt32?

    public init(
        body: Data,
        contentType: String = "text/plain",
        replyToID: String? = nil,
        expiresInSeconds: UInt32? = nil
    ) {
        self.body = body
        self.contentType = contentType
        self.replyToID = replyToID
        self.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        self.messageID = UUID().uuidString
        self.expiresInSeconds = expiresInSeconds
    }
}

// MARK: - APEX Encrypted Message (Double Ratchet layer output)

/// The ratchet-encrypted payload sent between peers.
public struct APEXEncryptedMessage: Codable, Sendable {
    /// Protocol version for forward compatibility
    public let version: UInt8
    /// Ratchet header (DH public key, chain indices)
    public let ratchetHeader: APEXRatchetHeader
    /// AES-256-GCM ciphertext ‖ tag (16 bytes) of the serialized APEXDataMessage
    public let ciphertext: Data
    /// Message type
    public let messageType: APEXMessageType

    public init(
        ratchetHeader: APEXRatchetHeader,
        ciphertext: Data,
        messageType: APEXMessageType = .normal
    ) {
        self.version = APEXConstants.protocolVersion
        self.ratchetHeader = ratchetHeader
        self.ciphertext = ciphertext
        self.messageType = messageType
    }
}

// MARK: - APEX PreKey Message (session initiation)

/// Sent by Alice to Bob to establish a new session (wraps the first encrypted message).
/// Contains all data Bob needs to perform X3DH and decrypt the first message.
public struct APEXPreKeyMessage: Codable, Sendable {
    public let version: UInt8

    // Alice's X3DH material
    public let senderIdentityKey: Data         // IK_A (32 bytes)
    public let senderEphemeralKey: Data        // EK_A (32 bytes)
    public let usedSignedPreKeyID: UInt32
    public let usedOneTimePreKeyID: UInt32?

    // PQ encapsulation data (optional)
    public let pqCiphertext: Data?
    public let usedPQPreKeyID: UInt32?

    // The first Double Ratchet encrypted message
    public let encryptedMessage: APEXEncryptedMessage

    // Alice's registration ID (for Bob to identify the sending device)
    public let senderRegistrationID: UInt16

    public init(
        senderIdentityKey: Data,
        senderEphemeralKey: Data,
        usedSignedPreKeyID: UInt32,
        usedOneTimePreKeyID: UInt32?,
        pqCiphertext: Data?,
        usedPQPreKeyID: UInt32?,
        encryptedMessage: APEXEncryptedMessage,
        senderRegistrationID: UInt16
    ) {
        self.version = APEXConstants.protocolVersion
        self.senderIdentityKey = senderIdentityKey
        self.senderEphemeralKey = senderEphemeralKey
        self.usedSignedPreKeyID = usedSignedPreKeyID
        self.usedOneTimePreKeyID = usedOneTimePreKeyID
        self.pqCiphertext = pqCiphertext
        self.usedPQPreKeyID = usedPQPreKeyID
        self.encryptedMessage = encryptedMessage
        self.senderRegistrationID = senderRegistrationID
    }
}

// MARK: - APEX Envelope (outer transport layer)

/// The outermost envelope delivered via the server.
/// Contains the sealed sender ciphertext (hiding sender identity from server).
public struct APEXEnvelope: Codable, Sendable {
    public let version: UInt8
    /// Sealed sender ciphertext — decrypted by recipient to reveal actual message
    public let sealedContent: Data
    /// Server-assigned recipient identifier (e.g. UUID or phone hash)
    public let recipientID: String
    /// Server timestamp (added by server, not trusted for content authenticity)
    public let serverTimestamp: Int64?
    /// Optional encrypted delivery priority (0=normal, 1=high, 2=silent)
    /// Encrypted with priority-specific key so server can route without reading
    public let encryptedPriority: Data?
    /// APEX message type (for routing, not content-sensitive)
    public let envelopeType: APEXMessageType

    public init(
        sealedContent: Data,
        recipientID: String,
        envelopeType: APEXMessageType,
        encryptedPriority: Data? = nil
    ) {
        self.version = APEXConstants.protocolVersion
        self.sealedContent = sealedContent
        self.recipientID = recipientID
        self.serverTimestamp = nil
        self.encryptedPriority = encryptedPriority
        self.envelopeType = envelopeType
    }
}

// MARK: - Serialization Helpers

extension APEXRatchetHeader: Codable {
    enum CodingKeys: String, CodingKey {
        case dhPublicKey, previousChainLength, messageIndex
    }
}

/// Serialize a Codable value to MessagePack-compatible binary via JSON (portable fallback).
/// In production, replace with a proper binary codec (e.g. protobuf or MessagePack).
public func apexEncode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(value)
}

public func apexDecode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    return try decoder.decode(type, from: data)
}
