@preconcurrency import CoreBluetooth
import SwiftUI

@MainActor
@Observable
final class LightBLEManager: NSObject {

    // MARK: - Types

    enum ConnectionState: String {
        case disconnected, scanning, connecting, connected
    }

    // MARK: - Published state

    var connectionState: ConnectionState = .disconnected
    var isOn = false
    var color: Color = .white
    var brightness: Double = 1.0
    var effectMode: UInt8 = 0x25
    var effectSpeed: UInt8 = 0x0F

    // MARK: - Private constants (inside @MainActor class, safe)

    nonisolated(unsafe) private static let serviceUUID    = CBUUID(string: "FFF0")
    nonisolated(unsafe) private static let writeCharUUID  = CBUUID(string: "FFF3")
    nonisolated(unsafe) private static let notifyCharUUID = CBUUID(string: "FFF4")
    nonisolated(unsafe) private static let advertisedUUID = CBUUID(string: "2022")

    // MARK: - Private state

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var reconnectTask: Task<Void, Never>?
    private var colorDebounce: Task<Void, Never>?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Public API

    func connect() {
        guard connectionState == .disconnected else { return }
        reconnectAttempts = 0
        startScan()
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = maxReconnectAttempts
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        connectionState = .disconnected
    }

    func setPower(on: Bool) {
        isOn = on
        write(on ? Cmd.powerOn : Cmd.powerOff)
    }

    func setColor(_ newColor: Color) {
        color = newColor
        colorDebounce?.cancel()
        colorDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            let (r, g, b) = newColor.rgbComponents
            self.write(Cmd.color(r: r, g: g, b: b))
        }
    }

    func setBrightness(_ value: Double) {
        brightness = value
        write(Cmd.brightness(value))
    }

    func setEffect(mode: UInt8, speed: UInt8) {
        effectMode = mode
        effectSpeed = speed
        write(Cmd.effect(mode: mode, speed: speed))
    }

    // MARK: - Private helpers

    private func startScan() {
        connectionState = .scanning
        central.scanForPeripherals(withServices: [Self.advertisedUUID], options: nil)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard self.connectionState == .scanning else { return }
            self.central.stopScan()
            self.connectionState = .disconnected
        }
    }

    private func write(_ bytes: [UInt8]) {
        guard let p = peripheral, let ch = writeChar,
              connectionState == .connected else { return }
        p.writeValue(Data(bytes), for: ch, type: .withoutResponse)
    }

    private func scheduleReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            connectionState = .disconnected
            return
        }
        reconnectAttempts += 1
        let delay = UInt64(min(30, pow(2.0, Double(reconnectAttempts)))) * 1_000_000_000
        reconnectTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            if let p = self.peripheral {
                self.connectionState = .connecting
                self.central.connect(p, options: nil)
            } else {
                self.startScan()
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension LightBLEManager: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // auto-connect on BT power-on could go here
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? ""
        guard name.contains("GATT") || name.contains("LED") else { return }

        Task { @MainActor in
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            self.connectionState = .connecting
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.reconnectAttempts = 0
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: (any Error)?) {
        Task { @MainActor in self.scheduleReconnect() }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: (any Error)?) {
        Task { @MainActor in
            self.writeChar = nil
            self.connectionState = .disconnected
            if error != nil { self.scheduleReconnect() }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension LightBLEManager: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverServices error: (any Error)?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID })
        else { return }
        peripheral.discoverCharacteristics([Self.writeCharUUID, Self.notifyCharUUID], for: service)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: (any Error)?) {
        Task { @MainActor in
            self.writeChar = service.characteristics?.first(where: { $0.uuid == Self.writeCharUUID })
            if self.writeChar != nil { self.connectionState = .connected }
            if let notify = service.characteristics?.first(where: { $0.uuid == Self.notifyCharUUID }) {
                peripheral.setNotifyValue(true, for: notify)
            }
        }
    }
}

// MARK: - Command encoder

private enum Cmd {
    static let powerOn:  [UInt8] = [0x7E, 0x00, 0x04, 0xF0, 0x00, 0x01, 0xFF, 0x00, 0xEF]
    static let powerOff: [UInt8] = [0x7E, 0x00, 0x04, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xEF]

    static func color(r: UInt8, g: UInt8, b: UInt8) -> [UInt8] {
        [0x7E, 0x00, 0x05, 0x03, r, g, b, 0x00, 0xEF]
    }
    static func brightness(_ value: Double) -> [UInt8] {
        let level = UInt8(max(0, min(100, Int(value * 100))))
        return [0x7E, 0x00, 0x01, level, 0x00, 0x00, 0x00, 0x00, 0xEF]
    }
    static func effect(mode: UInt8, speed: UInt8) -> [UInt8] {
        [0x7E, 0x00, 0x03, mode, speed, 0x00, 0x00, 0x00, 0xEF]
    }
}

// MARK: - Color helper

private extension Color {
    var rgbComponents: (UInt8, UInt8, UInt8) {
        let r = NSColor(self).redComponent
        let g = NSColor(self).greenComponent
        let b = NSColor(self).blueComponent
        return (
            UInt8(max(0, min(255, Int(r * 255)))),
            UInt8(max(0, min(255, Int(g * 255)))),
            UInt8(max(0, min(255, Int(b * 255))))
        )
    }
}
