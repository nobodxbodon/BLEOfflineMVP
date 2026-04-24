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

    // MARK: - Published State (same interface as MPC version)

    @Published private(set) var connectedPeers: [String] = []
    @Published private(set) var connectionState: ConnectionState = .idle

    // MARK: - Data Publisher

    let dataReceived = PassthroughSubject<(Data, String), Never>()

    // MARK: - BLE UUIDs

    private static let serviceUUID = CBUUID(string: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")
    private static let writeUUID  = CBUUID(string: "A1B2C3D4-E5F6-7890-ABCD-EF1234567891")

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

    /// Reassembly buffers for chunked messages (keyed by central identifier).
    private var receiveBuffers: [UUID: Data] = [:]
    private var expectedLengths: [UUID: Int] = [:]

    /// The characteristic we expose on our peripheral for others to write to.
    private var messageCharacteristic: CBMutableCharacteristic!

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
        let characteristic = CBMutableCharacteristic(
            type: Self.writeUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        messageCharacteristic = characteristic

        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        peripheralManager.add(service)
    }

    // MARK: - Send Data

    func sendToAll(_ data: Data) throws {
        guard !writeTargets.isEmpty else {
            throw ConnectivityError.noPeersConnected
        }

        // Prepend 4-byte length header for reassembly
        var length = UInt32(data.count).bigEndian
        let framedData = Data(bytes: &length, count: 4) + data

        for (peripheral, characteristic) in writeTargets {
            let maxLen = peripheral.maximumWriteValueLength(for: .withResponse)
            if maxLen > 0 && framedData.count > maxLen {
                // Chunk it
                var offset = 0
                while offset < framedData.count {
                    let end = min(offset + maxLen, framedData.count)
                    let chunk = framedData[offset..<end]
                    peripheral.writeValue(Data(chunk), for: characteristic, type: .withResponse)
                    offset = end
                }
            } else {
                peripheral.writeValue(framedData, for: characteristic, type: .withResponse)
            }
        }
    }

    enum ConnectivityError: LocalizedError {
        case noPeersConnected
        var errorDescription: String? { "No peers connected" }
    }

    // MARK: - Helpers

    var displayName: String { UIDevice.current.name }

    private func updatePeerList() {
        connectedPeers = writeTargets.keys.map { $0.identifier.uuidString }
        if connectedPeers.isEmpty {
            connectionState = pendingPeripherals.isEmpty
                ? (isRunning ? .searching : .idle)
                : .connecting
        } else {
            connectionState = .connected(peerCount: connectedPeers.count)
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

            // Auto-reconnect
            if self.isRunning {
                print("[BLE] Auto-reconnecting...")
                central.connect(peripheral, options: nil)
                self.pendingPeripherals.insert(peripheral)
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
            peripheral.discoverCharacteristics([Self.writeUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                 didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            guard error == nil,
                  let characteristic = service.characteristics?.first(where: { $0.uuid == Self.writeUUID }) else {
                print("[BLE] Characteristic discovery failed")
                return
            }

            self.writeTargets[peripheral] = characteristic
            self.pendingPeripherals.remove(peripheral)
            self.updatePeerList()
            print("[BLE] Ready to send to: \(peripheral.name ?? peripheral.identifier.uuidString)")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                 didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            Task { @MainActor in
                print("[BLE] Write error: \(error.localizedDescription)")
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
