# APEX Protocol Specification
## Adaptive Privacy Exchange Protocol — Version 1.0

---

## Abstract

APEX (Adaptive Privacy Exchange Protocol) is a novel end-to-end encryption protocol
designed for secure messaging on Apple platforms. It combines proven cryptographic
building blocks — Extended Triple Diffie-Hellman (X3DH), Double Ratchet, and
HKDF-SHA-512 — with modern enhancements including post-quantum hybrid key
encapsulation (ML-KEM-768), Sealed Sender metadata protection, and an Adaptive
Ratchet mechanism for on-demand forward secrecy escalation.

APEX is implemented natively in Swift using Apple's CryptoKit framework and
integrates with the Secure Enclave for hardware-backed identity key storage.

---

## 1. Design Goals

| Goal | Mechanism |
|------|-----------|
| End-to-end encryption | AES-256-GCM via Double Ratchet |
| Forward secrecy | Double Ratchet symmetric ratchet (per-message keys) |
| Break-in recovery | Double Ratchet DH ratchet (new keys on each reply direction) |
| Mutual authentication | X3DH with Ed25519 identity signing |
| Deniability | No long-term signatures on message content |
| Post-quantum security | ML-KEM-768 hybrid with X25519 |
| Metadata protection | Sealed Sender (server cannot see who sent each message) |
| Adaptive security | Force extra DH ratchet step for high-value messages |
| Apple platform native | CryptoKit, Secure Enclave, Keychain, Swift concurrency |
| Key transparency | Human-verifiable safety numbers |

---

## 2. Cryptographic Primitives

```
Key Exchange (classical):  X25519 (Curve25519 ECDH)
Key Exchange (PQ hybrid):  ML-KEM-768 (CRYSTALS-Kyber, FIPS 203)
Signatures:                Ed25519 (Curve25519 signing)
Symmetric encryption:      AES-256-GCM (AEAD)
Hash function:             SHA-512
Key derivation:            HKDF-SHA-512
Message authentication:    HMAC-SHA-512
Key storage:               Apple Keychain + Secure Enclave
```

All HKDF operations use **SHA-512** (not SHA-256) for a larger security margin.
Domain separation is enforced via unique info strings for every HKDF context.

---

## 3. Key Material

### 3.1 Identity Keys (long-term, per device)

```
IK    — Curve25519 key agreement key pair   (used in X3DH DH computations)
IK_sig — Ed25519 signing key pair           (signs SPK, proves ownership of IK)
```

Identity keys are stored in the **Secure Enclave** when available (iOS/macOS),
falling back to the Keychain with device-bound `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

### 3.2 Signed Pre-Key (medium-term, rotated weekly)

```
SPK   — Curve25519 key pair
SPK_sig — Ed25519 signature over (version || SPKID || SPK.publicKey)
         signed by IK_sig.privateKey
```

Rotation interval: 7 days (configurable; high-security profile uses 24 hours).

### 3.3 One-Time Pre-Keys (single use)

```
OPK_i — Curve25519 key pair, generated in batches of 100
```

Each OPK is consumed at most once. When the pool drops below a threshold (default: 20),
the app uploads a fresh batch of public keys to the server.

### 3.4 Post-Quantum Pre-Keys (ML-KEM-768)

```
PQPK_i — ML-KEM-768 key pair (public key: 1184 bytes, private key: 2400 bytes)
```

Generated in batches of 10. Consumed during session initiation when available.

---

## 4. X3DH Key Agreement

APEX uses **Extended Triple Diffie-Hellman (X3DH)** for asynchronous key agreement.

### 4.1 Pre-Key Bundle (Bob's public material)

```
Bundle = {
  IK_B.public          // Identity DH key
  IK_B_sig.public      // Identity signing key
  SPKID_B              // Signed pre-key ID
  SPK_B.public         // Signed pre-key
  SPK_B_sig            // Ed25519 signature (by IK_B_sig) over SPK
  OTPKID_B (optional)  // One-time pre-key ID
  OPK_B.public (opt.)  // One-time pre-key
  PQPKID_B (optional)  // PQ pre-key ID
  PQPK_B.public (opt.) // ML-KEM-768 public key (1184 bytes)
}
```

### 4.2 Session Initiation (Alice → Bob)

**Step 1: Verify SPK signature**
```
message = version (1B) || SPKID_B (4B BE) || SPK_B.publicKey (32B)
verify: IK_B_sig.public.isValidSignature(SPK_B_sig, for: message)
```

**Step 2: Generate ephemeral key pair**
```
EK_A = Curve25519.KeyAgreement.PrivateKey()
```

**Step 3: PQ encapsulation (if PQPK_B present)**
```
(PQ_CT, PQ_SS) = ML-KEM-768.Encapsulate(PQPK_B.public)
```

**Step 4: Classical DH computations**
```
DH1 = X25519(IK_A.private,  SPK_B.public)    // auth: Alice's identity
DH2 = X25519(EK_A.private,  IK_B.public)     // auth: Bob's identity
DH3 = X25519(EK_A.private,  SPK_B.public)    // forward secrecy
DH4 = X25519(EK_A.private,  OPK_B.public)    // one-time (if available)
```

**Step 5: Derive shared secret**
```
IKM = DH1 || DH2 || DH3 [|| DH4]

// Hybrid PQ combination (if PQ layer present):
IKM = HKDF-SHA512(IKM || PQ_SS, salt=SHA512(APEX_v1_PQHybrid), info=APEX_v1_PQHybrid)

SK = HKDF-SHA512(IKM, salt=0xFF×32, info="APEX_v1_X3DH", L=32)
```

**Step 6: Associated Data**
```
AD = IK_A.publicKey.rawRepresentation || IK_B.publicKey.rawRepresentation
```

AD is bound into every subsequent AEAD operation, cryptographically tying
all messages in the session to the X3DH authentication.

**Alice sends Bob:**
```
PreKeyMessage = {
  version = 1
  IK_A.public      (32B)
  EK_A.public      (32B)
  usedSPKID        (4B)
  usedOTPKID       (4B, optional)
  PQ_CT            (1088B, optional)
  usedPQPKID       (4B, optional)
  first_encrypted_message
  registrationID   (2B)
}
```

### 4.3 Session Receipt (Bob's side)

Bob mirrors Alice's DH computations in the same order:
```
DH1 = X25519(SPK_B.private, IK_A.public)
DH2 = X25519(IK_B.private,  EK_A.public)
DH3 = X25519(SPK_B.private, EK_A.public)
DH4 = X25519(OPK_B.private, EK_A.public)   (if OPK was used)

PQ_SS = ML-KEM-768.Decapsulate(PQPK_B.private, PQ_CT)   (if PQ was used)
```

Bob then derives the same SK via the same HKDF chain. The one-time pre-key
is **permanently deleted** after this operation.

---

## 5. Double Ratchet Algorithm

APEX uses the **Double Ratchet Algorithm** for all ongoing message encryption.

### 5.1 State

```
DHs    — Our current sending DH ratchet key pair
DHr    — Their current receiving DH ratchet public key
RK     — 32-byte root key
CKs    — Sending chain key (32 bytes)
CKr    — Receiving chain key (32 bytes)
Ns     — Sending message counter
Nr     — Receiving message counter
PN     — Previous sending chain length
MKSKIPPED — {(DHr_fingerprint, N) → MessageKey}  // out-of-order cache
```

### 5.2 Chain Key KDF (Symmetric Ratchet)

Each message advances the chain key and derives a fresh message key:

```
MessageKey  = HMAC-SHA512(CK, 0x01)[0:32]
NewChainKey = HMAC-SHA512(CK, 0x02)[0:32]
```

This ensures **forward secrecy**: deleting MessageKey after decryption makes
past messages irrecoverable even if current state is compromised.

### 5.3 Root Chain KDF (DH Ratchet)

When the receiving DH public key changes (new ratchet key from peer):

```
(NewRK, NewCK) = HKDF-SHA512(
    inputKeyMaterial = DH(ourPrivate, theirNewPublic),
    salt             = currentRootKey,
    info             = "APEX_v1_RootChain",
    L                = 64          // 32B new root key + 32B new chain key
)
```

This provides **break-in recovery**: new DH keys after compromise restore secrecy.

### 5.4 Message Key Expansion

Each 32-byte message key is expanded into an AES-256-GCM key + deterministic nonce:

```
expanded = HKDF-SHA512(
    inputKeyMaterial = MessageKey,
    salt             = messageIndex (8B BE),
    info             = "APEX_v1_MessageKey",
    L                = 44            // 32B enc key + 12B nonce
)
EncKey = expanded[0:32]
Nonce  = expanded[32:44]
```

### 5.5 AEAD Encryption

```
AAD        = AD (from X3DH) || RatchetHeader.wireEncoding || callerAdditionalData
Ciphertext = AES-256-GCM.Seal(plaintext, key=EncKey, nonce=Nonce, aad=AAD)
```

The AAD binds the ratchet header and X3DH authentication into every ciphertext.

### 5.6 Ratchet Header Wire Format

```
DHPublicKey (32B) || PreviousChainLength (4B BE) || MessageIndex (4B BE)
```

### 5.7 Out-of-Order Message Handling

Skipped message keys are cached with a 1000-message window limit.
Cache entries are keyed by `(DHr_fingerprint, messageIndex)` and cleared
after successful use.

---

## 6. APEX Adaptive Ratchet (Novel Extension)

**Problem:** Standard Double Ratchet performs a DH ratchet step only when
the communication direction changes. Long one-way bursts accumulate messages
under the same DH epoch.

**APEX solution:** Any message can be flagged as `highSecurity`, which forces
an **immediate DH ratchet step** before encryption, regardless of direction.

```swift
session.send(plaintext: sensitiveData, highSecurity: true, ...)
```

Internally:
```
NewDHs = Curve25519.KeyAgreement.PrivateKey()   // fresh ratchet key pair
(RK, CKs) = KDF_RK(RK, X25519(NewDHs.priv, DHr))
Ns = 0  // reset sending counter
```

Use cases: key rotation acknowledgments, financial transactions, medical data,
location sharing, content that should have maximum forward secrecy.

---

## 7. Sealed Sender (Metadata Protection)

**Problem:** Even with E2E encryption, the delivery server knows the sender and
recipient of every message (from transport headers).

**APEX Sealed Sender** hides the sender identity from the server. The server
knows only the recipient (for routing), not the sender.

### 7.1 Sealing (sender side)

```
EK_S      = Curve25519.KeyAgreement.PrivateKey()    // ephemeral per-message key
SS        = X25519(EK_S.priv, IK_R.pub)              // DH with recipient's identity
SK_seal   = HKDF-SHA512(SS, info="APEX_v1_SealedSender", L=32)
Nonce     = Random(12 bytes)
Plaintext = SenderCertificate || InnerMessage
Ciphertext = AES-256-GCM.Seal(Plaintext, key=SK_seal, nonce=Nonce)
Container  = EK_S.public || Nonce || Ciphertext
```

### 7.2 Unsealing (recipient side)

```
SS       = X25519(IK_R.priv, EK_S.pub)
SK_seal  = HKDF-SHA512(SS, info="APEX_v1_SealedSender", L=32)
Plaintext = AES-256-GCM.Open(Ciphertext, key=SK_seal)
→ SenderCertificate + InnerMessage
```

### 7.3 Sender Certificate

```
SenderCertificate = {
  senderIdentityKey      (32B)
  senderRegistrationID   (2B)
  expiresAt              (8B UTC epoch seconds)
  senderServerID         (opaque server-assigned string)
  signature              (64B Ed25519 over above fields)
}
```

The certificate is signed by the sender's Ed25519 signing key, providing
authentication without requiring the server to know the sender.

---

## 8. Message Format (Wire Protocol)

```
APEXEnvelope                      (outer, server sees recipient + type)
├── version: UInt8
├── recipientID: String
├── envelopeType: UInt8
└── sealedContent: Data           (AES-GCM encrypted by Sealed Sender)
    └── APEXSealedSenderContainer
        ├── ephemeralPublicKey: Data (32B)
        └── sealedCiphertext: Data
            └── SealedSenderInner
                ├── SenderCertificate
                └── InnerMessageData
                    ├── APEXPreKeyMessage (first message only)
                    │   ├── senderIdentityKey (32B)
                    │   ├── senderEphemeralKey (32B)
                    │   ├── usedSignedPreKeyID (4B)
                    │   ├── usedOneTimePreKeyID (4B, opt.)
                    │   ├── pqCiphertext (1088B, opt.)
                    │   └── APEXEncryptedMessage
                    └── APEXEncryptedMessage (subsequent messages)
                        ├── version (1B)
                        ├── APEXRatchetHeader
                        │   ├── dhPublicKey (32B)
                        │   ├── previousChainLength (4B)
                        │   └── messageIndex (4B)
                        └── ciphertext (AES-256-GCM output)
                            └── APEXDataMessage (plaintext)
                                ├── messageID (UUID)
                                ├── timestamp (ms)
                                ├── contentType (MIME)
                                ├── body (raw bytes)
                                ├── replyToID (opt.)
                                └── expiresInSeconds (opt.)
```

---

## 9. Post-Quantum Hybrid KEM

APEX uses a **hybrid KEM** combining classical X25519 with ML-KEM-768.

**Security guarantee:** The combined session key is secure if **either**
X25519 **or** ML-KEM-768 is secure. A quantum computer breaking X25519
cannot break the session if ML-KEM-768 remains secure.

### 9.1 Combination Function

```
HybridSecret = HKDF-SHA512(
    inputKeyMaterial = ClassicalSecret || PQSecret,
    salt             = SHA512("APEX_v1_PQHybrid"),
    info             = "APEX_v1_PQHybrid",
    L                = 32
)
```

### 9.2 Platform Availability

| Platform | ML-KEM-768 Support |
|----------|--------------------|
| iOS 17+  | Yes (via CryptoKit) |
| macOS 14+ | Yes |
| watchOS 10+ | Yes |
| Older platforms | Fallback to X25519 simulation |

The fallback (`APEXSimulatedKEM`) uses X25519 ECDH to provide the same API
surface; it is not quantum-resistant but maintains the classical security level.

---

## 10. Security Analysis

### 10.1 Security Properties

| Property | Provided | Mechanism |
|----------|----------|-----------|
| Confidentiality | Yes | AES-256-GCM, Double Ratchet |
| Integrity | Yes | AES-GCM authentication tag |
| Forward Secrecy | Yes | Per-message keys derived and deleted |
| Break-in Recovery | Yes | DH ratchet step on each direction change |
| Post-Quantum Confidentiality | Yes (iOS 17+) | ML-KEM-768 hybrid |
| Authentication | Yes | Ed25519 identity signing, X3DH |
| Deniability | Yes | No signing of message content |
| Replay Protection | Yes | AES-GCM nonce + message index in AAD |
| Sender Anonymity | Yes | Sealed Sender |
| Out-of-Order Delivery | Yes | Skipped message key cache |

### 10.2 Trust Model

- **Server**: Untrusted. Server cannot read message content or sender identity.
- **Key Server**: Semi-trusted. Man-in-the-middle prevention via safety numbers.
- **Device**: Trusted. Secure Enclave protects identity keys from extraction.

### 10.3 Threat Model

| Threat | Mitigation |
|--------|------------|
| Network eavesdropper | AES-256-GCM encryption |
| Server compromise | E2E encryption, sealed sender |
| Quantum computer (future) | ML-KEM-768 hybrid |
| Session key compromise | Double Ratchet break-in recovery |
| Historical record | Forward secrecy (per-message keys deleted) |
| Man-in-the-middle | Safety numbers, key transparency |
| Replay attack | AEAD nonce + message counter in AD |
| Device theft | Secure Enclave + device PIN |

---

## 11. Apple Platform Optimizations

### 11.1 CryptoKit Integration

All cryptographic operations use Apple's `CryptoKit` framework:
- Hardware acceleration on Apple Silicon (A-series, M-series)
- Constant-time implementations for side-channel resistance
- Memory-safe Swift types with automatic zeroing

### 11.2 Secure Enclave

Identity keys can be generated in and bound to the Secure Enclave:
- Private key never leaves the secure hardware
- Operations performed inside the enclave
- Keys survive app reinstall but not device restore

### 11.3 Keychain Storage

- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — identity keys
- `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — session/chain keys
- Device-bound: keys cannot be migrated to other devices

### 11.4 Multi-Platform Support

```
iOS 16+       — Full support (PQ requires iOS 17+)
macOS 13+     — Full support (PQ requires macOS 14+)
watchOS 9+    — Full support
tvOS 16+      — Full support
visionOS 1+   — Full support
```

---

## 12. Integration Guide

### 12.1 One-Time Setup

```swift
import APEX

// 1. Create identity (stored in Keychain/Secure Enclave)
let myIdentity = try APEX.createIdentity()

// 2. Create sender certificate (signed by server in production)
let myCert = try APEX.createSenderCertificate(
    identity: myIdentity,
    serverID: "user@example.com"
)

// 3. Upload public pre-key bundle to your server
let bundle = APEX.makePublicBundle(from: myIdentity)
let bundleData = try APEX.encodeBundle(bundle)
await yourServer.uploadPreKeyBundle(bundleData)

// 4. Upload one-time pre-keys
let otpks = APEX.generateOneTimePreKeyPublicKeys(from: myIdentity)
await yourServer.uploadOneTimePreKeys(otpks)
```

### 12.2 Sending First Message

```swift
// Fetch recipient's bundle from your server
let bundleData = await yourServer.fetchPreKeyBundle(for: "bob@example.com")
let bobBundle = try APEX.decodeBundle(from: bundleData)

// Create session
let session = APEX.createSession(identity: myIdentity, certificate: myCert)

// Encrypt and send
let result = try session.initiateSession(
    plaintext: "Hello!".data(using: .utf8)!,
    recipientBundle: bobBundle,
    recipientID: "bob@example.com"
)

let envelopeData = try APEX.encodeEnvelope(result.envelope)
await yourServer.deliver(envelopeData, to: "bob@example.com")
```

### 12.3 Receiving Messages

```swift
let session = APEX.createSession(identity: myIdentity, certificate: myCert)

let envelopeData = await yourServer.fetchNextMessage()
let envelope = try APEX.decodeEnvelope(from: envelopeData)
let received = try session.receive(envelope: envelope)

let text = String(data: received.dataMessage.body, encoding: .utf8)!
print("From: \(received.senderCertificate.senderServerID)")
print("Message: \(text)")
```

### 12.4 Safety Number Verification

```swift
// Display to user for out-of-band verification
let sn = APEX.safetyNumber(
    localIdentityKey: myIdentity.identityKeyPair.publicKey,
    remoteIdentityKey: contactIdentityKey
)
// Show sn to user, have them verify it with contact via voice/in-person
```

---

## 13. Comparison with Existing Protocols

| Feature | Signal Protocol | TLS 1.3 | iMessage PQ3 | **APEX** |
|---------|----------------|---------|--------------|----------|
| Forward secrecy | Yes | Yes | Yes | Yes |
| Break-in recovery | Yes | No | Yes | Yes |
| Post-quantum | PQXDH | Partial | ML-KEM | ML-KEM-768 |
| Sealed sender | Yes | No | No | Yes |
| Adaptive ratchet | No | No | No | **Yes** |
| Apple-native impl | No | OS layer | Yes | **Yes** |
| Secure Enclave | No | No | Yes | **Yes** |
| Open spec | Yes | Yes | Partial | **Yes** |

The key APEX innovations over Signal Protocol:
1. **Hybrid post-quantum** from session establishment (not retrofitted)
2. **Adaptive Ratchet** — demand-driven extra DH step for high-value messages
3. **Native Apple CryptoKit** throughout — hardware acceleration included
4. **Secure Enclave** identity key binding — keys cannot be extracted

---

## 14. Known Limitations & Future Work

1. **Group messaging**: APEX v1 is point-to-point only. Group support (Sender Keys
   or Multi-Party Computation) is planned for v2.

2. **Key transparency**: Safety numbers provide manual verification. Integration
   with an auditable key transparency log (like Apple's KT) is planned.

3. **Sealed sender decoys**: Traffic analysis resistance via decoy messages is
   not yet implemented.

4. **PQ per-message keys**: ML-KEM-768 is used only at session establishment.
   Per-message PQ primitives (e.g. XMSS) are not yet incorporated.

5. **Multi-device**: Device-linking protocol for syncing sessions across multiple
   Apple devices (iPhone, Mac, Apple Watch) is planned for v1.1.

---

## 15. References

1. Marlinspike, M. & Perrin, T. — "The X3DH Key Agreement Protocol" (2016)
2. Marlinspike, M. & Perrin, T. — "The Double Ratchet Algorithm" (2016)
3. NIST FIPS 203 — "ML-KEM (CRYSTALS-Kyber)" (2024)
4. Apple Security Research — "iMessage with PQ3" (2024)
5. Signal Blog — "PQXDH: Post-Quantum Extended Diffie-Hellman" (2023)
6. RFC 5869 — "HMAC-based Extract-and-Expand KDF (HKDF)"
7. Apple CryptoKit Documentation — developer.apple.com/documentation/cryptokit

---

*APEX Protocol v1.0 — For integration into Apple-platform secure messaging applications.*
*This specification is the authoritative reference for the APEX Swift implementation.*
