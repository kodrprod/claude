// APEXPreKeyBundle.swift
// APEX Protocol — Pre-Key Bundle
//
// A pre-key bundle is Bob's public identity material that Alice fetches
// from the server before initiating a session. It contains:
//   - IK_B:  Bob's long-term identity DH public key
//   - IK_B_sig: Bob's Ed25519 signing key (for verifying SPK signature)
//   - SPK_B: Bob's signed pre-key (medium-term, rotated weekly)
//   - SPK_B_sig: Ed25519 signature over SPK_B proving Bob controls IK_B
//   - OPK_B: Optional one-time pre-key (consumed on first use)
//   - PQ_B: Optional post-quantum pre-key (ML-KEM-768 public key)

import Foundation
import CryptoKit

// MARK: - Pre-Key Bundle

public struct APEXPreKeyBundle: Sendable {

    // Bob's identity public key (for DH in X3DH)
    public let identityKey: APEXDHPublicKey

    // Bob's Ed25519 signing key (for SPK verification)
    public let identitySigningKey: APEXSigningPublicKey

    // Signed pre-key
    public let signedPreKeyID: UInt32
    public let signedPreKey: APEXDHPublicKey
    public let signedPreKeySignature: Data

    // One-time pre-key (optional, consumed after use)
    public let oneTimePreKeyID: UInt32?
    public let oneTimePreKey: APEXDHPublicKey?

    // Post-quantum pre-key (optional)
    public let pqPreKey: APEXPQPreKeyBundle?

    public init(
        identityKey: APEXDHPublicKey,
        identitySigningKey: APEXSigningPublicKey,
        signedPreKeyID: UInt32,
        signedPreKey: APEXDHPublicKey,
        signedPreKeySignature: Data,
        oneTimePreKeyID: UInt32? = nil,
        oneTimePreKey: APEXDHPublicKey? = nil,
        pqPreKey: APEXPQPreKeyBundle? = nil
    ) {
        self.identityKey = identityKey
        self.identitySigningKey = identitySigningKey
        self.signedPreKeyID = signedPreKeyID
        self.signedPreKey = signedPreKey
        self.signedPreKeySignature = signedPreKeySignature
        self.oneTimePreKeyID = oneTimePreKeyID
        self.oneTimePreKey = oneTimePreKey
        self.pqPreKey = pqPreKey
    }
}

// MARK: - Pre-Key Bundle (Serializable Wire Format)

/// Codable representation for server storage and transmission.
public struct APEXPreKeyBundleEncoded: Codable, Sendable {
    public let identityKey: Data              // 32 bytes
    public let identitySigningKey: Data        // 32 bytes
    public let signedPreKeyID: UInt32
    public let signedPreKey: Data             // 32 bytes
    public let signedPreKeySignature: Data    // 64 bytes
    public let oneTimePreKeyID: UInt32?
    public let oneTimePreKey: Data?           // 32 bytes, optional
    public let pqPreKeyPublicKey: Data?       // 1184 bytes (ML-KEM-768), optional
    public let pqPreKeyID: UInt32?

    public func decoded() throws -> APEXPreKeyBundle {
        let ik   = try APEXDHPublicKey(rawRepresentation: identityKey)
        let ikSig = try APEXSigningPublicKey(rawRepresentation: identitySigningKey)
        let spk  = try APEXDHPublicKey(rawRepresentation: signedPreKey)

        var otpk: APEXDHPublicKey? = nil
        if let otpkData = oneTimePreKey {
            otpk = try APEXDHPublicKey(rawRepresentation: otpkData)
        }

        var pqBundle: APEXPQPreKeyBundle? = nil
        if let pqPub = pqPreKeyPublicKey, let pqID = pqPreKeyID {
            pqBundle = APEXPQPreKeyBundle(pqPreKeyPublicKey: pqPub, pqPreKeyID: pqID)
        }

        return APEXPreKeyBundle(
            identityKey: ik,
            identitySigningKey: ikSig,
            signedPreKeyID: signedPreKeyID,
            signedPreKey: spk,
            signedPreKeySignature: signedPreKeySignature,
            oneTimePreKeyID: oneTimePreKeyID,
            oneTimePreKey: otpk,
            pqPreKey: pqBundle
        )
    }
}

// MARK: - One-Time Pre-Key Pool

/// A pool of generated one-time pre-keys. Server stores only public keys;
/// private keys remain on device. Each key is used at most once.
public struct APEXOneTimePreKeyRecord: Sendable {
    public let id: UInt32
    public let keyPair: APEXDHKeyPair

    public var publicKeyData: Data {
        keyPair.publicKey.rawRepresentation
    }
}

/// Generate a batch of one-time pre-keys
public func generateOneTimePreKeys(
    startingID: UInt32,
    count: Int = APEXConstants.oneTimePreKeyBatchSize
) -> [APEXOneTimePreKeyRecord] {
    return (0..<count).map { i in
        APEXOneTimePreKeyRecord(
            id: startingID + UInt32(i),
            keyPair: APEXDHKeyPair()
        )
    }
}
