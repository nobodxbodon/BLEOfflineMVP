//
//  ConnectivityService.swift
//  BLEOfflineMVP
//
//  Core Bluetooth implementation — works with Bluetooth only, NO Wi-Fi needed.
//  Each device runs both CBCentralManager (scanner) and CBPeripheralManager (advertiser).
//
//  Sending:   Our central writes to connected peripheral's characteristic.
//  Receiving: Our peripheral manager fires didReceiveWrite when another central writes.
//
//  Created by MD Aminuzzaman on 4/23/26.
//

import Foundation
import CoreBluetooth
import Combine
import UIKit

// MARK: - Connectivity Service (Core Bluetooth)

@MainActor
final class ConnectivityService: NSObject, ObservableObject {

    // MARK: - Published State (kept stable from earlier prototype)

    @Published private(set) var connectedPeers: [String] = []
    @Published private(set) var connectionState: ConnectionState = .idle

    // MARK: - Data Publisher

    let dataReceived = PassthroughSubject<(Data, String), Never>()

    // MARK: - BLE UUIDs

    private static let serviceUUID = CBUUID(string: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")
    private static let writeUUID  = CBUUID(string: "A1B2C3D4-E5F6-7890-ABCD-EF1234567891")
    private static let notifyUUID = CBUUID(string: "A1B2C3D4-E5F6-7890-ABCD-EF1234567892")

    // MARK: - BLE Managers

    private var centralManager: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!

    // MARK: - State

    private var isRunning = false
    private var centralReady = false
    private var peripheralReady = false
    private var serviceAdded = false

    /// Peripherals we've connected to and discovered the write characteristic on.
    private var writeTargets: [CBPeripheral: CBCharacteristic] = [:]

    /// Peripherals we're currently connecting to (keep strong reference).
    private var pendingPeripherals: Set<CBPeripheral> = []

    /// One outstanding write at a time per peripheral (CoreBluetooth callback-driven).
    private struct PendingWrite {
        let continuation: CheckedContinuation<Void, Error>
        let timeoutTask: Task<Void, Never>
    }
    private var pendingWritesByPeripheralID: [UUID: PendingWrite] = [:]

    /// Reassembly buffers for chunked messages (keyed by central identifier).
    private var receiveBuffers: [UUID: Data] = [:]
    private var expectedLengths: [UUID: Int] = [:]

    /// Reassembly buffers for notifications (keyed by peripheral identifier).
    private var notifyReceiveBuffers: [UUID: Data] = [:]
    private var notifyExpectedLengths: [UUID: Int] = [:]

    /// The characteristic we expose on our peripheral for others to write to.
    private var messageCharacteristic: CBMutableCharacteristic!

    /// The notify characteristic we expose for peripheral -> central messages.
    private var notifyCharacteristic: CBMutableCharacteristic!

    /// Centrals currently subscribed to our notify characteristic.
    private var subscribedCentrals: [CBCentral] = []

    /// Pending notify chunks when the transmit queue is full.
    private var pendingNotifyChunks: [Data] = []

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
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
        peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
    }

    // MARK: - Public Controls

    func start() {
        isRunning = true
        startIfReady()
    }

    func stop() {
        isRunning = false
        centralManager.stopScan()
        peripheralManager.stopAdvertising()
        for peripheral in writeTargets.keys {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        writeTargets.removeAll()
        pendingPeripherals.removeAll()
        pendingWritesByPeripheralID.values.forEach { $0.timeoutTask.cancel() }
        pendingWritesByPeripheralID.removeAll()
        subscribedCentrals.removeAll()
        pendingNotifyChunks.removeAll()
        connectedPeers = []
        connectionState = .idle
    }

    // MARK: - Internal Start

    private func startIfReady() {
        guard isRunning else { return }

        if centralReady {
            centralManager.scanForPeripherals(
                withServices: [Self.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
            if connectedPeers.isEmpty {
                connectionState = .searching
            }
            print("[BLE] Central scanning")
        }

        if peripheralReady && !serviceAdded {
            setupGATTService()
        }
    }

    // MARK: - GATT Service Setup

    private func setupGATTService() {
        let writeCharacteristic = CBMutableCharacteristic(
            type: Self.writeUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        messageCharacteristic = writeCharacteristic

        let notifyCharacteristic = CBMutableCharacteristic(
            type: Self.notifyUUID,
            properties: [.notify],
            value: nil,
            permissions: [.readable]
        )
        self.notifyCharacteristic = notifyCharacteristic

        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [writeCharacteristic, notifyCharacteristic]
        peripheralManager.add(service)
    }

    // MARK: - Send Data

    func sendToAll(_ data: Data) async throws {
        pruneDisconnectedWriteTargets()

        guard !writeTargets.isEmpty || !subscribedCentrals.isEmpty else {
            throw ConnectivityError.noPeersConnected
        }

        // Prepend 4-byte length header for reassembly
        var length = UInt32(data.count).bigEndian
        let framedData = Data(bytes: &length, count: 4) + data

        // Snapshot to avoid mutating while iterating
        let targets = Array(writeTargets)
        for (peripheral, characteristic) in targets {
            guard peripheral.state == .connected else { continue }

            let maxLen = max(20, peripheral.maximumWriteValueLength(for: .withResponse))
            if framedData.count > maxLen {
                var offset = 0
                while offset < framedData.count {
                    let end = min(offset + maxLen, framedData.count)
                    let chunk = Data(framedData[offset..<end])
                    try await writeChunk(chunk, to: peripheral, characteristic: characteristic)
                    offset = end
                }
            } else {
                try await writeChunk(framedData, to: peripheral, characteristic: characteristic)
            }
        }

        // If the remote device only connected to us as a central (and we didn't connect back),
        // notifications enable bidirectional messaging over that single link.
        sendNotifyFramed(framedData)
    }

    enum ConnectivityError: LocalizedError {
        case noPeersConnected
        case writeTimeout
        var errorDescription: String? {
            switch self {
            case .noPeersConnected:
                return "No peers connected"
            case .writeTimeout:
                return "Write timed out"
            }
        }
    }

    // MARK: - Helpers

    var displayName: String { UIDevice.current.name }

    private func updatePeerList() {
        let connectedPeripheralIDs = writeTargets.keys
            .filter { $0.state == .connected }
            .map { $0.identifier.uuidString }

        let centralCount = subscribedCentrals.count
        connectedPeers = connectedPeripheralIDs + Array(repeating: "central", count: centralCount)

        if connectedPeripheralIDs.isEmpty && centralCount == 0 {
            connectionState = pendingPeripherals.isEmpty
                ? (isRunning ? .searching : .idle)
                : .connecting
        } else {
            connectionState = .connected(peerCount: connectedPeers.count)
        }
    }

    private func pruneDisconnectedWriteTargets() {
        var removed = false
        for peripheral in writeTargets.keys where peripheral.state != .connected {
            writeTargets.removeValue(forKey: peripheral)
            pendingPeripherals.remove(peripheral)
            removed = true
        }
        if removed {
            updatePeerList()
        }
    }

    private func writeChunk(_ data: Data, to peripheral: CBPeripheral, characteristic: CBCharacteristic) async throws {
        // If the remote side closes/reopens, CoreBluetooth can keep a "connected" object that never ACKs writes.
        // On timeout we forcefully cancel the connection and rely on scan+rediscover to heal.
        let peripheralID = peripheral.identifier

        // Enforce one outstanding write per peripheral.
        if let existing = pendingWritesByPeripheralID.removeValue(forKey: peripheralID) {
            existing.timeoutTask.cancel()
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard let pending = self.pendingWritesByPeripheralID.removeValue(forKey: peripheralID) else { return }

                // Hard reset only this link (no global flapping).
                self.writeTargets.removeValue(forKey: peripheral)
                self.pendingPeripherals.remove(peripheral)
                self.updatePeerList()
                self.centralManager.cancelPeripheralConnection(peripheral)

                pending.continuation.resume(throwing: ConnectivityError.writeTimeout)
            }

            self.pendingWritesByPeripheralID[peripheralID] = PendingWrite(
                continuation: continuation,
                timeoutTask: timeoutTask
            )

            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
    }

    private func sendNotifyFramed(_ framedData: Data) {
        guard !subscribedCentrals.isEmpty else { return }
        guard notifyCharacteristic != nil else { return }

        // CoreBluetooth doesn't always expose a reliable max update length across SDKs/sims.
        // Use a conservative default; notifications will still work (just more chunks).
        let maxLen = 20
        if framedData.count > maxLen {
            var offset = 0
            while offset < framedData.count {
                let end = min(offset + maxLen, framedData.count)
                pendingNotifyChunks.append(Data(framedData[offset..<end]))
                offset = end
            }
        } else {
            pendingNotifyChunks.append(framedData)
        }

        flushNotifyOutbox()
    }

    private func flushNotifyOutbox() {
        guard !pendingNotifyChunks.isEmpty else { return }
        guard notifyCharacteristic != nil else { return }
        guard !subscribedCentrals.isEmpty else {
            pendingNotifyChunks.removeAll()
            return
        }

        while let next = pendingNotifyChunks.first {
            let ok = peripheralManager.updateValue(next, for: notifyCharacteristic, onSubscribedCentrals: nil)
            if ok {
                pendingNotifyChunks.removeFirst()
            } else {
                break
            }
        }
    }

    private func processReceivedNotifyChunk(_ data: Data, from peripheralID: UUID) {
        if notifyReceiveBuffers[peripheralID] == nil {
            guard data.count >= 4 else { return }
            let totalLength = Int(data.prefix(4).withUnsafeBytes {
                $0.load(as: UInt32.self).bigEndian
            })
            let payload = data.dropFirst(4)
            notifyExpectedLengths[peripheralID] = totalLength

            if payload.count >= totalLength {
                dataReceived.send((Data(payload.prefix(totalLength)), peripheralID.uuidString))
                notifyReceiveBuffers.removeValue(forKey: peripheralID)
                notifyExpectedLengths.removeValue(forKey: peripheralID)
            } else {
                notifyReceiveBuffers[peripheralID] = Data(payload)
            }
        } else {
            notifyReceiveBuffers[peripheralID]?.append(data)
            if let buffer = notifyReceiveBuffers[peripheralID],
               let expected = notifyExpectedLengths[peripheralID],
               buffer.count >= expected {
                dataReceived.send((Data(buffer.prefix(expected)), peripheralID.uuidString))
                notifyReceiveBuffers.removeValue(forKey: peripheralID)
                notifyExpectedLengths.removeValue(forKey: peripheralID)
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension ConnectivityService: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                self.centralReady = true
                print("[BLE] Central powered on")
                self.startIfReady()
            case .poweredOff:
                self.centralReady = false
                self.connectionState = .error("Bluetooth off")
            default:
                self.centralReady = false
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                     didDiscover peripheral: CBPeripheral,
                                     advertisementData: [String: Any],
                                     rssi RSSI: NSNumber) {
        Task { @MainActor in
            // Skip if already connected or connecting
            guard self.writeTargets[peripheral] == nil,
                  !self.pendingPeripherals.contains(peripheral) else { return }

            let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown"
            print("[BLE] Discovered: \(name)")

            self.pendingPeripherals.insert(peripheral)
            self.connectionState = .connecting
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            print("[BLE] Connected to peripheral: \(peripheral.name ?? peripheral.identifier.uuidString)")
            peripheral.delegate = self
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                     didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            print("[BLE] Failed to connect: \(error?.localizedDescription ?? "unknown")")
            self.pendingPeripherals.remove(peripheral)
            self.updatePeerList()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                     didDisconnectPeripheral peripheral: CBPeripheral,
                                     error: Error?) {
        Task { @MainActor in
            print("[BLE] Disconnected from: \(peripheral.name ?? peripheral.identifier.uuidString)")
            self.writeTargets.removeValue(forKey: peripheral)
            self.pendingPeripherals.remove(peripheral)
            self.updatePeerList()

            // Heal by going back to scanning. Auto-connecting to a stale CBPeripheral after the
            // remote app restarts can wedge sending while UI still looks "connected".
            if self.isRunning && self.centralReady {
                self.centralManager.scanForPeripherals(
                    withServices: [Self.serviceUUID],
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                )
                if self.connectedPeers.isEmpty {
                    self.connectionState = .searching
                }
            }
        }
    }
}

// MARK: - CBPeripheralDelegate (for discovering characteristics on remote peripherals)

extension ConnectivityService: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard error == nil,
                  let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
                print("[BLE] Service discovery failed: \(error?.localizedDescription ?? "not found")")
                return
            }
            // Discover both directions: central->peripheral write + peripheral->central notify.
            peripheral.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                 didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            guard error == nil, let characteristics = service.characteristics else {
                print("[BLE] Characteristic discovery failed")
                return
            }

            guard let writeCharacteristic = characteristics.first(where: { $0.uuid == Self.writeUUID }) else {
                print("[BLE] Write characteristic missing")
                return
            }

            self.writeTargets[peripheral] = writeCharacteristic
            self.pendingPeripherals.remove(peripheral)
            self.updatePeerList()
            print("[BLE] Ready to send to: \(peripheral.name ?? peripheral.identifier.uuidString)")

            if let notifyCharacteristic = characteristics.first(where: { $0.uuid == Self.notifyUUID }) {
                peripheral.setNotifyValue(true, for: notifyCharacteristic)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard error == nil else { return }
            guard characteristic.uuid == Self.notifyUUID else { return }
            guard let data = characteristic.value, !data.isEmpty else { return }
            self.processReceivedNotifyChunk(data, from: peripheral.identifier)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                 didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            let peripheralID = peripheral.identifier
            guard let pending = self.pendingWritesByPeripheralID.removeValue(forKey: peripheralID) else { return }
            pending.timeoutTask.cancel()

            if let error = error {
                print("[BLE] Write error: \(error.localizedDescription)")
                self.writeTargets.removeValue(forKey: peripheral)
                self.pendingPeripherals.remove(peripheral)
                self.updatePeerList()
                self.centralManager.cancelPeripheralConnection(peripheral)
                pending.continuation.resume(throwing: error)
            } else {
                pending.continuation.resume()
            }
        }
    }
}

// MARK: - CBPeripheralManagerDelegate (receives data from other centrals)

extension ConnectivityService: CBPeripheralManagerDelegate {

    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            switch peripheral.state {
            case .poweredOn:
                self.peripheralReady = true
                print("[BLE] Peripheral powered on")
                self.startIfReady()
            case .poweredOff:
                self.peripheralReady = false
            default:
                self.peripheralReady = false
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        Task { @MainActor in
            if let error = error {
                print("[BLE] Failed to add service: \(error.localizedDescription)")
                return
            }
            self.serviceAdded = true
            peripheral.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
                CBAdvertisementDataLocalNameKey: UIDevice.current.name
            ])
            print("[BLE] Service added, advertising started")
        }
    }

    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        Task { @MainActor in
            if let error = error {
                print("[BLE] Advertising failed: \(error.localizedDescription)")
            } else {
                print("[BLE] Advertising successfully")
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        Task { @MainActor in
            guard characteristic.uuid == Self.notifyUUID else { return }
            if !self.subscribedCentrals.contains(where: { $0.identifier == central.identifier }) {
                self.subscribedCentrals.append(central)
                self.updatePeerList()
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        Task { @MainActor in
            guard characteristic.uuid == Self.notifyUUID else { return }
            self.subscribedCentrals.removeAll(where: { $0.identifier == central.identifier })
            self.updatePeerList()
        }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        Task { @MainActor in
            self.flushNotifyOutbox()
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                        didReceiveWrite requests: [CBATTRequest]) {
        Task { @MainActor in
            for request in requests {
                guard let data = request.value, !data.isEmpty else {
                    peripheral.respond(to: request, withResult: .success)
                    continue
                }

                let centralID = request.central.identifier
                self.processReceivedChunk(data, from: centralID)
                peripheral.respond(to: request, withResult: .success)
            }
        }
    }

    // MARK: - Chunk Reassembly

    @MainActor
    private func processReceivedChunk(_ data: Data, from centralID: UUID) {
        if receiveBuffers[centralID] == nil {
            // New message — first 4 bytes are the total length
            guard data.count >= 4 else { return }
            let totalLength = Int(data.prefix(4).withUnsafeBytes {
                $0.load(as: UInt32.self).bigEndian
            })
            let payload = data.dropFirst(4)
            expectedLengths[centralID] = totalLength

            if payload.count >= totalLength {
                // Complete in one write
                dataReceived.send((Data(payload.prefix(totalLength)), centralID.uuidString))
                receiveBuffers.removeValue(forKey: centralID)
                expectedLengths.removeValue(forKey: centralID)
            } else {
                receiveBuffers[centralID] = Data(payload)
            }
        } else {
            // Continuation chunk
            receiveBuffers[centralID]?.append(data)

            if let buffer = receiveBuffers[centralID],
               let expected = expectedLengths[centralID],
               buffer.count >= expected {
                dataReceived.send((Data(buffer.prefix(expected)), centralID.uuidString))
                receiveBuffers.removeValue(forKey: centralID)
                expectedLengths.removeValue(forKey: centralID)
            }
        }
    }
}
