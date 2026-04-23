//
//  ContentView.swift
//  BLEOfflineMVP
//
//  Created by MD Aminuzzaman on 4/23/26.
//

import SwiftUI

// MARK: - Main Chat View

struct ContentView: View {
    @EnvironmentObject var viewModel: ChatViewModel

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Message list
                messageList

                Divider()

                // Compose bar
                composeBar
            }
            .navigationTitle("BLE Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ConnectionBadge(state: viewModel.connectionState)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Message List

    private var messageList: some View {
        Group {
            if viewModel.messages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No Messages")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Type a message below.\nIt will be delivered when a peer comes nearby.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(viewModel.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .onAppear {
                        // Scroll to bottom on first appear
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: viewModel.messages.count) { _ in
                        scrollToBottom(proxy: proxy)
                    }
                }
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let last = viewModel.messages.last {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Compose Bar

    private var composeBar: some View {
        HStack(spacing: 10) {
            TextField("Type a message…", text: $viewModel.composeText)
                .textFieldStyle(.roundedBorder)
                .padding(.vertical, 4)

            Button {
                viewModel.sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.blue)
            }
            .disabled(viewModel.composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.isMine { Spacer(minLength: 60) }

            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 4) {
                // Sender name (only for received messages)
                if !message.isMine {
                    Text(message.senderName)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                }

                // Message text
                Text(message.text)
                    .font(.body)
                    .foregroundColor(message.isMine ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        message.isMine
                            ? Color.blue
                            : Color(.systemGray5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                // Timestamp + status
                HStack(spacing: 4) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(.gray)

                    if message.isMine {
                        statusIcon
                    }
                }
            }

            if !message.isMine { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch message.status {
        case .queued:
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundColor(.orange)
        case .sent:
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundColor(.green)
        case .delivered:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.green)
        case .received:
            EmptyView()
        }
    }
}

// MARK: - Connection Badge

struct ConnectionBadge: View {
    let state: ConnectivityService.ConnectionState

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)

            Text(state.displayText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(.systemGray6))
        .clipShape(Capsule())
    }

    private var dotColor: Color {
        switch state {
        case .idle:       return .gray
        case .searching:  return .orange
        case .connecting: return .yellow
        case .connected:  return .green
        case .error:      return .red
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(ChatViewModel())
}
