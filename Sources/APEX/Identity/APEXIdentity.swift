// APEXIdentity.swift
// APEX Protocol — Identity Key Management
//
// An APEX identity consists of:
//   1. Long-term DH identity key (IK) — used in X3DH
//   2. Long-term Ed25519 signing key — signs SPK and proves ownership of IK
//   3. Current signed pre-key (SPK) — rotated every 7 days
//   4. Pool of one-time pre-keys (OPK) — 100 at a time, replenished as consumed
//   5. Post-quantum pre-key pool — ML-KEM-768 keys for PQ hybrid sessions
//
// Key storage:
//   - Identity keys: Secure Enclave (where available) or Keychain
//   - Pre-keys: Keychain with AES-GCM wrapping
//   - Public bundles: Uploadable to server
//
// APEX identity is device-scoped. Multi-device support is handled by
// the Session layer via a Sender Key Distribution message.

import Foundation
import CryptoKit

// MARK: - APEX Identity

public final class APEXIdentity: @unchecked Sendable {

    // MARK: - Properties

    /// Registration ID — random 14-bit integer, sent in session init
    public let registrationID: UInt16

    /// Long-term DH identity key pair (X25519)
    private(set) public var identityKeyPair: APEXDHKeyPair

    /// Long-term Ed25519 signing key pair (signs SPK, proves IK ownership)
    private(set) public var signingKeyPair: APEXSigningKeyPair

    /// Current signed pre-key
    private(set) public var signedPreKey: APEXDHKeyPair
    private(set) public var signedPreKeyID: UInt32
    private(set) public var signedPreKeySignature: Data
    private(set) public var signedPreKeyCreatedAt: Date

    /// One-time pre-key pool (private keys only; public keys uploaded to server)
    private var oneTimePreKeys: [UInt32: APEXDHKeyPair] = [:]
    private var nextOneTimePreKeyID: UInt32 = 1

    /// Post-quantum pre-key pool
    private var pqPreKeys: [UInt32: APEXPQKeyPair] = [:]
    private var nextPQPreKeyID: UInt32 = 1
    private let pqKEM: any APEXPostQuantumKEM

    // MARK: - Init

    /// Create a brand-new APEX identity (first launch / account creation)
    public init() throws {
        registrationID = UInt16.random(in: 1..<16384)
        identityKeyPair = APEXDHKeyPair()
        signingKeyPair  = APEXSigningKeyPair()
        pqKEM = APEXPostQuantumKEMFactory.makeKEM()

        // Generate initial signed pre-key
        let spkPair = APEXDHKeyPair()
        let spkID: UInt32 = 1
        let spkSig = try APEXIdentity.signPreKey(
            spkID: spkID,
            spkPublicKey: spkPair.publicKey,
            signingKey: signingKeyPair
        )
        signedPreKey = spkPair
        signedPreKeyID = spkID
        signedPreKeySignature = spkSig
        signedPreKeyCreatedAt = Date()

        // Generate initial one-time pre-key pool
        generateOneTimePreKeyBatch()

        // Generate PQ pre-keys if available
        try generatePQPreKeyBatch()
    }

    // MARK: - Pre-Key Bundle Generation

    /// Generate the public pre-key bundle to upload to the server.
    /// Optionally includes one one-time pre-key (consumed by the first session initiator).
    public func makePreKeyBundle(includeOneTimePK: Bool = true) -> APEXPreKeyBundle {
        var otpk: APEXDHPublicKey? = nil
        var otpkID: UInt32? = nil

        if includeOneTimePK, let (id, kp) = oneTimePreKeys.first {
            otpk = kp.publicKey
            otpkID = id
        }

        var pqBundle: APEXPQPreKeyBundle? = nil
        if let (pqID, pqKP) = pqPreKeys.first {
            pqBundle = APEXPQPreKeyBundle(
                pqPreKeyPublicKey: pqKP.publicKey,
                pqPreKeyID: pqID
            )
        }

        return APEXPreKeyBundle(
            identityKey: identityKeyPair.publicKey,
            identitySigningKey: signingKeyPair.publicKey,
            signedPreKeyID: signedPreKeyID,
            signedPreKey: signedPreKey.publicKey,
            signedPreKeySignature: signedPreKeySignature,
            oneTimePreKeyID: otpkID,
            oneTimePreKey: otpk,
            pqPreKey: pqBundle
        )
    }

    // MARK: - Key Lookup (called during session receive)

    /// Look up and consume a one-time pre-key by ID (deletes after retrieval)
    public func consumeOneTimePreKey(id: UInt32) -> APEXDHKeyPair? {
        return oneTimePreKeys.removeValue(forKey: id)
    }

    /// Look up (but don't consume) a signed pre-key by ID
    public func signedPreKeyPair(forID id: UInt32) -> APEXDHKeyPair? {
        guard id == signedPreKeyID else { return nil }
        return signedPreKey
    }

    /// Look up and consume a PQ pre-key by ID
    public func consumePQPreKey(id: UInt32) -> APEXPQKeyPair? {
        return pqPreKeys.removeValue(forKey: id)
    }

    // MARK: - Key Rotation

    /// Rotate signed pre-key (call periodically, e.g. every 7 days)
    public func rotateSignedPreKey() throws {
        let newSPKPair = APEXDHKeyPair()
        let newSPKID = signedPreKeyID + 1
        let newSPKSig = try APEXIdentity.signPreKey(
            spkID: newSPKID,
            spkPublicKey: newSPKPair.publicKey,
            signingKey: signingKeyPair
        )
        signedPreKey = newSPKPair
        signedPreKeyID = newSPKID
        signedPreKeySignature = newSPKSig
        signedPreKeyCreatedAt = Date()
    }

    /// Check if signed pre-key needs rotation
    public var needsSignedPreKeyRotation: Bool {
        Date().timeIntervalSince(signedPreKeyCreatedAt) > APEXConstants.signedPreKeyRotationInterval
    }

    /// How many one-time pre-keys remain
    public var remainingOneTimePreKeys: Int {
        oneTimePreKeys.count
    }

    /// Generate a new batch of one-time pre-keys (called when pool is low)
    public func generateOneTimePreKeyBatch() {
        let batch = generateOneTimePreKeys(startingID: nextOneTimePreKeyID)
        for record in batch {
            oneTimePreKeys[record.id] = record.keyPair
        }
        nextOneTimePreKeyID += UInt32(batch.count)
    }

    /// Public one-time pre-keys (only public parts, for server upload)
    public var publicOneTimePreKeys: [(id: UInt32, publicKeyData: Data)] {
        oneTimePreKeys.map { (id: $0.key, publicKeyData: $0.value.publicKey.rawRepresentation) }
    }

    // MARK: - Identity Fingerprint

    /// Canonical safety number for key verification (shown to users to confirm no MITM)
    public var safetyNumber: String {
        identityKeyPair.publicKey.safetyNumber
    }

    public var identityFingerprint: String {
        identityKeyPair.publicKey.fingerprint
    }

    // MARK: - Private Helpers

    private static func signPreKey(
        spkID: UInt32,
        spkPublicKey: APEXDHPublicKey,
        signingKey: APEXSigningKeyPair
    ) throws -> Data {
        var message = Data([APEXConstants.protocolVersion])
        var idBE = spkID.bigEndian
        message += Data(bytes: &idBE, count: 4)
        message += spkPublicKey.rawRepresentation
        return try signingKey.sign(message)
    }

    private func generatePQPreKeyBatch() throws {
        let batchSize = 10
        for _ in 0..<batchSize {
            let kp = try pqKEM.generateKeyPair()
            let id = nextPQPreKeyID
            pqPreKeys[id] = kp
            nextPQPreKeyID += 1
        }
    }
}
