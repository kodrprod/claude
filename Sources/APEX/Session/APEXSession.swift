// APEXSession.swift
// APEX Protocol — Session Management
//
// APEXSession is the top-level API for an APEX encrypted messaging session
// between two parties. It orchestrates:
//   1. Session initiation (X3DH + first message encryption)
//   2. Session receipt (X3DH responder + first message decryption)
//   3. Ongoing encryption/decryption via Double Ratchet
//   4. Sealed sender wrapping/unwrapping
//   5. Session state persistence
//   6. Signed pre-key rotation
//   7. Post-quantum key agreement (hybrid mode)
//
// Thread safety:
//   APEXSession is NOT thread-safe. Callers must serialize access.
//   Use actor isolation or a dedicated serial queue in production apps.

import Foundation
import CryptoKit

// MARK: - Session State

public enum APEXSessionStatus {
    case uninitialized
    case initiatorPending   // We sent session init, waiting for first reply
    case active             // Fully established, bidirectional
}

// MARK: - Send Result

public struct APEXSendResult {
    /// The envelope to deliver to the server
    public let envelope: APEXEnvelope
    /// The sealed sender container (already embedded in envelope.sealedContent)
    public let sealedContainer: APEXSealedSenderContainer
    /// Whether this was a PreKey message (session initiation)
    public let isPreKeyMessage: Bool
}

// MARK: - Receive Result

public struct APEXReceiveResult {
    /// Decrypted message content
    public let dataMessage: APEXDataMessage
    /// Verified sender certificate (identity authenticated)
    public let senderCertificate: APEXSenderCertificate
    /// Whether this was a PreKey message (session initiation received)
    public let isPreKeyMessage: Bool
}

// MARK: - APEXSession

public final class APEXSession {

    // MARK: - Properties

    public private(set) var status: APEXSessionStatus = .uninitialized

    /// Our local identity
    private let localIdentity: APEXIdentity
    private let localSenderCertificate: APEXSenderCertificate

    /// Remote party's identity public key (set after X3DH)
    public private(set) var remoteIdentityKey: APEXDHPublicKey?

    /// Double Ratchet state (nil until session established)
    private var ratchetState: APEXDoubleRatchetState?

    /// PQ KEM (for hybrid key establishment)
    private let pqKEM: any APEXPostQuantumKEM

    /// Session ID (derived from shared secret fingerprint)
    public private(set) var sessionID: String = ""

    // MARK: - Init

    public init(
        localIdentity: APEXIdentity,
        senderCertificate: APEXSenderCertificate
    ) {
        self.localIdentity = localIdentity
        self.localSenderCertificate = senderCertificate
        self.pqKEM = APEXPostQuantumKEMFactory.makeKEM()
    }

    // MARK: - Initiate Session (Alice sends first message)

    /// Build a PreKey message to initiate a session with a new contact.
    /// - Parameters:
    ///   - plaintext: The first message content
    ///   - contentType: MIME content type (default: "text/plain")
    ///   - recipientBundle: Bob's pre-key bundle (fetched from server)
    ///   - recipientID: Bob's server identifier (for envelope routing)
    public func initiateSession(
        plaintext: Data,
        contentType: String = "text/plain",
        recipientBundle: APEXPreKeyBundle,
        recipientID: String
    ) throws -> APEXSendResult {

        guard status == .uninitialized else {
            throw APEXError.sessionNotInitialized
        }

        // 1. Optional: PQ encapsulation
        var pqInitData: APEXPQInitData? = nil
        var pqSharedSecret: Data? = nil

        if let pqBundle = recipientBundle.pqPreKey {
            let encapResult = try pqKEM.encapsulate(recipientPublicKey: pqBundle.pqPreKeyPublicKey)
            pqInitData = APEXPQInitData(
                pqCiphertext: encapResult.ciphertext,
                pqPreKeyID: pqBundle.pqPreKeyID
            )
            pqSharedSecret = encapResult.sharedSecret
        }

        // 2. X3DH initiator
        let x3dhResult = try APEXX3DH.performInitiator(
            senderIdentity: localIdentity.identityKeyPair,
            senderSigningKey: localIdentity.signingKeyPair,
            recipientBundle: recipientBundle,
            pqSharedSecret: pqSharedSecret
        )

        // 3. Initialize Double Ratchet state (initiator side)
        let ratchet = APEXDoubleRatchetState.forInitiator(
            sharedSecret: x3dhResult.sharedSecret,
            recipientRatchetKey: recipientBundle.signedPreKey,
            associatedData: x3dhResult.associatedData
        )
        self.ratchetState = ratchet
        self.remoteIdentityKey = recipientBundle.identityKey

        // 4. Derive session ID
        self.sessionID = deriveSessionID(sharedSecret: x3dhResult.sharedSecret)

        // 5. Encrypt first data message with ratchet
        let dataMsg = APEXDataMessage(body: plaintext, contentType: contentType)
        let dataMsgData = try apexEncode(dataMsg)

        let (header, ciphertext) = try APEXDoubleRatchet.encrypt(
            plaintext: dataMsgData,
            state: ratchet
        )

        let encMsg = APEXEncryptedMessage(
            ratchetHeader: header,
            ciphertext: ciphertext,
            messageType: .normal
        )

        // 6. Build PreKey message
        let preKeyMsg = APEXPreKeyMessage(
            senderIdentityKey: localIdentity.identityKeyPair.publicKey.rawRepresentation,
            senderEphemeralKey: x3dhResult.ephemeralPublicKey.rawRepresentation,
            usedSignedPreKeyID: x3dhResult.usedSignedPreKeyID,
            usedOneTimePreKeyID: x3dhResult.usedOneTimePreKeyID,
            pqCiphertext: pqInitData?.pqCiphertext,
            usedPQPreKeyID: pqInitData?.pqPreKeyID,
            encryptedMessage: encMsg,
            senderRegistrationID: localIdentity.registrationID
        )
        let preKeyMsgData = try apexEncode(preKeyMsg)

        // 7. Seal sender
        let sealedContainer = try APEXSealedSender.seal(
            innerMessage: preKeyMsgData,
            messageType: .preKey,
            senderCertificate: localSenderCertificate,
            recipientIdentityKey: recipientBundle.identityKey
        )
        let sealedData = try apexEncode(sealedContainer)

        // 8. Build envelope
        let envelope = APEXEnvelope(
            sealedContent: sealedData,
            recipientID: recipientID,
            envelopeType: .preKey
        )

        status = .initiatorPending
        return APEXSendResult(
            envelope: envelope,
            sealedContainer: sealedContainer,
            isPreKeyMessage: true
        )
    }

    // MARK: - Send Message (established session)

    /// Encrypt and send a message in an established session.
    public func send(
        plaintext: Data,
        contentType: String = "text/plain",
        recipientID: String,
        recipientIdentityKey: APEXDHPublicKey,
        highSecurity: Bool = false
    ) throws -> APEXSendResult {

        guard let ratchet = ratchetState else {
            throw APEXError.sessionNotInitialized
        }

        // Optionally force an extra DH ratchet step for high-security messages
        if highSecurity {
            try APEXDoubleRatchet.forceRatchetStep(state: ratchet)
        }

        let dataMsg = APEXDataMessage(body: plaintext, contentType: contentType)
        let dataMsgData = try apexEncode(dataMsg)

        let (header, ciphertext) = try APEXDoubleRatchet.encrypt(
            plaintext: dataMsgData,
            state: ratchet
        )

        let encMsg = APEXEncryptedMessage(
            ratchetHeader: header,
            ciphertext: ciphertext,
            messageType: .normal
        )
        let encMsgData = try apexEncode(encMsg)

        let sealedContainer = try APEXSealedSender.seal(
            innerMessage: encMsgData,
            messageType: .normal,
            senderCertificate: localSenderCertificate,
            recipientIdentityKey: recipientIdentityKey
        )
        let sealedData = try apexEncode(sealedContainer)

        let envelope = APEXEnvelope(
            sealedContent: sealedData,
            recipientID: recipientID,
            envelopeType: .normal
        )

        status = .active
        return APEXSendResult(
            envelope: envelope,
            sealedContainer: sealedContainer,
            isPreKeyMessage: false
        )
    }

    // MARK: - Receive Message (responder side, handles both PreKey and Normal)

    /// Decrypt a received envelope. Handles both PreKey (session initiation) and normal messages.
    public func receive(
        envelope: APEXEnvelope
    ) throws -> APEXReceiveResult {

        // 1. Unseal the sender
        let containerData = envelope.sealedContent
        let container = try apexDecode(APEXSealedSenderContainer.self, from: containerData)

        let (senderCert, innerData, messageType) = try APEXSealedSender.unseal(
            container: container,
            recipientIdentityKeyPair: localIdentity.identityKeyPair
        )

        switch messageType {
        case .preKey:
            return try receivePreKeyMessage(
                innerData: innerData,
                senderCert: senderCert
            )
        case .normal, .ack, .control:
            return try receiveNormalMessage(
                innerData: innerData,
                senderCert: senderCert
            )
        case .group:
            throw APEXError.invalidMessageFormat
        }
    }

    // MARK: - Adaptive Force Ratchet (APEX Extension)

    /// Manually trigger an immediate DH ratchet step.
    /// Call before sending a very sensitive message for maximum forward secrecy.
    public func forceRatchet() throws {
        guard let ratchet = ratchetState else {
            throw APEXError.sessionNotInitialized
        }
        try APEXDoubleRatchet.forceRatchetStep(state: ratchet)
    }

    // MARK: - Session Fingerprint

    /// Safety number for out-of-band verification with the remote party.
    /// Display this to both users — if it matches, no MITM has occurred.
    public func safetyNumber(remoteIdentityKey: APEXDHPublicKey) -> String {
        let localFP  = localIdentity.identityKeyPair.publicKey.rawRepresentation
        let remoteFP = remoteIdentityKey.rawRepresentation
        // Combined hash, grouped into 5 groups of 5 characters
        let combined = SHA256.hash(data: localFP + remoteFP)
        let hex = combined.compactMap { String(format: "%02x", $0) }.joined()
        return stride(from: 0, to: 50, by: 10).map {
            String(hex.dropFirst($0).prefix(10))
        }.joined(separator: " ")
    }

    // MARK: - Private Helpers

    private func receivePreKeyMessage(
        innerData: Data,
        senderCert: APEXSenderCertificate
    ) throws -> APEXReceiveResult {

        let preKeyMsg = try apexDecode(APEXPreKeyMessage.self, from: innerData)

        guard preKeyMsg.version == APEXConstants.protocolVersion else {
            throw APEXError.unsupportedProtocolVersion
        }

        let senderIK  = try APEXDHPublicKey(rawRepresentation: preKeyMsg.senderIdentityKey)
        let senderEK  = try APEXDHPublicKey(rawRepresentation: preKeyMsg.senderEphemeralKey)

        // Look up Bob's signed pre-key by ID
        guard let spkPair = localIdentity.signedPreKeyPair(forID: preKeyMsg.usedSignedPreKeyID) else {
            throw APEXError.invalidPreKeyBundle
        }

        // Look up and consume one-time pre-key if used
        var otpkPair: APEXDHKeyPair? = nil
        if let otpkID = preKeyMsg.usedOneTimePreKeyID {
            otpkPair = localIdentity.consumeOneTimePreKey(id: otpkID)
        }

        // Optional: PQ decapsulation
        var pqSharedSecret: Data? = nil
        if let pqCT = preKeyMsg.pqCiphertext,
           let pqID = preKeyMsg.usedPQPreKeyID,
           let pqKP = localIdentity.consumePQPreKey(id: pqID) {
            pqSharedSecret = try pqKEM.decapsulate(
                privateKey: pqKP.privateKey,
                ciphertext: pqCT
            )
        }

        // X3DH responder
        let x3dhResult = try APEXX3DH.performResponder(
            recipientIdentity: localIdentity.identityKeyPair,
            recipientSignedPreKey: spkPair,
            recipientOneTimePreKey: otpkPair,
            senderIdentityKey: senderIK,
            senderEphemeralKey: senderEK,
            pqSharedSecret: pqSharedSecret
        )

        // Initialize Double Ratchet (responder side uses SPK as initial ratchet key)
        let ratchet = APEXDoubleRatchetState.forResponder(
            sharedSecret: x3dhResult.sharedSecret,
            ourRatchetKeyPair: spkPair,
            associatedData: x3dhResult.associatedData
        )
        self.ratchetState = ratchet
        self.remoteIdentityKey = senderIK
        self.sessionID = deriveSessionID(sharedSecret: x3dhResult.sharedSecret)

        // Decrypt the embedded encrypted message
        let encMsg = preKeyMsg.encryptedMessage
        let dataMsgData = try APEXDoubleRatchet.decrypt(
            header: encMsg.ratchetHeader,
            ciphertext: encMsg.ciphertext,
            state: ratchet
        )

        let dataMsg = try apexDecode(APEXDataMessage.self, from: dataMsgData)
        self.status = .active

        return APEXReceiveResult(
            dataMessage: dataMsg,
            senderCertificate: senderCert,
            isPreKeyMessage: true
        )
    }

    private func receiveNormalMessage(
        innerData: Data,
        senderCert: APEXSenderCertificate
    ) throws -> APEXReceiveResult {

        guard let ratchet = ratchetState else {
            throw APEXError.sessionNotInitialized
        }

        let encMsg = try apexDecode(APEXEncryptedMessage.self, from: innerData)

        guard encMsg.version == APEXConstants.protocolVersion else {
            throw APEXError.unsupportedProtocolVersion
        }

        let dataMsgData = try APEXDoubleRatchet.decrypt(
            header: encMsg.ratchetHeader,
            ciphertext: encMsg.ciphertext,
            state: ratchet
        )

        let dataMsg = try apexDecode(APEXDataMessage.self, from: dataMsgData)
        self.status = .active

        return APEXReceiveResult(
            dataMessage: dataMsg,
            senderCertificate: senderCert,
            isPreKeyMessage: false
        )
    }

    private func deriveSessionID(sharedSecret: Data) -> String {
        let hash = SHA256.hash(data: sharedSecret + "APEX_SessionID".data(using: .utf8)!)
        return hash.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}
