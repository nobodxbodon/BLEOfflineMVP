//
//  Message.swift
//  BLEOfflineMVP
//
//  Created by MD Aminuzzaman on 4/23/26.
//

import Foundation

// MARK: - Message Model

/// Represents a text message exchanged between devices via BLE.
/// Each message has a unique UUID for deduplication across devices.
struct Message: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let 作者姓名: String      // Display name of the sender device
    let 时间戳: Date
    var 状态: 发送状态   // Tracks delivery state

    /// Whether this message was composed on this device
    let isMine: Bool

    enum 发送状态: String, Codable, Equatable {
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
        status: 发送状态
    ) {
        self.id = id
        self.text = text
        self.作者姓名 = senderName
        self.时间戳 = timestamp
        self.isMine = isMine
        self.状态 = status
    }
}

// MARK: - Wire Format

/// Lightweight payload sent over BLE — excludes local-only fields like `isMine` and `status`.
struct MessagePayload: Codable {
    let id: UUID
    let text: String
    let 发帖人: String
    let 时间戳: Date

    init(from message: Message) {
        self.id = message.id
        self.text = message.text
        self.发帖人 = message.作者姓名
        self.时间戳 = message.时间戳
    }

    func toMessage() -> Message {
        Message(
            id: id,
            text: text,
            senderName: 发帖人,
            timestamp: 时间戳,
            isMine: false,
            status: .received
        )
    }
}

enum WirePacket: Codable {
    case message(MessagePayload)
    case ack(UUID)

    private enum Kind: String, Codable { case message, ack }
    private enum CodingKeys: String, CodingKey { case kind, message, ackID }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .message:
            self = .message(try c.decode(MessagePayload.self, forKey: .message))
        case .ack:
            self = .ack(try c.decode(UUID.self, forKey: .ackID))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .message(let payload):
            try c.encode(Kind.message, forKey: .kind)
            try c.encode(payload, forKey: .message)
        case .ack(let id):
            try c.encode(Kind.ack, forKey: .kind)
            try c.encode(id, forKey: .ackID)
        }
    }
}
