//
//  ConnectivityService.swift
//  BLEOfflineMVP
//
//  Adapted from CoreDataSync/MPCService.swift
//  Simplified for text-only messaging MVP.
//
//  Created by MD Aminuzzaman on 4/23/26.
//

import Foundation
import MultipeerConnectivity
import Combine

// MARK: - Connectivity Service

/// Manages MultipeerConnectivity for peer-to-peer text messaging.
/// Both advertises and browses simultaneously so any two devices
/// running this app will auto-discover and auto-connect.
@MainActor
final class ConnectivityService: NSObject, ObservableObject {

    // MARK: - Published State

    @Published private(set) var connectedPeers: [MCPeerID] = []
    @Published private(set) var connectionState: ConnectionState = .idle

    // MARK: - Data Publisher

    /// Emits raw Data received from any connected peer.
    let dataReceived = PassthroughSubject<(Data, MCPeerID), Never>()

    // MARK: - Configuration

    private static let serviceType = "blemvp"   // max 15 chars, lowercase

    private let peerID: MCPeerID
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser!
    private var browser: MCNearbyServiceBrowser!
    private var isAdvertising = false
    private var isBrowsing = false

    // MARK: - Connection State

    enum ConnectionState: Equatable {
        case idle
        case searching
        case connecting
        case connected(peerCount: Int)
        case error(String)

        var displayText: String {
            switch self {
            case .idle:                  return "Offline"
            case .searching:             return "Searching…"
            case .connecting:            return "Connecting…"
            case .connected(let count):  return "\(count) peer\(count == 1 ? "" : "s")"
            case .error(let msg):        return "Error: \(msg)"
            }
        }

        var dotColor: String {
            switch self {
            case .idle:       return "gray"
            case .searching:  return "orange"
            case .connecting: return "yellow"
            case .connected:  return "green"
            case .error:      return "red"
            }
        }
    }

    // MARK: - Init

    override init() {
        self.peerID = MCPeerID(displayName: UIDevice.current.name)
        super.init()
        setupSession()
        setupAdvertiser()
        setupBrowser()
    }

    // MARK: - Setup

    private func setupSession() {
        session = MCSession(
            peer: peerID,
            securityIdentity: nil,
            encryptionPreference: .none    // No encryption per MVP requirement
        )
        session.delegate = self
    }

    private func setupAdvertiser() {
        advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: nil,
            serviceType: Self.serviceType
        )
        advertiser.delegate = self
    }

    private func setupBrowser() {
        browser = MCNearbyServiceBrowser(
            peer: peerID,
            serviceType: Self.serviceType
        )
        browser.delegate = self
    }

    // MARK: - Public Controls

    /// Start advertising and browsing for peers.
    func start() {
        guard !isAdvertising, !isBrowsing else { return }
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        isAdvertising = true
        isBrowsing = true
        connectionState = .searching
        print("[MPC] Started advertising + browsing")
    }

    /// Stop all MPC operations.
    func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        isAdvertising = false
        isBrowsing = false
        connectedPeers = []
        connectionState = .idle
        print("[MPC] Stopped")
    }

    // MARK: - Send Data

    /// Send data to all connected peers with reliable delivery.
    func sendToAll(_ data: Data) throws {
        guard !connectedPeers.isEmpty else {
            throw ConnectivityError.noPeersConnected
        }
        try session.send(data, toPeers: connectedPeers, with: .reliable)
    }

    enum ConnectivityError: LocalizedError {
        case noPeersConnected

        var errorDescription: String? {
            switch self {
            case .noPeersConnected: return "No peers connected"
            }
        }
    }

    // MARK: - Helpers

    /// The display name of this device (used as sender name).
    var displayName: String { peerID.displayName }
}

// MARK: - MCSessionDelegate

extension ConnectivityService: MCSessionDelegate {

    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            handleStateChange(peer: peerID, state: state)
        }
    }

    @MainActor
    private func handleStateChange(peer: MCPeerID, state: MCSessionState) {
        switch state {
        case .notConnected:
            connectedPeers.removeAll { $0 == peer }
            print("[MPC] Peer disconnected: \(peer.displayName)")

        case .connecting:
            connectionState = .connecting
            print("[MPC] Connecting to: \(peer.displayName)")

        case .connected:
            if !connectedPeers.contains(peer) {
                connectedPeers.append(peer)
            }
            print("[MPC] Connected to: \(peer.displayName)")

        @unknown default:
            break
        }

        // Update aggregate state
        if connectedPeers.isEmpty {
            connectionState = (isAdvertising || isBrowsing) ? .searching : .idle
        } else {
            connectionState = .connected(peerCount: connectedPeers.count)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            dataReceived.send((data, peerID))
        }
    }

    // Unused but required delegate stubs
    nonisolated func session(_ s: MCSession, didReceive stream: InputStream, withName name: String, fromPeer p: MCPeerID) {}
    nonisolated func session(_ s: MCSession, didStartReceivingResourceWithName n: String, fromPeer p: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ s: MCSession, didFinishReceivingResourceWithName n: String, fromPeer p: MCPeerID, at url: URL?, withError e: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension ConnectivityService: MCNearbyServiceAdvertiserDelegate {

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Auto-accept all invitations — zero user friction
        Task { @MainActor in
            invitationHandler(true, session)
            print("[MPC] Auto-accepted invitation from: \(peerID.displayName)")
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            connectionState = .error("Advertising failed")
            isAdvertising = false
            print("[MPC] Advertising error: \(error.localizedDescription)")
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension ConnectivityService: MCNearbyServiceBrowserDelegate {

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard peerID != self.peerID else { return }
            print("[MPC] Discovered peer: \(peerID.displayName)")

            // Auto-invite discovered peer
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            print("[MPC] Lost peer: \(peerID.displayName)")
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            connectionState = .error("Browsing failed")
            isBrowsing = false
            print("[MPC] Browsing error: \(error.localizedDescription)")
        }
    }
}
