// APEXPostQuantum.swift
// APEX Protocol — Post-Quantum Hybrid KEM Layer
//
// APEX implements a hybrid post-quantum key encapsulation mechanism (KEM)
// that combines classical X25519 with ML-KEM-768 (FIPS 203 / CRYSTALS-Kyber).
//
// Security model: HYBRID. The combined secret is secure if EITHER:
//   - Classical X25519 is secure (against classical computers), OR
//   - ML-KEM-768 is secure (against quantum computers)
//
// This matches Apple's PQ3 protocol for iMessage and Signal's PQXDH approach.
//
// Availability:
//   - Classical X25519 DH: All supported platforms
//   - ML-KEM-768 via CryptoKit: Available on newer platforms (iOS 17+, macOS 14+)
//   - Fallback: Classical-only mode when PQ primitives are unavailable
//
// The PQ layer operates at session establishment (X3DH), not per-message.
// The Double Ratchet's forward secrecy protects messages after key establishment.

import Foundation
import CryptoKit

// MARK: - PQ Capability Detection

public enum APEXPQCapability {
    /// Full post-quantum hybrid support
    case hybridPQ
    /// Classical-only (PQ primitives not available on this platform)
    case classicalOnly

    /// Detect PQ capability at runtime
    public static var current: APEXPQCapability {
        if #available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *) {
            return .hybridPQ
        }
        return .classicalOnly
    }
}

// MARK: - PQ KEM Protocol Abstraction

/// Abstract interface for post-quantum KEM operations.
/// Concrete implementation uses ML-KEM-768 when available.
public protocol APEXPostQuantumKEM {
    /// Generate a KEM key pair
    func generateKeyPair() throws -> APEXPQKeyPair

    /// Encapsulate: given a recipient's PQ public key, produce a ciphertext + shared secret
    func encapsulate(recipientPublicKey: Data) throws -> APEXPQEncapsulationResult

    /// Decapsulate: given our private key and a ciphertext, recover the shared secret
    func decapsulate(privateKey: Data, ciphertext: Data) throws -> Data

    /// Public key size in bytes
    var publicKeySize: Int { get }

    /// Ciphertext size in bytes
    var ciphertextSize: Int { get }

    /// Shared secret size in bytes
    var sharedSecretSize: Int { get }
}

// MARK: - PQ Key Types

public struct APEXPQKeyPair: Sendable {
    public let publicKey: Data
    public let privateKey: Data

    public init(publicKey: Data, privateKey: Data) {
        self.publicKey = publicKey
        self.privateKey = privateKey
    }
}

public struct APEXPQEncapsulationResult: Sendable {
    /// The ciphertext to send to the recipient
    public let ciphertext: Data
    /// The shared secret (local only, never transmitted)
    public let sharedSecret: Data

    public init(ciphertext: Data, sharedSecret: Data) {
        self.ciphertext = ciphertext
        self.sharedSecret = sharedSecret
    }
}

// MARK: - ML-KEM-768 Implementation

/// ML-KEM-768 KEM (FIPS 203), available on iOS 17+ / macOS 14+.
/// Parameters: ML-KEM-768 provides 128-bit post-quantum security level.
///   Public key:  1184 bytes
///   Private key: 2400 bytes
///   Ciphertext:  1088 bytes
///   Shared secret: 32 bytes
@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *)
public struct APEXMLKEM768: APEXPostQuantumKEM {

    public init() {}

    public var publicKeySize:    Int { 1184 }
    public var ciphertextSize:   Int { 1088 }
    public var sharedSecretSize: Int { 32 }

    public func generateKeyPair() throws -> APEXPQKeyPair {
        // ML-KEM-768 key generation via CryptoKit
        // Note: CryptoKit exposes ML-KEM-768 as MLKem768 on supported platforms.
        // Using conditional compilation for precise platform targeting.
        let keyPair = try MLKem768.KeyAgreement.PrivateKey()
        let privBytes = keyPair.rawRepresentation
        let pubBytes  = keyPair.publicKey.rawRepresentation
        return APEXPQKeyPair(publicKey: pubBytes, privateKey: privBytes)
    }

    public func encapsulate(recipientPublicKey: Data) throws -> APEXPQEncapsulationResult {
        let recipientPubKey = try MLKem768.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey)
        let (sharedSecret, ciphertext) = try recipientPubKey.encapsulate()
        return APEXPQEncapsulationResult(
            ciphertext: ciphertext,
            sharedSecret: sharedSecret.withUnsafeBytes { Data($0) }
        )
    }

    public func decapsulate(privateKey: Data, ciphertext: Data) throws -> Data {
        let privKey = try MLKem768.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        let sharedSecret = try privKey.decapsulate(ciphertext)
        return sharedSecret.withUnsafeBytes { Data($0) }
    }
}

// MARK: - Simulation KEM (Classical Fallback)

/// Deterministic simulation KEM for platforms without ML-KEM-768.
/// Uses X25519 ECDH to simulate KEM semantics — NOT post-quantum secure,
/// but allows the same API surface and protocol structure across all platforms.
/// Real security relies on the classical X25519 layer in this mode.
public struct APEXSimulatedKEM: APEXPostQuantumKEM {

    public init() {}

    public var publicKeySize:    Int { 32 }
    public var ciphertextSize:   Int { 32 }
    public var sharedSecretSize: Int { 32 }

    public func generateKeyPair() throws -> APEXPQKeyPair {
        let kp = APEXDHKeyPair()
        return APEXPQKeyPair(
            publicKey: kp.publicKey.rawRepresentation,
            privateKey: kp.privateKey.rawRepresentation
        )
    }

    public func encapsulate(recipientPublicKey: Data) throws -> APEXPQEncapsulationResult {
        let ephemeral = APEXDHKeyPair()
        let recipientPK = try APEXDHPublicKey(rawRepresentation: recipientPublicKey)
        let ss = try ephemeral.privateKey
            .sharedSecretFromKeyAgreement(with: recipientPK)
            .withUnsafeBytes { Data($0) }
        return APEXPQEncapsulationResult(
            ciphertext: ephemeral.publicKey.rawRepresentation,
            sharedSecret: ss
        )
    }

    public func decapsulate(privateKey: Data, ciphertext: Data) throws -> Data {
        let privKey = try APEXDHPrivateKey(rawRepresentation: privateKey)
        let ephemeralPK = try APEXDHPublicKey(rawRepresentation: ciphertext)
        return try privKey
            .sharedSecretFromKeyAgreement(with: ephemeralPK)
            .withUnsafeBytes { Data($0) }
    }
}

// MARK: - PQ KEM Factory

public enum APEXPostQuantumKEMFactory {
    /// Return the best available KEM implementation for this platform
    public static func makeKEM() -> any APEXPostQuantumKEM {
        if #available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *) {
            return APEXMLKEM768()
        }
        return APEXSimulatedKEM()
    }

    /// True if real ML-KEM-768 is available (not the simulation fallback)
    public static var isPostQuantumAvailable: Bool {
        if #available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *) {
            return true
        }
        return false
    }
}

// MARK: - APEX PQ Pre-Key Bundle Extension

/// Post-quantum public keys added to the pre-key bundle for PQ-enabled session establishment.
public struct APEXPQPreKeyBundle {
    /// ML-KEM-768 public key for the signed pre-key (1184 bytes when real PQ, 32 bytes fallback)
    public let pqPreKeyPublicKey: Data
    public let pqPreKeyID: UInt32

    public init(pqPreKeyPublicKey: Data, pqPreKeyID: UInt32) {
        self.pqPreKeyPublicKey = pqPreKeyPublicKey
        self.pqPreKeyID = pqPreKeyID
    }
}

// MARK: - APEX PQ Session Init Data (sent in initial message)

/// Post-quantum ciphertext included in the session initiation message.
/// Bob uses his PQ private key to decapsulate and recover the PQ shared secret.
public struct APEXPQInitData {
    /// The ML-KEM-768 ciphertext (1088 bytes when real PQ, 32 bytes fallback)
    public let pqCiphertext: Data
    /// Which PQ pre-key ID was used
    public let pqPreKeyID: UInt32

    public init(pqCiphertext: Data, pqPreKeyID: UInt32) {
        self.pqCiphertext = pqCiphertext
        self.pqPreKeyID = pqPreKeyID
    }
}
