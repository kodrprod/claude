// APEXKeyDerivation.swift
// APEX Protocol — Key Derivation Functions
//
// All KDF operations in APEX use HKDF-SHA-512 for maximum security margin.
// Domain separation is enforced via distinct info strings for every context.
//
// KDF hierarchy:
//   X3DH master secret → Root Key (RK)
//   RK + DH output    → new RK + Chain Key (CK)   [DH Ratchet step]
//   CK                → new CK + Message Key (MK)  [Symmetric ratchet step]
//   MK                → AES-GCM key + nonce        [Message encryption]

import Foundation
import CryptoKit

public enum APEXKeyDerivation {

    // MARK: - HKDF Primitives

    /// HKDF-Extract: derive pseudorandom key from input key material + salt
    private static func extract(salt: Data, inputKeyMaterial: Data) -> SymmetricKey {
        let saltKey = SymmetricKey(data: salt)
        let prk = HMAC<SHA512>.authenticationCode(
            for: inputKeyMaterial,
            using: saltKey
        )
        return SymmetricKey(data: Data(prk))
    }

    /// HKDF-Expand: expand PRK to desired output length with info label
    private static func expand(prk: SymmetricKey, info: Data, outputLength: Int) -> Data {
        var output = Data()
        var previous = Data()
        var counter: UInt8 = 1

        while output.count < outputLength {
            var input = previous + info + Data([counter])
            let block = HMAC<SHA512>.authenticationCode(for: input, using: prk)
            output.append(contentsOf: block)
            previous = Data(block)
            counter += 1
            // Zero sensitive intermediate data
            input = Data(repeating: 0, count: input.count)
        }

        return Data(output.prefix(outputLength))
    }

    /// Full HKDF-SHA-512: extract + expand
    static func hkdf(
        inputKeyMaterial: Data,
        salt: Data,
        info: Data,
        outputLength: Int
    ) -> Data {
        let prk = extract(salt: salt, inputKeyMaterial: inputKeyMaterial)
        return expand(prk: prk, info: info, outputLength: outputLength)
    }

    // MARK: - X3DH Master Secret → Root Key

    /// Derive initial Root Key from X3DH shared secret material.
    /// The input is the concatenation of all X3DH DH outputs (DH1‖DH2‖DH3[‖DH4]).
    /// Uses a 32-byte 0xFF salt (as per Signal spec) for X3DH.
    public static func deriveRootKey(fromX3DHSecret secret: Data) -> APEXRootKey {
        let salt = APEXConstants.x3dhPadding
        let output = hkdf(
            inputKeyMaterial: secret,
            salt: salt,
            info: APEXConstants.hkdfInfoX3DH,
            outputLength: 32
        )
        return SymmetricKey(data: output)
    }

    // MARK: - DH Ratchet: Root Chain KDF

    /// KDF_RK: Given current root key and DH output, derive new root key + chain key.
    /// Returns (newRootKey: 32B, newChainKey: 32B)
    public static func kdfRootChain(
        rootKey: APEXRootKey,
        dhOutput: Data
    ) -> (newRootKey: APEXRootKey, newChainKey: APEXChainKey) {
        let rkBytes = rootKey.withUnsafeBytes { Data($0) }
        let output = hkdf(
            inputKeyMaterial: dhOutput,
            salt: rkBytes,
            info: APEXConstants.hkdfInfoRootChain,
            outputLength: 64  // 32 bytes RK + 32 bytes CK
        )
        let newRK = SymmetricKey(data: output.prefix(32))
        let newCK = Data(output.suffix(32))
        return (newRK, newCK)
    }

    // MARK: - Symmetric Ratchet: Chain Key → Message Key

    /// KDF_CK: Advance the chain key and derive a message key.
    /// Uses HMAC-SHA-512 with fixed constants (0x01 = message key, 0x02 = next chain key).
    /// Returns (newChainKey: 32B, messageKey: SymmetricKey 32B)
    public static func kdfChain(
        chainKey: APEXChainKey
    ) -> (newChainKey: APEXChainKey, messageKey: APEXMessageKey) {
        let ckKey = SymmetricKey(data: chainKey)

        // Message key: HMAC(CK, 0x01)
        let mkBytes = HMAC<SHA512>.authenticationCode(
            for: Data([0x01]),
            using: ckKey
        )

        // Next chain key: HMAC(CK, 0x02)
        let nextCKBytes = HMAC<SHA512>.authenticationCode(
            for: Data([0x02]),
            using: ckKey
        )

        let messageKey = SymmetricKey(data: Data(mkBytes).prefix(32))
        let newChainKey = Data(Data(nextCKBytes).prefix(32))

        return (newChainKey, messageKey)
    }

    // MARK: - Message Key Expansion

    /// Expand a 32-byte message key into AES-GCM key (32B) + deterministic nonce (12B).
    /// The nonce is derived (not random) to allow deterministic AEAD with the message key.
    public static func expandMessageKey(
        _ mk: APEXMessageKey,
        messageIndex: UInt64
    ) -> (encKey: SymmetricKey, nonce: AES.GCM.Nonce) {
        let mkBytes = mk.withUnsafeBytes { Data($0) }
        var indexBytes = messageIndex.bigEndian
        let indexData = Data(bytes: &indexBytes, count: 8)

        let expanded = hkdf(
            inputKeyMaterial: mkBytes,
            salt: indexData,
            info: APEXConstants.hkdfInfoMessageKey,
            outputLength: 44  // 32 bytes key + 12 bytes nonce
        )

        let encKey = SymmetricKey(data: expanded.prefix(32))
        let nonceData = expanded.suffix(12)
        // swiftlint:disable:next force_try
        let nonce = try! AES.GCM.Nonce(data: nonceData)

        return (encKey, nonce)
    }

    // MARK: - Sealed Sender Key Derivation

    /// Derive an ephemeral symmetric key for sealing sender identity.
    /// Takes the ECDH shared secret between sender's ephemeral key and recipient's identity key.
    public static func deriveSealedSenderKey(dhOutput: Data) -> SymmetricKey {
        let salt = Data(SHA256.hash(data: "APEX_SealedSender_Salt".data(using: .utf8)!))
        let output = hkdf(
            inputKeyMaterial: dhOutput,
            salt: salt,
            info: APEXConstants.hkdfInfoSealedSender,
            outputLength: 32
        )
        return SymmetricKey(data: output)
    }

    // MARK: - Post-Quantum Hybrid Key Combination

    /// Combine classical X25519 shared secret with post-quantum shared secret.
    /// Concatenates both secrets and applies HKDF, so security holds if EITHER is secure.
    /// This is the hybrid KEM approach used by PQ3 / Signal PQXDH.
    public static func hybridCombine(
        classicalSecret: Data,
        pqSecret: Data
    ) -> Data {
        let combined = classicalSecret + pqSecret
        let salt = Data(SHA512.hash(data: APEXConstants.hkdfInfoPQHybrid))
        return hkdf(
            inputKeyMaterial: combined,
            salt: salt,
            info: APEXConstants.hkdfInfoPQHybrid,
            outputLength: 32
        )
    }
}
