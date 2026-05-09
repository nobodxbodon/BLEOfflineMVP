//
//  MessageStore.swift
//  BLEOfflineMVP
//
//  Created by MD Aminuzzaman on 4/23/26.
//

import Foundation

// MARK: - Message Store

/// Lightweight JSON-based persistence for messages.
/// Stores all messages (sent, queued, received) in a single JSON file
/// in the app's Documents directory.
final class MessageStore {

    // MARK: - Properties

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // MARK: - Initialization

    init(filename: String = "messages.json") {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.fileURL = docs.appendingPathComponent(filename)

        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - CRUD

    /// Load all persisted messages in insertion order.
    func loadMessages() -> [Message] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([Message].self, from: data)
        } catch {
            print("[MessageStore] Failed to load: \(error.localizedDescription)")
            return []
        }
    }

    /// Persist the full message array to disk.
    func saveMessages(_ messages: [Message]) {
        do {
            let data = try encoder.encode(messages)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[MessageStore] Failed to save: \(error.localizedDescription)")
        }
    }

    /// Append a single message if it doesn't already exist (dedup by id).
    func appendMessage(_ message: Message) -> [Message] {
        var messages = loadMessages()
        guard !messages.contains(where: { $0.id == message.id }) else {
            return messages
        }
        messages.append(message)
        saveMessages(messages)
        return messages
    }

    /// Update the status of a message by id.
    func updateStatus(id: UUID, to status: Message.发送状态) -> [Message] {
        var messages = loadMessages()
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].状态 = status
            saveMessages(messages)
        }
        return messages
    }

    /// Update status for multiple message ids at once.
    func updateStatuses(ids: [UUID], to status: Message.发送状态) -> [Message] {
        var messages = loadMessages()
        let idSet = Set(ids)
        for i in messages.indices where idSet.contains(messages[i].id) {
            messages[i].状态 = status
        }
        saveMessages(messages)
        return messages
    }

    /// Return only messages with `.queued` status (outbox).
    func queuedMessages() -> [Message] {
        return loadMessages().filter { $0.状态 == .queued }
    }
}
