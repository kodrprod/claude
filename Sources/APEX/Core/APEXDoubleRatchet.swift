// APEXDoubleRatchet.swift
// APEX Protocol — Double Ratchet Algorithm
//
// The Double Ratchet combines:
//   1. A "DH Ratchet" — each reply triggers a DH step, deriving new chain keys.
//      This gives break-in recovery: compromising current keys doesn't expose future ones.
//   2. A "Symmetric Ratchet" — each message advances the chain key, deriving a fresh
//      message key. This gives forward secrecy: deleting message keys hides past messages.
//
// State per session direction:
//   DHs   — our current DH ratchet key pair (sending)
//   DHr   — their current DH ratchet public key (receiving)
//   RK    — 32-byte root key
//   CKs   — sending chain key
//   CKr   — receiving chain key
//   Ns    — message number (sending)
//   Nr    — message number (receiving)
//   PN    — previous sending chain length (for out-of-order delivery)
//   MKSKIPPED — map of (DHr, N) → message key for skipped messages
//
// APEX enhancement: "Adaptive Ratchet" — callers can request an immediate
// DH ratchet step for any message flagged as high-security (e.g. key rotation,
// financial data), providing an extra layer of forward secrecy on demand.

import Foundation
import CryptoKit

// MARK: - Ratchet Header (sent with every message)

public struct APEXRatchetHeader: Codable, Sendable {
    /// Sender's current DH ratchet public key
    public let dhPublicKey: Data
    /// How many messages were in the previous sending chain
    public let previousChainLength: UInt32
    /// Index of this message in the current sending chain
    public let messageIndex: UInt32

    public init(dhPublicKey: Data, previousChainLength: UInt32, messageIndex: UInt32) {
        self.dhPublicKey = dhPublicKey
        self.previousChainLength = previousChainLength
        self.messageIndex = messageIndex
    }

    /// Serialize to wire format: dhPubKey(32) ‖ PN(4BE) ‖ N(4BE)
    public var wireEncoding: Data {
        var data = dhPublicKey
        var pn = previousChainLength.bigEndian
        var n  = messageIndex.bigEndian
        data += Data(bytes: &pn, count: 4)
        data += Data(bytes: &n, count: 4)
        return data
    }
}

// MARK: - Skipped Message Key Cache Entry

private struct SkippedKeyEntry: Hashable {
    let dhPublicKeyFingerprint: String  // hex fingerprint of the ratchet key
    let messageIndex: UInt32
}

// MARK: - Double Ratchet State

public final class APEXDoubleRatchetState: @unchecked Sendable {

    // DH keys
    var dhSendingKeyPair: APEXDHKeyPair
    var dhReceivingPublicKey: APEXDHPublicKey?

    // Chain keys
    var rootKey: APEXRootKey
    var sendingChainKey: APEXChainKey?
    var receivingChainKey: APEXChainKey?

    // Message counters
    var sendingMessageIndex: UInt32 = 0
    var receivingMessageIndex: UInt32 = 0
    var previousSendingChainLength: UInt32 = 0

    // Skipped message key cache: (DHPublicKey fingerprint + messageIndex) → message key
    var skippedMessageKeys: [SkippedKeyEntry: APEXMessageKey] = [:]

    // Associated data from X3DH (bound into every message)
    let associatedData: Data

    // Whether we've received at least one message (tracks ratchet init side)
    var hasReceivedMessage = false

    init(
        rootKey: APEXRootKey,
        dhSendingKeyPair: APEXDHKeyPair,
        associatedData: Data
    ) {
        self.rootKey = rootKey
        self.dhSendingKeyPair = dhSendingKeyPair
        self.associatedData = associatedData
    }

    /// Initialize for the session initiator (Alice):
    /// Alice has no sending chain key yet — it's established when Bob responds.
    static func forInitiator(
        sharedSecret: Data,
        recipientRatchetKey: APEXDHPublicKey,
        associatedData: Data
    ) throws -> APEXDoubleRatchetState {
        let rk = APEXKeyDerivation.deriveRootKey(fromX3DHSecret: sharedSecret)
        let dhPair = APEXDHKeyPair()

        let state = APEXDoubleRatchetState(
            rootKey: rk,
            dhSendingKeyPair: dhPair,
            associatedData: associatedData
        )
        state.dhReceivingPublicKey = recipientRatchetKey

        // Immediately perform first DH ratchet to get Alice's sending chain
        do {
            let dhOutput = try dhPair.privateKey
                .sharedSecretFromKeyAgreement(with: recipientRatchetKey)
                .withUnsafeBytes { Data($0) }
            let (newRK, ckS) = APEXKeyDerivation.kdfRootChain(rootKey: rk, dhOutput: dhOutput)
            state.rootKey = newRK
            state.sendingChainKey = ckS
        } catch {
            throw APEXError.keyAgreementFailed
        }

        return state
    }

    /// Initialize for the session responder (Bob):
    /// Bob starts with a receiving chain key from Alice's first message.
    static func forResponder(
        sharedSecret: Data,
        ourRatchetKeyPair: APEXDHKeyPair,
        associatedData: Data
    ) -> APEXDoubleRatchetState {
        let rk = APEXKeyDerivation.deriveRootKey(fromX3DHSecret: sharedSecret)

        let state = APEXDoubleRatchetState(
            rootKey: rk,
            dhSendingKeyPair: ourRatchetKeyPair,
            associatedData: associatedData
        )
        // Bob has no chain keys yet; they're derived when he receives Alice's first message.
        return state
    }
}

// MARK: - Double Ratchet Engine

public struct APEXDoubleRatchet {

    // MARK: - Encrypt

    /// Encrypt a plaintext message using the current sending chain.
    /// Returns the encrypted message with its ratchet header.
    public static func encrypt(
        plaintext: Data,
        state: APEXDoubleRatchetState,
        additionalData: Data = Data()
    ) throws -> (header: APEXRatchetHeader, ciphertext: Data) {

        guard var ck = state.sendingChainKey else {
            throw APEXError.sessionNotInitialized
        }

        // Advance symmetric ratchet
        let (newCK, messageKey) = APEXKeyDerivation.kdfChain(chainKey: ck)
        ck = newCK
        state.sendingChainKey = newCK

        // Build header
        let header = APEXRatchetHeader(
            dhPublicKey: state.dhSendingKeyPair.publicKey.rawRepresentation,
            previousChainLength: state.previousSendingChainLength,
            messageIndex: state.sendingMessageIndex
        )

        // Derive per-message AES-GCM key + nonce from message key + index
        let (encKey, nonce) = try APEXKeyDerivation.expandMessageKey(
            messageKey,
            messageIndex: UInt64(state.sendingMessageIndex)
        )

        // AEAD: associated data = X3DH AD ‖ header wire encoding ‖ caller AD
        let aad = state.associatedData + header.wireEncoding + additionalData

        let sealedBox = try AES.GCM.seal(plaintext, using: encKey, nonce: nonce, authenticating: aad)
        let ciphertext = sealedBox.ciphertext + sealedBox.tag

        state.sendingMessageIndex += 1

        return (header, ciphertext)
    }

    // MARK: - Decrypt

    /// Decrypt a received message, performing DH ratchet step if needed.
    public static func decrypt(
        header: APEXRatchetHeader,
        ciphertext: Data,
        state: APEXDoubleRatchetState,
        additionalData: Data = Data()
    ) throws -> Data {

        let theirDHKey = try APEXDHPublicKey(rawRepresentation: header.dhPublicKey)
        let dhFingerprint = theirDHKey.fingerprint

        // Check skipped message key cache first
        let cacheKey = SkippedKeyEntry(
            dhPublicKeyFingerprint: dhFingerprint,
            messageIndex: header.messageIndex
        )
        if let skippedMK = state.skippedMessageKeys[cacheKey] {
            state.skippedMessageKeys.removeValue(forKey: cacheKey)
            return try decryptWithMessageKey(
                skippedMK,
                ciphertext: ciphertext,
                header: header,
                state: state,
                additionalData: additionalData
            )
        }

        // Determine if this triggers a DH ratchet step
        let isNewRatchetKey = state.dhReceivingPublicKey.map {
            $0.rawRepresentation != theirDHKey.rawRepresentation
        } ?? true

        if isNewRatchetKey {
            // Skip remaining messages in previous receiving chain
            try skipMessageKeys(
                state: state,
                upTo: header.previousChainLength,
                dhFingerprint: state.dhReceivingPublicKey?.fingerprint ?? ""
            )

            // Perform DH ratchet: derive new receiving chain key
            try performDHRatchetReceive(
                state: state,
                theirNewDHKey: theirDHKey
            )
        }

        // Skip messages in current receiving chain up to this message's index
        try skipMessageKeys(
            state: state,
            upTo: header.messageIndex,
            dhFingerprint: dhFingerprint
        )

        guard var ck = state.receivingChainKey else {
            throw APEXError.sessionNotInitialized
        }

        let (newCK, messageKey) = APEXKeyDerivation.kdfChain(chainKey: ck)
        ck = newCK
        state.receivingChainKey = newCK
        state.receivingMessageIndex = header.messageIndex + 1

        return try decryptWithMessageKey(
            messageKey,
            ciphertext: ciphertext,
            header: header,
            state: state,
            additionalData: additionalData
        )
    }

    // MARK: - Adaptive Ratchet (APEX Extension)

    /// Force an immediate DH ratchet step before sending a high-security message.
    /// This provides an extra layer of forward secrecy beyond the normal ratchet schedule.
    /// Use for: key rotation messages, financial transactions, sensitive content.
    public static func forceRatchetStep(state: APEXDoubleRatchetState) throws {
        guard let theirKey = state.dhReceivingPublicKey else {
            throw APEXError.sessionNotInitialized
        }

        // Generate brand-new DH sending key pair
        let newDHPair = APEXDHKeyPair()
        state.previousSendingChainLength = state.sendingMessageIndex
        state.sendingMessageIndex = 0
        state.dhSendingKeyPair = newDHPair

        // Derive new sending chain from the new DH output
        let dhOutput = try newDHPair.privateKey
            .sharedSecretFromKeyAgreement(with: theirKey)
            .withUnsafeBytes { Data($0) }
        let (newRK, newCKs) = APEXKeyDerivation.kdfRootChain(rootKey: state.rootKey, dhOutput: dhOutput)
        state.rootKey = newRK
        state.sendingChainKey = newCKs
    }

    // MARK: - Private Helpers

    private static func performDHRatchetReceive(
        state: APEXDoubleRatchetState,
        theirNewDHKey: APEXDHPublicKey
    ) throws {
        state.previousSendingChainLength = state.sendingMessageIndex
        state.sendingMessageIndex = 0
        state.receivingMessageIndex = 0
        state.dhReceivingPublicKey = theirNewDHKey

        // Step 1: Derive new receiving chain key from their new DH key
        let dhOutput1 = try state.dhSendingKeyPair.privateKey
            .sharedSecretFromKeyAgreement(with: theirNewDHKey)
            .withUnsafeBytes { Data($0) }
        let (rk1, ckr) = APEXKeyDerivation.kdfRootChain(rootKey: state.rootKey, dhOutput: dhOutput1)
        state.rootKey = rk1
        state.receivingChainKey = ckr

        // Step 2: Generate our new DH sending key pair + derive new sending chain
        let newDHPair = APEXDHKeyPair()
        state.dhSendingKeyPair = newDHPair

        let dhOutput2 = try newDHPair.privateKey
            .sharedSecretFromKeyAgreement(with: theirNewDHKey)
            .withUnsafeBytes { Data($0) }
        let (rk2, cks) = APEXKeyDerivation.kdfRootChain(rootKey: rk1, dhOutput: dhOutput2)
        state.rootKey = rk2
        state.sendingChainKey = cks
    }

    private static func skipMessageKeys(
        state: APEXDoubleRatchetState,
        upTo targetIndex: UInt32,
        dhFingerprint: String
    ) throws {
        guard var ck = state.receivingChainKey else { return }

        let currentIndex = state.receivingMessageIndex
        guard targetIndex > currentIndex else { return }

        let skip = targetIndex - currentIndex
        guard skip <= APEXConstants.maxSkippedMessages else {
            throw APEXError.skippedMessageLimitExceeded
        }

        for i in currentIndex..<targetIndex {
            let (newCK, messageKey) = APEXKeyDerivation.kdfChain(chainKey: ck)
            ck = newCK
            let entry = SkippedKeyEntry(dhPublicKeyFingerprint: dhFingerprint, messageIndex: i)
            state.skippedMessageKeys[entry] = messageKey
        }

        state.receivingChainKey = ck
        state.receivingMessageIndex = targetIndex
    }

    private static func decryptWithMessageKey(
        _ messageKey: APEXMessageKey,
        ciphertext: Data,
        header: APEXRatchetHeader,
        state: APEXDoubleRatchetState,
        additionalData: Data
    ) throws -> Data {
        let (encKey, nonce) = try APEXKeyDerivation.expandMessageKey(
            messageKey,
            messageIndex: UInt64(header.messageIndex)
        )

        let aad = state.associatedData + header.wireEncoding + additionalData

        guard ciphertext.count > APEXConstants.tagSize else {
            throw APEXError.decryptionFailed
        }

        let body = ciphertext.prefix(ciphertext.count - APEXConstants.tagSize)
        let tag  = ciphertext.suffix(APEXConstants.tagSize)

        do {
            let sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: body,
                tag: tag
            )
            return try AES.GCM.open(sealedBox, using: encKey, authenticating: aad)
        } catch {
            throw APEXError.decryptionFailed
        }
    }
}
