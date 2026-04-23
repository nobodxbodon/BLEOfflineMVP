//
//  Message.swift
//  BLEOfflineMVP
//
//  Created by MD Aminuzzaman on 4/23/26.
//

import Foundation

// MARK: - Message Model

/// Represents a text message exchanged between devices via MPC.
/// Each message has a unique UUID for deduplication across devices.
struct Message: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let senderName: String      // Display name of the sender device
    let timestamp: Date
    var status: DeliveryStatus   // Tracks delivery state

    /// Whether this message was composed on this device
    let isMine: Bool

    enum DeliveryStatus: String, Codable, Equatable {
        case queued      // Written locally, no peer connected yet
        case sent        // Successfully sent to at least one peer
        case delivered   // Confirmed received (future use)
        case received    // Received from a remote peer
    }

    init(
        id: UUID = UUID(),
        text: String,
        senderName: String,
        timestamp: Date = Date(),
        isMine: Bool,
        status: DeliveryStatus
    ) {
        self.id = id
        self.text = text
        self.senderName = senderName
        self.timestamp = timestamp
        self.isMine = isMine
        self.status = status
    }
}

// MARK: - Wire Format

/// Lightweight payload sent over MPC — excludes local-only fields like `isMine` and `status`.
struct MessagePayload: Codable {
    let id: UUID
    let text: String
    let senderName: String
    let timestamp: Date

    init(from message: Message) {
        self.id = message.id
        self.text = message.text
        self.senderName = message.senderName
        self.timestamp = message.timestamp
    }

    func toMessage() -> Message {
        Message(
            id: id,
            text: text,
            senderName: senderName,
            timestamp: timestamp,
            isMine: false,
            status: .received
        )
    }
}
