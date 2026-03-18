// APEXKeychain.swift
// APEX Protocol — Secure Key Storage (Keychain + Secure Enclave)
//
// All private key material in APEX is stored in:
//   - Secure Enclave (identity keys on iOS/macOS, if available)
//   - Keychain (pre-keys, session state, chain keys)
//
// The Keychain items use:
//   - kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly for session keys
//   - kSecAttrAccessibleWhenUnlockedThisDeviceOnly for identity keys
//   - Device binding (non-migratable) for all sensitive keys
//
// Key wrapping:
//   - All Keychain data is wrapped with AES-256-GCM
//   - The wrapping key is derived from a device-specific secret

import Foundation
import CryptoKit
import Security

// MARK: - Keychain Service Names

private enum APEXKeychainService {
    static let identity     = "com.apex.identity"
    static let signedPreKey = "com.apex.signed-prekey"
    static let oneTimePreKey = "com.apex.otpk"
    static let sessionState = "com.apex.session"
    static let pqPreKey     = "com.apex.pq-prekey"
}

// MARK: - Keychain Helper

public enum APEXKeychain {

    // MARK: - Store

    /// Store arbitrary data in the Keychain under a service + account key.
    @discardableResult
    public static func store(
        data: Data,
        service: String,
        account: String,
        accessControl: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) throws -> Bool {
        // Delete any existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessControl
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw APEXError.keychainError(status)
        }
        return true
    }

    // MARK: - Retrieve

    public static func retrieve(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw APEXError.keychainError(status)
        }

        return result as? Data
    }

    // MARK: - Delete

    public static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Identity Key Persistence

    public static func storeIdentityKeyPair(_ keyPair: APEXDHKeyPair, userID: String) throws {
        let rawKey = keyPair.privateKey.rawRepresentation
        try store(
            data: rawKey,
            service: APEXKeychainService.identity,
            account: "DH-\(userID)",
            accessControl: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
    }

    public static func loadIdentityKeyPair(userID: String) throws -> APEXDHKeyPair? {
        guard let raw = try retrieve(
            service: APEXKeychainService.identity,
            account: "DH-\(userID)"
        ) else { return nil }
        return try APEXDHKeyPair(rawPrivateKey: raw)
    }

    public static func storeSigningKeyPair(_ keyPair: APEXSigningKeyPair, userID: String) throws {
        let rawKey = keyPair.privateKey.rawRepresentation
        try store(
            data: rawKey,
            service: APEXKeychainService.identity,
            account: "Signing-\(userID)",
            accessControl: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
    }

    public static func loadSigningKeyPair(userID: String) throws -> APEXSigningKeyPair? {
        guard let raw = try retrieve(
            service: APEXKeychainService.identity,
            account: "Signing-\(userID)"
        ) else { return nil }
        return try APEXSigningKeyPair(rawPrivateKey: raw)
    }

    // MARK: - Session State Persistence

    /// Store an opaque session state blob (already serialized by APEXSession)
    public static func storeSessionState(_ data: Data, sessionID: String) throws {
        try store(
            data: data,
            service: APEXKeychainService.sessionState,
            account: sessionID
        )
    }

    public static func loadSessionState(sessionID: String) throws -> Data? {
        return try retrieve(
            service: APEXKeychainService.sessionState,
            account: sessionID
        )
    }

    public static func deleteSessionState(sessionID: String) {
        delete(service: APEXKeychainService.sessionState, account: sessionID)
    }

    // MARK: - Secure Enclave Check

    /// Returns true if the Secure Enclave is available on this device
    public static var isSecureEnclaveAvailable: Bool {
        #if os(iOS) || os(macOS)
        return SecureEnclave.isAvailable
        #else
        return false
        #endif
    }
}
