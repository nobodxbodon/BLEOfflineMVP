//
//  ChatViewModel.swift
//  BLEOfflineMVP
//
//  Created by MD Aminuzzaman on 4/23/26.
//

import Foundation
import Combine
import MultipeerConnectivity

// MARK: - Chat View Model

/// Central coordinator for the messaging feature.
/// Owns the connectivity service and message store,
/// handles compose → queue → send → receive → display flow.
@MainActor
final class ChatViewModel: ObservableObject {

    // MARK: - Published UI State

    @Published var messages: [Message] = []
    @Published var composeText: String = ""
    @Published private(set) var connectionState: ConnectivityService.ConnectionState = .idle
    @Published private(set) var connectedPeerCount: Int = 0

    // MARK: - Dependencies

    let connectivity: ConnectivityService
    private let store: MessageStore
    private var cancellables = Set<AnyCancellable>()

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

        // Load persisted messages
        messages = store.loadMessages()

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

        // Persist locally
        messages = store.appendMessage(message)
        composeText = ""

        // Attempt immediate send if peers are connected
        if connectedPeerCount > 0 {
            sendSingleMessage(message)
        }
    }

    // MARK: - Outbox Flush

    /// Send all queued messages to connected peers.
    private func flushOutbox() {
        let queued = messages.filter { $0.isMine && $0.status == .queued }
        guard !queued.isEmpty else { return }

        print("[Chat] Flushing \(queued.count) queued message(s)")

        for message in queued {
            sendSingleMessage(message)
        }
    }

    /// Encode and send a single message over MPC.
    private func sendSingleMessage(_ message: Message) {
        let payload = MessagePayload(from: message)

        do {
            let data = try encoder.encode(payload)
            try connectivity.sendToAll(data)

            // Mark as sent
            messages = store.updateStatus(id: message.id, to: .sent)
            print("[Chat] Sent: \(message.text)")
        } catch {
            print("[Chat] Send failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Receive

    /// Decode incoming data and add to inbox.
    private func handleReceivedData(_ data: Data) {
        do {
            let payload = try decoder.decode(MessagePayload.self, from: data)
            let message = payload.toMessage()

            // Dedup: appendMessage checks by id
            let updated = store.appendMessage(message)

            // Only update UI if message was actually new
            if updated.count != messages.count {
                messages = updated
                print("[Chat] Received: \(message.text) from \(message.senderName)")
            }
        } catch {
            print("[Chat] Failed to decode received data: \(error.localizedDescription)")
        }
    }
}
