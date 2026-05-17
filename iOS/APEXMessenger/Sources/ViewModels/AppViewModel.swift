import Foundation
import SwiftUI
import APEX

// MARK: - AppViewModel
// Central state for the app. Owns the APEX identity and all sessions.

@MainActor
final class AppViewModel: ObservableObject {

    // MARK: - Published state

    @Published var identity: APEXIdentity?
    @Published var storedIdentity: StoredIdentity?
    @Published var conversations: [Conversation] = []
    @Published var errorMessage: String?

    // MARK: - Private state

    private var sessions: [UUID: APEXSession] = [:]   // conversationID → session
    private var senderCertificate: APEXSenderCertificate?
    private let storage = AppStorage.shared
    private var pollingTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        loadPersistedState()
    }

    // MARK: - Identity Setup

    func createIdentity(serverID: String, displayName: String) async {
        do {
            let apexIdentity = try APEX.createIdentity()
            let cert = try APEX.createSenderCertificate(identity: apexIdentity, serverID: serverID)

            let stored = StoredIdentity(
                serverID: serverID,
                displayName: displayName,
                registrationID: apexIdentity.registrationID,
                identityKeyData: apexIdentity.identityKeyPair.publicKey.rawRepresentation,
                signingKeyData: apexIdentity.signingKeyPair.publicKey.rawRepresentation,
                signedPreKeyData: apexIdentity.signedPreKey.publicKey.rawRepresentation,
                signedPreKeyID: apexIdentity.signedPreKeyID,
                signedPreKeySignature: apexIdentity.signedPreKeySignature,
                createdAt: Date()
            )

            try storage.saveIdentity(stored)

            let bundleData = try APEX.encodeBundle(APEX.makePublicBundle(from: apexIdentity))
            try storage.saveBundleData(bundleData)

            self.identity = apexIdentity
            self.storedIdentity = stored
            self.senderCertificate = cert

            try await ServerClient.shared.register(
                serverID: serverID,
                displayName: displayName,
                bundleData: bundleData
            )

            startPolling()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Start New Conversation

    func startConversation(with bundle: ReceivedBundle) async {
        do {
            guard let identity = identity,
                  let cert = senderCertificate else { return }

            let peerBundle = try APEX.decodeBundle(from: bundle.bundleData)

            let conversation = Conversation(
                peerServerID: bundle.serverID,
                peerDisplayName: bundle.displayName,
                peerIdentityKeyData: peerBundle.identityKey.rawRepresentation
            )

            let session = APEX.createSession(identity: identity, certificate: cert)
            sessions[conversation.id] = session

            conversations.append(conversation)
            try storage.saveConversations(conversations)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Send Message

    func send(
        text: String,
        in conversationID: UUID,
        highSecurity: Bool = false
    ) async -> Message? {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationID }),
              let identity = identity,
              let cert = senderCertificate
        else { return nil }

        var conv = conversations[idx]

        do {
            let peerBundle = try await ServerClient.shared.fetchBundle(serverID: conv.peerServerID)
            let peerAPEXBundle = try APEX.decodeBundle(from: peerBundle.bundleData)

            let session: APEXSession
            if let existing = sessions[conversationID] {
                session = existing
            } else {
                session = APEX.createSession(identity: identity, certificate: cert)
                sessions[conversationID] = session
            }

            let plaintext = Data(text.utf8)
            let result: APEXSendResult

            if session.status == .uninitialized {
                result = try session.initiateSession(
                    plaintext: plaintext,
                    recipientBundle: peerAPEXBundle,
                    recipientID: conv.peerServerID
                )
                conv.sessionID = session.sessionID
            } else {
                guard let remoteIK = session.remoteIdentityKey else { return nil }
                result = try session.send(
                    plaintext: plaintext,
                    recipientID: conv.peerServerID,
                    recipientIdentityKey: remoteIK,
                    highSecurity: highSecurity
                )
            }

            try await ServerClient.shared.send(envelope: result.envelope)

            var msg = Message(
                conversationID: conversationID,
                body: text,
                isOutgoing: true,
                isHighSecurity: highSecurity
            )
            msg.status = .sent

            conv.lastMessagePreview = text
            conv.lastMessageDate = Date()
            conversations[idx] = conv
            try storage.saveConversations(conversations)

            var messages = storage.loadMessages(for: conversationID)
            messages.append(msg)
            try storage.saveMessages(messages, for: conversationID)

            return msg
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Inbox Polling

    func startPolling() {
        guard let stored = storedIdentity else { return }
        pollingTask?.cancel()
        pollingTask = Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                await self?.pollInbox(serverID: stored.serverID)
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
            }
        }
    }

    private func pollInbox(serverID: String) async {
        guard let identity = identity, let cert = senderCertificate else { return }
        do {
            let envelopes = try await ServerClient.shared.fetchInbox(serverID: serverID)
            for envData in envelopes {
                let envelope = try APEX.decodeEnvelope(from: envData)
                await receive(envelope: envelope, ownIdentity: identity, cert: cert)
            }
        } catch {
            // Silent — polling failures are expected when server is unreachable
        }
    }

    private func receive(
        envelope: APEXEnvelope,
        ownIdentity: APEXIdentity,
        cert: APEXSenderCertificate
    ) async {
        do {
            let recipientID = envelope.recipientID

            // Find or create conversation matching this sender
            let session: APEXSession
            var conv: Conversation?
            var convIdx: Int?

            if let idx = conversations.firstIndex(where: { $0.peerServerID == recipientID }) {
                convIdx = idx
                conv = conversations[idx]
                session = sessions[conversations[idx].id] ?? {
                    let s = APEX.createSession(identity: ownIdentity, certificate: cert)
                    sessions[conversations[idx].id] = s
                    return s
                }()
            } else {
                session = APEX.createSession(identity: ownIdentity, certificate: cert)
                let newConv = Conversation(
                    peerServerID: recipientID,
                    peerDisplayName: recipientID,
                    peerIdentityKeyData: Data()
                )
                conversations.append(newConv)
                sessions[newConv.id] = session
                convIdx = conversations.count - 1
                conv = newConv
            }

            guard let convIdx = convIdx, var conv = conv else { return }

            let result = try session.receive(envelope: envelope)
            let text = String(data: result.dataMessage.body, encoding: .utf8) ?? "(binary)"

            let msg = Message(
                conversationID: conv.id,
                body: text,
                isOutgoing: false
            )

            conv.lastMessagePreview = text
            conv.lastMessageDate = Date()
            conv.unreadCount += 1
            conversations[convIdx] = conv

            var messages = storage.loadMessages(for: conv.id)
            messages.append(msg)
            try storage.saveMessages(messages, for: conv.id)
            try storage.saveConversations(conversations)

        } catch {
            // Decryption failures are logged silently (forward secrecy may cause
            // legitimate failures if the session state diverges)
        }
    }

    // MARK: - Safety Number

    func safetyNumber(for conversation: Conversation) -> String? {
        guard let localIK = identity?.identityKeyPair.publicKey,
              let remoteIK = try? APEXDHPublicKey(rawRepresentation: conversation.peerIdentityKeyData)
        else { return nil }
        return APEX.safetyNumber(localIdentityKey: localIK, remoteIdentityKey: remoteIK)
    }

    // MARK: - Helpers

    func messages(for conversationID: UUID) -> [Message] {
        storage.loadMessages(for: conversationID)
    }

    func markVerified(_ conversationID: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[idx].safetyNumberVerified = true
        try? storage.saveConversations(conversations)
    }

    // MARK: - Persistence restore

    private func loadPersistedState() {
        conversations = storage.loadConversations()
        if let stored = storage.loadIdentity() {
            storedIdentity = stored
            // Full APEX identity is rebuilt from Keychain in production.
            // Here we mark that setup is complete so the UI skips onboarding.
        }
    }
}
