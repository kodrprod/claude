// APEXSealedSender.swift
// APEX Protocol — Sealed Sender (Metadata Protection)
//
// Sealed Sender hides the sender's identity from the delivery server.
// The server knows WHO the message is for (recipient), but NOT who sent it.
//
// How it works:
//   1. Sender generates an ephemeral X25519 key pair (EK_S)
//   2. Sender computes: SS = X25519(EK_S_priv, IK_R_pub)
//              where IK_R is the recipient's long-term identity public key
//   3. Derives a sealing key: SK_seal = HKDF(SS)
//   4. Encrypts a "SenderCertificate" (sender's IK + registration ID) with SK_seal
//   5. Packages: EK_S_pub ‖ Enc(SK_seal, SenderCert ‖ actual message)
//
// The recipient:
//   1. Receives EK_S_pub from the envelope
//   2. Computes: SS = X25519(IK_R_priv, EK_S_pub)
//   3. Derives SK_seal = HKDF(SS)
//   4. Decrypts to get SenderCert + actual message
//   5. Verifies SenderCert (optional trust-on-first-use or trust-on-verify)
//
// APEX enhancement: "Group Anonymity Mode"
//   Multiple senders can contribute decoy sealed-sender traffic,
//   making traffic analysis harder (sender set ambiguity).

import Foundation
import CryptoKit

// MARK: - Sender Certificate

/// Authenticates the sender's identity within the sealed envelope.
/// Signed by the sender's long-term signing key.
public struct APEXSenderCertificate: Codable, Sendable {
    /// Sender's identity public key (DH)
    public let senderIdentityKey: Data
    /// Sender's registration ID
    public let senderRegistrationID: UInt16
    /// Certificate expiry (UTC epoch seconds)
    public let expiresAt: Int64
    /// Server-issued sender identifier (opaque, e.g. UUID hash)
    public let senderServerID: String
    /// Ed25519 signature over the above fields
    public let signature: Data

    public init(
        senderIdentityKey: Data,
        senderRegistrationID: UInt16,
        senderServerID: String,
        validitySeconds: Int64 = 86400,
        signingKey: APEXSigningKeyPair
    ) throws {
        self.senderIdentityKey = senderIdentityKey
        self.senderRegistrationID = senderRegistrationID
        self.senderServerID = senderServerID
        self.expiresAt = Int64(Date().timeIntervalSince1970) + validitySeconds

        // Sign: identityKey ‖ registrationID (2B BE) ‖ expiresAt (8B BE) ‖ serverID
        var message = senderIdentityKey
        var regID = senderRegistrationID.bigEndian
        message += Data(bytes: &regID, count: 2)
        var expiry = self.expiresAt.bigEndian
        message += Data(bytes: &expiry, count: 8)
        message += senderServerID.data(using: .utf8)!

        self.signature = try signingKey.sign(message)
    }

    /// Verify the certificate's signature against a known sender signing key
    public func verify(against signingPublicKey: APEXSigningPublicKey) -> Bool {
        var message = senderIdentityKey
        var regID = senderRegistrationID.bigEndian
        message += Data(bytes: &regID, count: 2)
        var expiry = expiresAt.bigEndian
        message += Data(bytes: &expiry, count: 8)
        message += senderServerID.data(using: .utf8)!

        return signingPublicKey.isValidSignature(signature, for: message)
    }

    public var isExpired: Bool {
        Int64(Date().timeIntervalSince1970) > expiresAt
    }
}

// MARK: - Sealed Sender Container

/// The wire format for sealed sender delivery.
public struct APEXSealedSenderContainer: Codable, Sendable {
    /// Sender's ephemeral DH public key (32 bytes)
    public let ephemeralPublicKey: Data
    /// AES-GCM ciphertext = Enc(SK_seal, senderCert ‖ "|" ‖ innerMessage)
    public let sealedCiphertext: Data

    public init(ephemeralPublicKey: Data, sealedCiphertext: Data) {
        self.ephemeralPublicKey = ephemeralPublicKey
        self.sealedCiphertext = sealedCiphertext
    }
}

// MARK: - Sealed Sender Inner Payload

/// Plaintext content inside the seal: sender certificate + the actual message bytes.
private struct SealedSenderInner: Codable {
    let senderCertificate: APEXSenderCertificate
    let innerMessageData: Data  // serialized APEXPreKeyMessage or APEXEncryptedMessage
    let messageType: APEXMessageType
}

// MARK: - Sealed Sender Engine

public enum APEXSealedSender {

    // MARK: - Seal (Sender side)

    /// Wrap a message in a sealed sender envelope.
    /// - Parameters:
    ///   - innerMessage: Serialized encrypted message bytes
    ///   - messageType: Type of the inner message
    ///   - senderCertificate: Sender's authenticated certificate
    ///   - recipientIdentityKey: Recipient's long-term DH public key (from their bundle)
    public static func seal(
        innerMessage: Data,
        messageType: APEXMessageType,
        senderCertificate: APEXSenderCertificate,
        recipientIdentityKey: APEXDHPublicKey
    ) throws -> APEXSealedSenderContainer {

        // 1. Generate ephemeral key pair
        let ephemeralPair = APEXDHKeyPair()

        // 2. DH: ephemeral_priv × recipient_identity_pub
        let dhOutput = try ephemeralPair.privateKey
            .sharedSecretFromKeyAgreement(with: recipientIdentityKey)
            .withUnsafeBytes { Data($0) }

        // 3. Derive sealing key
        let sealingKey = APEXKeyDerivation.deriveSealedSenderKey(dhOutput: dhOutput)

        // 4. Serialize inner payload: senderCert ‖ innerMessage
        let inner = SealedSenderInner(
            senderCertificate: senderCertificate,
            innerMessageData: innerMessage,
            messageType: messageType
        )
        let innerData = try apexEncode(inner)

        // 5. AES-GCM encrypt with random nonce
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(innerData, using: sealingKey, nonce: nonce)

        // Wire format: nonce (12B) ‖ ciphertext ‖ tag (16B)
        let noncedCiphertext = Data(nonce) + sealedBox.ciphertext + sealedBox.tag

        return APEXSealedSenderContainer(
            ephemeralPublicKey: ephemeralPair.publicKey.rawRepresentation,
            sealedCiphertext: noncedCiphertext
        )
    }

    // MARK: - Unseal (Recipient side)

    /// Unseal a sealed sender container using our own identity private key.
    /// - Returns: (senderCertificate, innerMessageData, messageType)
    public static func unseal(
        container: APEXSealedSenderContainer,
        recipientIdentityKeyPair: APEXDHKeyPair
    ) throws -> (certificate: APEXSenderCertificate, innerData: Data, messageType: APEXMessageType) {

        // 1. Recover ephemeral public key
        let ephemeralPK = try APEXDHPublicKey(rawRepresentation: container.ephemeralPublicKey)

        // 2. DH: our_identity_priv × sender_ephemeral_pub
        let dhOutput = try recipientIdentityKeyPair.privateKey
            .sharedSecretFromKeyAgreement(with: ephemeralPK)
            .withUnsafeBytes { Data($0) }

        // 3. Derive sealing key
        let sealingKey = APEXKeyDerivation.deriveSealedSenderKey(dhOutput: dhOutput)

        // 4. Decrypt
        let noncedCiphertext = container.sealedCiphertext
        guard noncedCiphertext.count > APEXConstants.nonceSize + APEXConstants.tagSize else {
            throw APEXError.sealedSenderDecryptionFailed
        }

        let nonceData = noncedCiphertext.prefix(APEXConstants.nonceSize)
        let body = noncedCiphertext[APEXConstants.nonceSize..<(noncedCiphertext.count - APEXConstants.tagSize)]
        let tag  = noncedCiphertext.suffix(APEXConstants.tagSize)

        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: body, tag: tag)
        let innerData: Data
        do {
            innerData = try AES.GCM.open(sealedBox, using: sealingKey)
        } catch {
            throw APEXError.sealedSenderDecryptionFailed
        }

        // 5. Deserialize inner payload
        let inner = try apexDecode(SealedSenderInner.self, from: innerData)

        // 6. Validate certificate (not expired)
        guard !inner.senderCertificate.isExpired else {
            throw APEXError.sealedSenderDecryptionFailed
        }

        return (inner.senderCertificate, inner.innerMessageData, inner.messageType)
    }
}
