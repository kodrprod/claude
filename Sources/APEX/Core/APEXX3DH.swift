// APEXX3DH.swift
// APEX Protocol — Extended Triple Diffie-Hellman (X3DH) Key Agreement
//
// X3DH establishes a shared secret between two parties without requiring
// both to be online simultaneously. It provides:
//   - Mutual authentication (both parties' identity keys contribute)
//   - Forward secrecy (ephemeral keys)
//   - Deniability (no long-term signatures on message content)
//
// APEX extends the standard Signal X3DH with:
//   - Post-quantum hybrid encapsulation (optional, when PQ keys present)
//   - Protocol version negotiation
//   - Associated data construction for AEAD binding
//
// Protocol:
//   Alice has:  IK_A (identity), EK_A (ephemeral, generated per session)
//   Bob has:    IK_B (identity), SPK_B (signed pre-key), OPK_B (one-time pre-key, optional)
//
//   DH1 = X25519(IK_A_priv, SPK_B_pub)      — Alice's identity × Bob's signed pre-key
//   DH2 = X25519(EK_A_priv, IK_B_pub)       — Alice's ephemeral × Bob's identity
//   DH3 = X25519(EK_A_priv, SPK_B_pub)      — Alice's ephemeral × Bob's signed pre-key
//   DH4 = X25519(EK_A_priv, OPK_B_pub)      — Alice's ephemeral × Bob's one-time (optional)
//
//   SK = HKDF(DH1 ‖ DH2 ‖ DH3 [‖ DH4] [‖ PQ_SS])
//
//   Associated Data = IK_A_pub ‖ IK_B_pub   (bound into every encrypted message)

import Foundation
import CryptoKit

// MARK: - X3DH Initiator Output

/// Everything Alice needs to bootstrap a session and what she must send Bob.
public struct X3DHInitiatorResult {
    /// The derived shared secret (input to Double Ratchet root key)
    public let sharedSecret: Data

    /// Associated data = IK_A‖IK_B, bound into every subsequent message AEAD
    public let associatedData: Data

    /// Alice's ephemeral public key — must be sent to Bob
    public let ephemeralPublicKey: APEXDHPublicKey

    /// Which of Bob's signed pre-keys was used (so Bob can look it up)
    public let usedSignedPreKeyID: UInt32

    /// Which of Bob's one-time pre-keys was used (nil if none available)
    public let usedOneTimePreKeyID: UInt32?
}

// MARK: - X3DH Responder Output

/// Everything Bob derives after receiving Alice's initial message.
public struct X3DHResponderResult {
    public let sharedSecret: Data
    public let associatedData: Data
}

// MARK: - APEX X3DH Engine

public enum APEXX3DH {

    // MARK: - Initiator (Alice)

    /// Perform the initiator side of X3DH.
    /// - Parameters:
    ///   - senderIdentity:   Alice's long-term identity key pair
    ///   - recipientBundle:  Bob's pre-key bundle (fetched from server)
    ///   - pqSharedSecret:   Optional post-quantum shared secret from hybrid KEM
    /// - Returns: `X3DHInitiatorResult` containing SK and keys to send Bob
    public static func performInitiator(
        senderIdentity: APEXDHKeyPair,
        senderSigningKey: APEXSigningKeyPair,
        recipientBundle: APEXPreKeyBundle,
        pqSharedSecret: Data? = nil
    ) throws -> X3DHInitiatorResult {

        // 1. Verify Bob's signed pre-key signature
        guard try verifySignedPreKey(bundle: recipientBundle) else {
            throw APEXError.signatureVerificationFailed
        }

        // 2. Generate Alice's ephemeral key pair
        let ephemeralKeyPair = APEXDHKeyPair()

        // 3. Compute DH values
        let dh1 = try sharedSecret(
            privateKey: senderIdentity.privateKey,
            publicKey: recipientBundle.signedPreKey
        )
        let dh2 = try sharedSecret(
            privateKey: ephemeralKeyPair.privateKey,
            publicKey: recipientBundle.identityKey
        )
        let dh3 = try sharedSecret(
            privateKey: ephemeralKeyPair.privateKey,
            publicKey: recipientBundle.signedPreKey
        )

        var ikm = dh1 + dh2 + dh3
        var usedOTPKID: UInt32? = nil

        // 4. Optional: DH4 with one-time pre-key
        if let otpk = recipientBundle.oneTimePreKey,
           let otpkID = recipientBundle.oneTimePreKeyID {
            let dh4 = try sharedSecret(
                privateKey: ephemeralKeyPair.privateKey,
                publicKey: otpk
            )
            ikm += dh4
            usedOTPKID = otpkID
        }

        // 5. Optional: Mix in post-quantum shared secret
        if let pqSS = pqSharedSecret {
            ikm = APEXKeyDerivation.hybridCombine(classicalSecret: ikm, pqSecret: pqSS)
        }

        // 6. Derive shared secret via HKDF
        let sk = APEXKeyDerivation.deriveRootKey(fromX3DHSecret: ikm)
        let skBytes = sk.withUnsafeBytes { Data($0) }

        // 7. Build associated data (Alice's IK ‖ Bob's IK)
        let ad = senderIdentity.publicKey.rawRepresentation +
                 recipientBundle.identityKey.rawRepresentation

        // Clear sensitive intermediate data
        var ikmCopy = ikm
        ikmCopy = Data(repeating: 0, count: ikmCopy.count)

        return X3DHInitiatorResult(
            sharedSecret: skBytes,
            associatedData: ad,
            ephemeralPublicKey: ephemeralKeyPair.publicKey,
            usedSignedPreKeyID: recipientBundle.signedPreKeyID,
            usedOneTimePreKeyID: usedOTPKID
        )
    }

    // MARK: - Responder (Bob)

    /// Perform the responder side of X3DH.
    /// Bob reconstructs the same shared secret from Alice's initial message.
    /// - Parameters:
    ///   - recipientIdentity:    Bob's long-term identity key pair
    ///   - recipientSignedPreKey: Bob's signed pre-key (looked up by ID)
    ///   - recipientOneTimePreKey: Bob's one-time pre-key (looked up by ID, deleted after use)
    ///   - senderIdentityKey:    Alice's identity public key (from her initial message)
    ///   - senderEphemeralKey:   Alice's ephemeral public key (from her initial message)
    ///   - pqSharedSecret:       Optional post-quantum shared secret from hybrid KEM
    public static func performResponder(
        recipientIdentity: APEXDHKeyPair,
        recipientSignedPreKey: APEXDHKeyPair,
        recipientOneTimePreKey: APEXDHKeyPair?,
        senderIdentityKey: APEXDHPublicKey,
        senderEphemeralKey: APEXDHPublicKey,
        pqSharedSecret: Data? = nil
    ) throws -> X3DHResponderResult {

        // Mirror Alice's DH computations
        let dh1 = try sharedSecret(
            privateKey: recipientSignedPreKey.privateKey,
            publicKey: senderIdentityKey
        )
        let dh2 = try sharedSecret(
            privateKey: recipientIdentity.privateKey,
            publicKey: senderEphemeralKey
        )
        let dh3 = try sharedSecret(
            privateKey: recipientSignedPreKey.privateKey,
            publicKey: senderEphemeralKey
        )

        var ikm = dh1 + dh2 + dh3

        if let otpkPair = recipientOneTimePreKey {
            let dh4 = try sharedSecret(
                privateKey: otpkPair.privateKey,
                publicKey: senderEphemeralKey
            )
            ikm += dh4
        }

        if let pqSS = pqSharedSecret {
            ikm = APEXKeyDerivation.hybridCombine(classicalSecret: ikm, pqSecret: pqSS)
        }

        let sk = APEXKeyDerivation.deriveRootKey(fromX3DHSecret: ikm)
        let skBytes = sk.withUnsafeBytes { Data($0) }

        // Associated data: sender(Alice)'s IK ‖ recipient(Bob)'s IK
        let ad = senderIdentityKey.rawRepresentation +
                 recipientIdentity.publicKey.rawRepresentation

        return X3DHResponderResult(
            sharedSecret: skBytes,
            associatedData: ad
        )
    }

    // MARK: - Helpers

    private static func sharedSecret(
        privateKey: APEXDHPrivateKey,
        publicKey: APEXDHPublicKey
    ) throws -> Data {
        do {
            let ss = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
            return ss.withUnsafeBytes { Data($0) }
        } catch {
            throw APEXError.keyAgreementFailed
        }
    }

    private static func verifySignedPreKey(bundle: APEXPreKeyBundle) throws -> Bool {
        // The signed pre-key signature covers:
        //   version (1B) ‖ signedPreKeyID (4B) ‖ signedPreKey.rawRepresentation (32B)
        var message = Data([APEXConstants.protocolVersion])
        var idBytes = bundle.signedPreKeyID.bigEndian
        message += Data(bytes: &idBytes, count: 4)
        message += bundle.signedPreKey.rawRepresentation

        return bundle.identitySigningKey.isValidSignature(
            bundle.signedPreKeySignature,
            for: message
        )
    }
}
