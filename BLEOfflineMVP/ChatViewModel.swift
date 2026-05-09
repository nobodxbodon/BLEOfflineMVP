//
//  ChatViewModel.swift
//  BLEOfflineMVP
//
//  Created by MD Aminuzzaman on 4/23/26.
//

import Foundation
import Combine

// MARK: - Chat View Model

/// Central coordinator for the messaging feature.
/// Manages the in-memory messages array as the single source of truth,
/// persists to disk on every change, and handles the
/// compose → queue → send → receive → display flow.
@MainActor
final class ChatViewModel: ObservableObject {

    // MARK: - Published UI State

    /// All messages, always sorted chronologically (oldest first → newest last).
    @Published var messages: [Message] = []
    @Published var composeText: String = ""
    @Published private(set) var connectionState: ConnectivityService.ConnectionState = .idle
    @Published private(set) var connectedPeerCount: Int = 0

    // MARK: - Dependencies

    let connectivity: ConnectivityService
    private let store: MessageStore
    private var cancellables = Set<AnyCancellable>()

    /// Set of message IDs we already have, for O(1) dedup.
    private var knownMessageIDs: Set<UUID> = []

    /// Ack tracking for resend.
    private var ackWaitTasks: [UUID: Task<Void, Never>] = [:]

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Init

    init() {
        self.connectivity = ConnectivityService()
        self.store = MessageStore()

        // Load persisted messages (already sorted oldest-first by store)
        let loaded = store.loadMessages()
        self.messages = loaded
        self.knownMessageIDs = Set(loaded.map(\.id))

        setupObservers()
        connectivity.start()
    }

    // MARK: - Observers

    private func setupObservers() {
        // Track connection state
        connectivity.$connectionState
            .receive(on: DispatchQueue.main)
            .assign(to: &$connectionState)

        // Track peer count
        connectivity.$connectedPeers
            .receive(on: DispatchQueue.main)
            .map(\.count)
            .assign(to: &$connectedPeerCount)

        // When peers connect → flush outbox
        connectivity.$connectedPeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peers in
                if !peers.isEmpty {
                    self?.flushOutbox()
                    self?.resumePendingDeliveries()
                }
            }
            .store(in: &cancellables)

        // Incoming data → decode and display
        connectivity.dataReceived
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data, _ in
                self?.handleReceivedData(data)
            }
            .store(in: &cancellables)
    }

    // MARK: - In-Memory Array Helpers

    /// Insert a message into the array at the correct chronological position.
    /// Returns true if the message was new, false if it was a duplicate.
    @discardableResult
    private func insertMessage(_ message: Message) -> Bool {
        // Dedup
        guard !knownMessageIDs.contains(message.id) else { return false }

        knownMessageIDs.insert(message.id)
        messages.append(message)
        persistToDisk()
        return true
    }

    /// Update status of a message in-place without re-reading from disk.
    private func updateMessageStatus(id: UUID, to status: Message.DeliveryStatus) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].status = status
            persistToDisk()
        }
    }

    /// Save current in-memory messages to disk (fire-and-forget).
    private func persistToDisk() {
        store.saveMessages(messages)
    }

    // MARK: - Compose & Send

    /// Called when the user taps "Send".
    func sendMessage() {
        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let message = Message(
            text: text,
            senderName: connectivity.displayName,
            isMine: true,
            status: .queued
        )

        composeText = ""

        // Add to in-memory array
        insertMessage(message)

        // Attempt immediate send if peers are connected
        if connectedPeerCount > 0 {
            sendOverWire(message)
        }
    }

    // MARK: - Outbox Flush

    /// Send all queued messages to connected peers.
    private func flushOutbox() {
        // Only flush truly queued. "sent" will be handled by ACK retry loop.
        let queued = messages.filter { $0.isMine && $0.status == .queued }
        guard !queued.isEmpty else { return }

        print("[Chat] Flushing \(queued.count) queued message(s)")

        for message in queued {
            sendOverWire(message)
        }
    }

    private func resumePendingDeliveries() {
        // If we reconnected after a while, previously "sent" (but un-ACK'd) messages
        // must re-enter the retry loop; otherwise they can remain stuck at a green check.
        let pending = messages.filter { $0.isMine && ($0.status == .sent || $0.status == .queued) }
        guard !pending.isEmpty else { return }

        for message in pending {
            if message.status == .queued {
                sendOverWire(message)
            } else {
                ensureAckWaitTask(for: message.id)
            }
        }
    }

    /// Encode and send a single message over BLE, then mark as sent.
    private func sendOverWire(_ message: Message) {
        let packet = WirePacket.message(MessagePayload(from: message))

        Task {
            do {
                let data = try encoder.encode(packet)
                try await connectivity.sendToAll(data)

                // Mark as sent in-memory
                await MainActor.run {
                    self.updateMessageStatus(id: message.id, to: .sent)
                }
                print("[Chat] Sent: \(message.text)")

                ensureAckWaitTask(for: message.id)
            } catch {
                // Keep queued; it will be retried on next connect / flush.
                print("[Chat] Send failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Receive

    /// Decode incoming data and add to inbox.
    private func handleReceivedData(_ data: Data) {
        do {
            let packet = try decoder.decode(WirePacket.self, from: data)
            switch packet {
            case .message(let payload):
                let message = payload.toMessage()
                if insertMessage(message) {
                    print("[Chat] Received: \(message.text) from \(message.senderName)")
                }
                sendAck(for: payload.id)

            case .ack(let id):
                ackWaitTasks[id]?.cancel()
                ackWaitTasks[id] = nil
                updateMessageStatus(id: id, to: .delivered)
            }
        } catch {
            print("[Chat] Failed to decode received data: \(error.localizedDescription)")
        }
    }

    private func sendAck(for messageID: UUID) {
        let packet = WirePacket.ack(messageID)
        Task {
            do {
                let data = try encoder.encode(packet)
                try await connectivity.sendToAll(data)
            } catch {
                // Best-effort; sender will retry if ack not received.
            }
        }
    }

    private func ensureAckWaitTask(for messageID: UUID) {
        // Don’t create multiple retry loops for the same message.
        if ackWaitTasks[messageID] != nil { return }

        ackWaitTasks[messageID] = Task { [weak self] in
            guard let self else { return }

            // Keep retrying (with gentle backoff) until ACK arrives or the message disappears.
            // Receiver dedups by UUID, so resends are safe.
            let delays: [UInt64] = [
                4_000_000_000,
                6_000_000_000,
                10_000_000_000,
                15_000_000_000
            ]

            var attempt = 0
            while !Task.isCancelled {
                let delay = delays[min(attempt, delays.count - 1)]
                try? await Task.sleep(nanoseconds: delay)

                if Task.isCancelled { return }
                guard let msg = self.messages.first(where: { $0.id == messageID }) else { return }
                if msg.status == .delivered { return }

                guard self.connectedPeerCount > 0 else {
                    attempt += 1
                    continue
                }

                do {
                    let packet = WirePacket.message(MessagePayload(from: msg))
                    let data = try self.encoder.encode(packet)
                    try await self.connectivity.sendToAll(data)
                } catch {
                    // Ignore; we'll retry again (or on reconnect via resumePendingDeliveries()).
                }

                attempt += 1
            }
        }
    }
}
