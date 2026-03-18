// APEX.swift
// APEX Protocol — Adaptive Privacy Exchange Protocol
//
// ╔═══════════════════════════════════════════════════════════════════╗
// ║              APEX: Adaptive Privacy Exchange Protocol             ║
// ║                          Version 1.0                             ║
// ╠═══════════════════════════════════════════════════════════════════╣
// ║  Security Properties:                                             ║
// ║  ✓ End-to-End Encryption    (AES-256-GCM / Double Ratchet)       ║
// ║  ✓ Forward Secrecy          (Double Ratchet symmetric ratchet)    ║
// ║  ✓ Break-in Recovery        (Double Ratchet DH ratchet)          ║
// ║  ✓ Mutual Authentication    (X3DH + Ed25519 signing)             ║
// ║  ✓ Deniability              (No long-term commitment to content)  ║
// ║  ✓ Post-Quantum Hybrid      (X25519 + ML-KEM-768)                ║
// ║  ✓ Metadata Protection      (Sealed Sender / server blindness)   ║
// ║  ✓ Adaptive Ratchet         (Force extra DH step on demand)      ║
// ║  ✓ Secure Enclave Support   (Hardware-backed identity keys)       ║
// ║  ✓ Key Transparency Ready   (Fingerprints for out-of-band verify) ║
// ╚═══════════════════════════════════════════════════════════════════╝
//
// Cryptographic Primitives:
//   Key Exchange:    X25519 (Curve25519 DH) + ML-KEM-768 (FIPS 203)
//   Signatures:      Ed25519 (Curve25519 signing)
//   Symmetric Enc:   AES-256-GCM (AEAD)
//   Hash / KDF:      SHA-512, HKDF-SHA-512
//   MAC:             HMAC-SHA-512
//   Key Storage:     Apple Keychain + Secure Enclave
//
// Platform support:
//   iOS 16+, macOS 13+, watchOS 9+, tvOS 16+, visionOS 1+
//   Post-quantum layer requires: iOS 17+, macOS 14+
//
// Quick Start:
//   // 1. Create identity (Alice, one-time setup)
//   let alice = try APEX.createIdentity()
//   let aliceCert = try APEX.createSenderCertificate(identity: alice, serverID: "alice@example.com")
//
//   // 2. Fetch Bob's pre-key bundle from server
//   let bobBundle: APEXPreKeyBundle = ... // from your server API
//
//   // 3. Create session and send first message
//   let session = APEX.createSession(identity: alice, certificate: aliceCert)
//   let result = try session.initiateSession(
//       plaintext: "Hello Bob!".data(using: .utf8)!,
//       recipientBundle: bobBundle,
//       recipientID: "bob@example.com"
//   )
//   // Send result.envelope to your server
//
//   // 4. Bob receives and decrypts
//   let bobSession = APEX.createSession(identity: bob, certificate: bobCert)
//   let received = try bobSession.receive(envelope: envelope)
//   print(String(data: received.dataMessage.body, encoding: .utf8)!) // "Hello Bob!"

import Foundation
import CryptoKit

// MARK: - APEX Namespace

/// Primary namespace for the APEX E2E encryption protocol.
/// All public API is accessed through this enum.
public enum APEX {

    // MARK: - Protocol Info

    public static let version     = "1.0.0"
    public static let protocolID  = "APEX/1"

    /// Whether post-quantum (ML-KEM-768) is available on this device/OS
    public static var isPostQuantumAvailable: Bool {
        APEXPostQuantumKEMFactory.isPostQuantumAvailable
    }

    /// Whether Secure Enclave is available for hardware-backed key storage
    public static var isSecureEnclaveAvailable: Bool {
        APEXKeychain.isSecureEnclaveAvailable
    }

    // MARK: - Identity Management

    /// Create a new APEX identity (first launch / registration).
    /// Generates all required key material (IK, SPK, OTPKs, PQ keys).
    public static func createIdentity() throws -> APEXIdentity {
        return try APEXIdentity()
    }

    // MARK: - Sender Certificate

    /// Create a sender certificate for use in sealed sender messages.
    /// In production: the server signs these after authenticating the user.
    /// For testing: self-signed by the identity's own signing key.
    public static func createSenderCertificate(
        identity: APEXIdentity,
        serverID: String,
        validitySeconds: Int64 = 86400
    ) throws -> APEXSenderCertificate {
        return try APEXSenderCertificate(
            senderIdentityKey: identity.identityKeyPair.publicKey.rawRepresentation,
            senderRegistrationID: identity.registrationID,
            senderServerID: serverID,
            validitySeconds: validitySeconds,
            signingKey: identity.signingKeyPair
        )
    }

    // MARK: - Session Factory

    /// Create a new APEX session for communicating with a peer.
    public static func createSession(
        identity: APEXIdentity,
        certificate: APEXSenderCertificate
    ) -> APEXSession {
        return APEXSession(
            localIdentity: identity,
            senderCertificate: certificate
        )
    }

    // MARK: - Pre-Key Bundle

    /// Extract the public pre-key bundle from an identity (for upload to server).
    public static func makePublicBundle(
        from identity: APEXIdentity,
        includeOneTimePK: Bool = true
    ) -> APEXPreKeyBundle {
        return identity.makePreKeyBundle(includeOneTimePK: includeOneTimePK)
    }

    /// Encode a pre-key bundle to JSON bytes for server upload.
    public static func encodeBundle(_ bundle: APEXPreKeyBundle) throws -> Data {
        let encoded = APEXPreKeyBundleEncoded(
            identityKey: bundle.identityKey.rawRepresentation,
            identitySigningKey: bundle.identitySigningKey.rawRepresentation,
            signedPreKeyID: bundle.signedPreKeyID,
            signedPreKey: bundle.signedPreKey.rawRepresentation,
            signedPreKeySignature: bundle.signedPreKeySignature,
            oneTimePreKeyID: bundle.oneTimePreKeyID,
            oneTimePreKey: bundle.oneTimePreKey?.rawRepresentation,
            pqPreKeyPublicKey: bundle.pqPreKey?.pqPreKeyPublicKey,
            pqPreKeyID: bundle.pqPreKey?.pqPreKeyID
        )
        return try apexEncode(encoded)
    }

    /// Decode a pre-key bundle received from the server.
    public static func decodeBundle(from data: Data) throws -> APEXPreKeyBundle {
        let encoded = try apexDecode(APEXPreKeyBundleEncoded.self, from: data)
        return try encoded.decoded()
    }

    // MARK: - Safety Number / Key Transparency

    /// Compute the combined safety number between two identity keys.
    /// Display this to users for out-of-band verification (scan each other's
    /// safety numbers to confirm no man-in-the-middle attack is occurring).
    public static func safetyNumber(
        localIdentityKey: APEXDHPublicKey,
        remoteIdentityKey: APEXDHPublicKey
    ) -> String {
        // Lexicographically sort keys so A↔B == B↔A
        let local  = localIdentityKey.rawRepresentation
        let remote = remoteIdentityKey.rawRepresentation

        let (first, second) = local.lexicographicallyPrecedes(remote)
            ? (local, remote)
            : (remote, local)

        let combined = SHA256.hash(data: first + second)
        let digits = combined.withUnsafeBytes { bytes -> [UInt8] in Array(bytes) }

        // 60 digits in groups of 5 → "12345 67890 ..."
        var result = ""
        var pos = 0
        for byte in digits.prefix(30) {
            let lo = byte & 0x0F
            let hi = (byte >> 4) & 0x0F
            result += "\(hi)\(lo)"
            pos += 2
            if pos % 5 == 0 { result += " " }
        }

        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Envelope Encoding

    /// Encode an envelope to wire bytes for delivery to server.
    public static func encodeEnvelope(_ envelope: APEXEnvelope) throws -> Data {
        return try apexEncode(envelope)
    }

    /// Decode an envelope received from server.
    public static func decodeEnvelope(from data: Data) throws -> APEXEnvelope {
        return try apexDecode(APEXEnvelope.self, from: data)
    }

    // MARK: - Utility

    /// Generate a batch of one-time pre-key public keys for server upload.
    public static func generateOneTimePreKeyPublicKeys(
        from identity: APEXIdentity
    ) -> [(id: UInt32, publicKeyData: Data)] {
        return identity.publicOneTimePreKeys
    }
}

// MARK: - APEX Configuration

/// Runtime configuration for APEX protocol behavior
public struct APEXConfiguration {
    /// Enable post-quantum hybrid KEM (requires iOS 17+ / macOS 14+)
    public var enablePostQuantum: Bool = APEXPostQuantumKEMFactory.isPostQuantumAvailable

    /// Enable adaptive ratchet for all messages (maximum forward secrecy, higher CPU)
    public var alwaysForceRatchet: Bool = false

    /// Enable sealed sender (hide sender identity from server)
    public var enableSealedSender: Bool = true

    /// Signed pre-key rotation interval (default: 7 days)
    public var signedPreKeyRotationInterval: TimeInterval = 7 * 24 * 3600

    /// One-time pre-key replenishment threshold (replenish when below this count)
    public var oneTimePreKeyReplenishThreshold: Int = 20

    public init() {}

    /// Recommended high-security configuration
    public static var highSecurity: APEXConfiguration {
        var c = APEXConfiguration()
        c.enablePostQuantum = APEXPostQuantumKEMFactory.isPostQuantumAvailable
        c.alwaysForceRatchet = true
        c.enableSealedSender = true
        c.signedPreKeyRotationInterval = 24 * 3600  // Daily rotation
        return c
    }

    /// Recommended balanced configuration (recommended default)
    public static var balanced: APEXConfiguration {
        APEXConfiguration()
    }
}
