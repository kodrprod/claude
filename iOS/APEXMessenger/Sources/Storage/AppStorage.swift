import Foundation
import APEX

// MARK: - AppStorage
// Persists conversations and messages to the app's Documents directory.
// In production replace with Core Data or SQLite for large message volumes.

final class AppStorage {
    static let shared = AppStorage()
    private let fm = FileManager.default
    private lazy var root: URL = {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("APEXMessenger", isDirectory: true)
    }()

    private init() {
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - Identity

    func saveIdentity(_ stored: StoredIdentity) throws {
        let data = try JSONEncoder().encode(stored)
        try data.write(to: root.appendingPathComponent("identity.json"), options: .atomic)
    }

    func loadIdentity() -> StoredIdentity? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("identity.json")) else {
            return nil
        }
        return try? JSONDecoder().decode(StoredIdentity.self, from: data)
    }

    func deleteIdentity() {
        try? fm.removeItem(at: root.appendingPathComponent("identity.json"))
    }

    // MARK: - Conversations

    func saveConversations(_ conversations: [Conversation]) throws {
        let data = try JSONEncoder().encode(conversations)
        try data.write(to: root.appendingPathComponent("conversations.json"), options: .atomic)
    }

    func loadConversations() -> [Conversation] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("conversations.json")),
              let list = try? JSONDecoder().decode([Conversation].self, from: data)
        else { return [] }
        return list
    }

    // MARK: - Messages

    private func messagesURL(for conversationID: UUID) -> URL {
        root.appendingPathComponent("messages-\(conversationID.uuidString).json")
    }

    func saveMessages(_ messages: [Message], for conversationID: UUID) throws {
        let data = try JSONEncoder().encode(messages)
        try data.write(to: messagesURL(for: conversationID), options: .atomic)
    }

    func loadMessages(for conversationID: UUID) -> [Message] {
        guard let data = try? Data(contentsOf: messagesURL(for: conversationID)),
              let list = try? JSONDecoder().decode([Message].self, from: data)
        else { return [] }
        return list
    }

    // MARK: - Pre-key bundle (own, serialised for upload to server)

    func saveBundleData(_ data: Data) throws {
        try data.write(to: root.appendingPathComponent("own_bundle.json"), options: .atomic)
    }

    func loadBundleData() -> Data? {
        try? Data(contentsOf: root.appendingPathComponent("own_bundle.json"))
    }
}
