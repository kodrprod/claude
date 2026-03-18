// APEXKeyTypes.swift
// APEX Protocol — Adaptive Privacy Exchange Protocol
//
// Core key type definitions. All cryptographic keys used throughout
// the APEX protocol are defined and type-aliased here for clarity.
//
// Classical layer: Curve25519 (X25519 DH + Ed25519 signatures)
// Symmetric layer: AES-256-GCM / ChaCha20-Poly1305
// PQ layer: ML-KEM-768 (when available, iOS 17+ / macOS 14+)

import Foundation
import CryptoKit

// MARK: - Type Aliases

/// Long-term DH key for key agreement (X25519)
public typealias APEXDHPublicKey  = Curve25519.KeyAgreement.PublicKey
public typealias APEXDHPrivateKey = Curve25519.KeyAgreement.PrivateKey

/// Ed25519 signing keys for identity authentication
public typealias APEXSigningPublicKey  = Curve25519.Signing.PublicKey
public typealias APEXSigningPrivateKey = Curve25519.Signing.PrivateKey

/// Raw 32-byte symmetric key material
public typealias APEXRootKey    = SymmetricKey  // 256-bit
public typealias APEXChainKey   = Data          // 32 bytes
public typealias APEXMessageKey = SymmetricKey  // 256-bit

// MARK: - Key Pair Wrappers

/// Ephemeral or ratchet DH key pair
public struct APEXDHKeyPair: Sendable {
    public let privateKey: APEXDHPrivateKey
    public let publicKey:  APEXDHPublicKey

    public init() {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        self.privateKey = priv
        self.publicKey  = priv.publicKey
    }

    /// Restore from raw private key bytes (e.g. from Keychain)
    public init(rawPrivateKey: Data) throws {
        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawPrivateKey)
        self.privateKey = priv
        self.publicKey  = priv.publicKey
    }
}

/// Long-term signing key pair for identity
public struct APEXSigningKeyPair: Sendable {
    public let privateKey: APEXSigningPrivateKey
    public let publicKey:  APEXSigningPublicKey

    public init() {
        let priv = Curve25519.Signing.PrivateKey()
        self.privateKey = priv
        self.publicKey  = priv.publicKey
    }

    public init(rawPrivateKey: Data) throws {
        let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: rawPrivateKey)
        self.privateKey = priv
        self.publicKey  = priv.publicKey
    }

    /// Sign arbitrary data, returning a 64-byte Ed25519 signature
    public func sign(_ data: Data) throws -> Data {
        return try privateKey.signature(for: data)
    }
}

// MARK: - Key Fingerprint

public extension APEXDHPublicKey {
    /// SHA-256 fingerprint (hex) for display and verification
    var fingerprint: String {
        let hash = SHA256.hash(data: rawRepresentation)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Safety-number–style human fingerprint (5 groups of 6 digits)
    var safetyNumber: String {
        let hash = SHA256.hash(data: rawRepresentation)
        let bytes = Array(hash)
        return stride(from: 0, to: 30, by: 6).map { i in
            let chunk = bytes[i..<(i+6)]
            let val = chunk.reduce(0) { ($0 << 8) | UInt64($1) } % 1_000_000
            return String(format: "%06d", val)
        }.joined(separator: " ")
    }
}

public extension APEXSigningPublicKey {
    var fingerprint: String {
        let hash = SHA256.hash(data: rawRepresentation)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - APEX Protocol Constants

public enum APEXConstants {
    /// Protocol version negotiated at session start
    public static let protocolVersion: UInt8 = 1

    /// HKDF info strings (domain separation)
    public static let hkdfInfoX3DH        = "APEX_v1_X3DH".data(using: .utf8)!
    public static let hkdfInfoRootChain   = "APEX_v1_RootChain".data(using: .utf8)!
    public static let hkdfInfoMessageKey  = "APEX_v1_MessageKey".data(using: .utf8)!
    public static let hkdfInfoSealedSender = "APEX_v1_SealedSender".data(using: .utf8)!
    public static let hkdfInfoPQHybrid    = "APEX_v1_PQHybrid".data(using: .utf8)!
    public static let hkdfSaltPQHybrid    = "APEX_v1_PQHybrid_Salt".data(using: .utf8)!

    /// Number of one-time pre-keys to generate per batch
    public static let oneTimePreKeyBatchSize = 100

    /// Max skipped messages before out-of-order window is closed
    public static let maxSkippedMessages = 1000

    /// Signed pre-key rotation interval (7 days in seconds)
    public static let signedPreKeyRotationInterval: TimeInterval = 7 * 24 * 3600

    /// AES-GCM nonce size
    public static let nonceSize = 12

    /// ChaCha20-Poly1305 tag size
    public static let tagSize = 16

    /// 32-byte zero buffer used as X3DH padding
    public static let x3dhPadding = Data(repeating: 0xFF, count: 32)
}

// MARK: - APEX Errors

public enum APEXError: Error, LocalizedError {
    case keyGenerationFailed
    case keyAgreementFailed
    case signatureVerificationFailed
    case invalidSignature
    case invalidPreKeyBundle
    case noOneTimePreKeyAvailable
    case sessionNotInitialized
    case encryptionFailed
    case decryptionFailed
    case messageReplay
    case skippedMessageLimitExceeded
    case keyDerivationFailed
    case invalidMessageFormat
    case unsupportedProtocolVersion
    case sealedSenderDecryptionFailed
    case postQuantumError(String)
    case keychainError(OSStatus)
    case secureEnclaveUnavailable

    public var errorDescription: String? {
        switch self {
        case .keyGenerationFailed:            return "Key generation failed"
        case .keyAgreementFailed:             return "DH key agreement failed"
        case .signatureVerificationFailed:    return "Signature verification failed"
        case .invalidSignature:               return "Invalid signature"
        case .invalidPreKeyBundle:            return "Invalid pre-key bundle"
        case .noOneTimePreKeyAvailable:       return "No one-time pre-key available"
        case .sessionNotInitialized:          return "Session not initialized"
        case .encryptionFailed:               return "Encryption failed"
        case .decryptionFailed:               return "Decryption failed"
        case .messageReplay:                  return "Replay attack detected"
        case .skippedMessageLimitExceeded:    return "Too many skipped messages"
        case .keyDerivationFailed:            return "Key derivation failed"
        case .invalidMessageFormat:           return "Invalid message format"
        case .unsupportedProtocolVersion:     return "Unsupported protocol version"
        case .sealedSenderDecryptionFailed:   return "Sealed sender decryption failed"
        case .postQuantumError(let msg):      return "Post-quantum error: \(msg)"
        case .keychainError(let status):      return "Keychain error: \(status)"
        case .secureEnclaveUnavailable:       return "Secure Enclave unavailable"
        }
    }
}
