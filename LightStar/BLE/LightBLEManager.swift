@preconcurrency import CoreBluetooth
import SwiftUI

@MainActor
@Observable
final class LightBLEManager: NSObject {

    // MARK: - Types

    enum ConnectionState: String {
        case disconnected, scanning, connecting, connected
    }

    enum SyncMode: String, CaseIterable, Equatable {
        case off      = "Off"
        case video    = "Video"
        case audio    = "Audio"
        case combined = "Video+Audio"
    }

    // MARK: - Observable state

    var connectionState: ConnectionState = .disconnected
    var connectionError: String?   // set on scan timeout or reconnect exhaustion
    var bleNeedsPermission = false  // true when BT is .unauthorized → show settings button
    var isOn: Bool = UserDefaults.standard.object(forKey: "lastPowerState") as? Bool ?? false {
        didSet { UserDefaults.standard.set(isOn, forKey: "lastPowerState") }
    }
    var color: Color = {
        guard let h = UserDefaults.standard.object(forKey: "colorHue") as? Double,
              let s = UserDefaults.standard.object(forKey: "colorSat") as? Double else { return .white }
        return Color(hue: h, saturation: s, brightness: 1)
    }()
    var brightness: Double = UserDefaults.standard.object(forKey: "brightness") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(brightness, forKey: "brightness") }
    }
    var effectID: UInt8 = 0x01
    var effectSpeed: Double = 0.5   // 0–1 mapped to 0–100
    var effectModeActive = false
    // Sync state machine
    var syncMode: SyncMode = .off
    var syncColor: Color? = nil          // live color during sync; nil when sync is off
    var syncError: String?
    var syncNeedsPermission = false   // true when syncError is a Screen Recording denial
    var pendingSyncMode: SyncMode?  // mode to retry when permission is granted
    var syncTransitioning = false
    // Called after the connect sequence completes with no sync mode to restore
    var onConnect: (@MainActor () -> Void)?
    enum AudioSyncMode: String, CaseIterable { case rainbow = "Rainbow"; case pulse = "Pulse"; case frequency = "Frequency" }
    var audioSyncMode: AudioSyncMode = .rainbow
    enum AudioInputSource: String, CaseIterable { case system = "System Audio"; case mic = "Microphone"; case stripMic = "Strip Mic" }
    var audioInputSource: AudioInputSource = {
        guard let raw = UserDefaults.standard.string(forKey: "audioInputSource"),
              let v = AudioInputSource(rawValue: raw) else { return .system }
        return v
    }() {
        didSet {
            UserDefaults.standard.set(audioInputSource.rawValue, forKey: "audioInputSource")
            guard syncMode == .audio, oldValue != audioInputSource else { return }
            setSyncMode(.audio)
        }
    }
    // Strip onboard mic settings (BC11 style, BC12 sensitivity)
    enum MicStyle: Int, CaseIterable {
        case classic = 1, soft = 2, dynamic = 3, disco = 4
        var label: String {
            switch self { case .classic: "Classic"; case .soft: "Soft"; case .dynamic: "Dynamic"; case .disco: "Disco" }
        }
    }
    var micStyle: MicStyle = .classic {
        didSet { if audioInputSource == .stripMic { write(Cmd.micStyle(UInt8(micStyle.rawValue))) } }
    }
    // 0–255 mapped to 0.0–1.0 for slider
    var micSensitivity: Double = UserDefaults.standard.object(forKey: "micSensitivity") as? Double ?? 0.5 {
        didSet {
            UserDefaults.standard.set(micSensitivity, forKey: "micSensitivity")
            if audioInputSource == .stripMic { write(Cmd.micSensitivity(Int(micSensitivity * 255))) }
        }
    }

    // LED strip hardware config
    enum LEDChannelOrder: Int, CaseIterable {
        case rgb = 1, rbg = 2, grb = 3, gbr = 4, brg = 5, bgr = 6
        var label: String {
            switch self { case .rgb: "RGB"; case .rbg: "RBG"; case .grb: "GRB"; case .gbr: "GBR"; case .brg: "BRG"; case .bgr: "BGR" }
        }
    }
    var ledChannelOrder: LEDChannelOrder = .rgb {
        didSet { write([0xBC, 0x02, 0x01, UInt8(ledChannelOrder.rawValue), 0x55]) }
    }
    var ledPixelCount: Int = 30 {
        didSet {
            let n = max(8, min(300, ledPixelCount))
            ledPixelCount = n
            write([0xBC, 0x03, 0x02, UInt8(n >> 8), UInt8(n & 0xFF), 0x55])
        }
    }

    // Display picker
    var availableDisplays: [(id: CGDirectDisplayID, name: String)] = []
    var selectedDisplayID: CGDirectDisplayID? = nil {
        didSet {
            guard isSyncingVideo, oldValue != selectedDisplayID else { return }
            setSyncMode(syncMode)  // restart with the new display
        }
    }
    var syncResponsiveness: Double = UserDefaults.standard.object(forKey: "syncResponsiveness") as? Double ?? 0.7 {
        didSet { UserDefaults.standard.set(syncResponsiveness, forKey: "syncResponsiveness") }
    }
    // Beat sensitivity: 0 = very hard to trigger, 0.5 = default (flux > 0.60), 1 = very sensitive (flux > 0.20)
    var beatSensitivity: Double = UserDefaults.standard.object(forKey: "beatSensitivity") as? Double ?? 0.5 {
        didSet { UserDefaults.standard.set(beatSensitivity, forKey: "beatSensitivity") }
    }
    // When true, video sync also drives strip brightness from average screen brightness
    var videoSyncBrightness: Bool = UserDefaults.standard.bool(forKey: "videoSyncBrightness") {
        didSet { UserDefaults.standard.set(videoSyncBrightness, forKey: "videoSyncBrightness") }
    }

    var isSyncingVideo: Bool { syncMode == .video || syncMode == .combined }
    var isSyncingAudio: Bool { syncMode == .audio || syncMode == .combined }

    // MARK: - Color history (last 12 manually set colors)

    var colorHistory: [(h: Double, s: Double)] = {
        guard let data = UserDefaults.standard.data(forKey: "colorHistory"),
              let arr = try? JSONDecoder().decode([[Double]].self, from: data) else { return [] }
        return arr.map { ($0[0], $0[1]) }
    }()

    // MARK: - Circadian auto color temperature

    var circadianEnabled: Bool = UserDefaults.standard.bool(forKey: "circadianEnabled") {
        didSet {
            UserDefaults.standard.set(circadianEnabled, forKey: "circadianEnabled")
            if circadianEnabled { startCircadianTimer() } else { stopCircadianTimer() }
        }
    }
    var circadianTimer: Timer?

    // MARK: - Protocol probe
    var probeLog: [String] = []
    var probeRunning = false

    // MARK: - Device discovery log
    var deviceLog: [String] = []
    var capturedAdvertisementStrings: [String: String] = [:]
    var capturedRSSI: Int = 0
    // MARK: - BLE UUIDs

    nonisolated(unsafe) private static let serviceUUID    = CBUUID(string: "FFF0")
    nonisolated(unsafe) private static let writeCharUUID  = CBUUID(string: "FFF3")
    nonisolated(unsafe) private static let notifyCharUUID = CBUUID(string: "FFF4")
    nonisolated(unsafe) private static let advertisedUUID = CBUUID(string: "2022")

    // MARK: - Multi-light

    var multiLightEnabled: Bool = UserDefaults.standard.bool(forKey: "multiLightEnabled") {
        didSet {
            UserDefaults.standard.set(multiLightEnabled, forKey: "multiLightEnabled")
            if !multiLightEnabled { disconnectExtraLights() }
        }
    }
    // Names of all connected lights (primary first, then extras)
    var connectedLightNames: [String] {
        var names: [String] = []
        if let n = peripheral?.name { names.append(n) }
        names += extraLights.compactMap { $0.peripheral.name }
        return names
    }

    // MARK: - Private state

    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var writeChar: CBCharacteristic?
    var extraLights: [(peripheral: CBPeripheral, writeChar: CBCharacteristic?)] = []
    var reconnectTask: Task<Void, Never>?
    var probeTask: Task<Void, Never>?
    // Set during probe sweeps to mirror BLE notifications into probeLog
    var notifyTapHandler: ((Data) -> Void)?
    var connectSequenceTask: Task<Void, Never>?
    var connectWhenReady = false
    var shouldAutoReconnect = false
    // Restored after reconnect and after full app restart
    var lastSyncMode: SyncMode = {
        guard let raw = UserDefaults.standard.string(forKey: "lastSyncMode"),
              let v = SyncMode(rawValue: raw) else { return .off }
        return v
    }()
    var colorDebounce: Task<Void, Never>?
    var reconnectAttempts = 0
    let maxReconnectAttempts = 5
    let systemAudio = SystemAudioSampler()
    let micAudio = MicAudioSampler()
    var transitionTask: Task<Void, Never>?
    var fadeTask: Task<Void, Never>?
    var coalescer: BLEWriteCoalescer!
    var beatHue: Double = 0
    var flashLevel: Double = 0
    var lastScreenH: Double = 0
    var lastScreenS: Double = 1
    var audioPulseH: Double = 0   // cached hue for pulse mode — avoids 30Hz hsvComponents
    let screenSampler = ScreenColorSampler()

    override init() {
        super.init()
        if circadianEnabled { startCircadianTimer() }
        central = CBCentralManager(delegate: self, queue: .main)
        coalescer = BLEWriteCoalescer(
            send: { [weak self] data in
                guard let self else { return }
                if let p = self.peripheral, let ch = self.writeChar {
                    p.writeValue(data, for: ch, type: .withResponse)
                }
                for light in self.extraLights {
                    guard let ch = light.writeChar else { continue }
                    light.peripheral.writeValue(data, for: ch, type: .withResponse)
                }
            },
            isConnected: { [weak self] in self?.connectionState == .connected }
        )
    }

    // MARK: - Public API

    func connect() {
        guard connectionState == .disconnected else { return }
        reconnectAttempts = 0
        connectionError = nil
        bleNeedsPermission = false

        // Use central.state (from the live CBCentralManager) rather than the
        // CBManager.authorization class property — the class property can return
        // stale data after the user grants permission in System Settings.
        if central.state == .poweredOn {
            startScan()
        } else if central.state == .unauthorized {
            bleNeedsPermission = true
            connectionError = "Bluetooth access denied. Open Privacy & Security → Bluetooth and enable LightStar."
        } else {
            // .unknown / .poweredOff / .resetting — defer to centralManagerDidUpdateState
            connectWhenReady = true
            connectionState = .scanning
        }
    }

    // Call when the user returns from System Settings after (potentially) granting
    // Bluetooth permission. Recreates CBCentralManager so it re-evaluates current
    // auth state and triggers the permission dialog if still notDetermined.
    func retryBluetoothPermission() {
        guard bleNeedsPermission else { return }
        bleNeedsPermission = false
        connectionError = nil
        connectionState = .disconnected
        connectWhenReady = true
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        probeTask?.cancel()
        probeTask = nil
        connectSequenceTask?.cancel()
        connectSequenceTask = nil
        connectWhenReady = false
        shouldAutoReconnect = false
        lastSyncMode = .off
        reconnectAttempts = maxReconnectAttempts
        bleNeedsPermission = false
        connectionError = nil
        coalescer.flush()
        if probeRunning {
            probeRunning = false
            notifyTapHandler = nil
        }
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        disconnectExtraLights()
        connectionState = .disconnected
    }

    func sendRaw(_ bytes: [UInt8]) {
        print("[LightStar] sendRaw: \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        write(bytes)
    }

    func setPower(on: Bool) {
        isOn = on
        if !on {
            // Cancel ALL pending async work before powerOff — any hue/brightness
            // packet arriving after powerOff wakes the BC/55 strip back up.
            transitionTask?.cancel(); transitionTask = nil
            connectSequenceTask?.cancel(); connectSequenceTask = nil
            probeTask?.cancel(); probeTask = nil
            fadeTask?.cancel(); fadeTask = nil
            colorDebounce?.cancel(); colorDebounce = nil
            syncTransitioning = false
            systemAudio.onBands = nil
            screenSampler.onColor = nil
            flashLevel = 0
            syncMode = .off
            // Stop samplers async — no fade, nothing writes after powerOff
            Task { await self.systemAudio.stop(); await self.screenSampler.stop() }
        }
        write(on ? Cmd.powerOn : Cmd.powerOff)
    }

    // MARK: - Private helpers

    private func disconnectExtraLights() {
        for light in extraLights { central.cancelPeripheralConnection(light.peripheral) }
        extraLights.removeAll()
    }

    private func startScan() {
        guard central.state == .poweredOn else { return }
        connectionError = nil
        connectionState = .scanning
        central.scanForPeripherals(withServices: [Self.advertisedUUID], options: nil)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard self.connectionState == .scanning else { return }
            self.central.stopScan()
            self.connectionState = .disconnected
            self.connectionError = "Device not found — make sure it's powered on"
        }
    }

    // FFF3 supports write-with-response (.write) — CB queues internally, ACK guaranteed.
    func write(_ bytes: [UInt8]) { coalescer.enqueue(bytes) }

    private func scheduleReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            connectionState = .disconnected
            connectionError = "Could not reconnect — tap Connect to retry"
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
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                // Clear any stale permission error — BT is now authorized and on.
                // This fires automatically when the user grants permission in System
                // Settings and returns to the app.
                if self.bleNeedsPermission {
                    self.bleNeedsPermission = false
                    self.connectionError = nil
                    self.connectionState = .disconnected
                    // Auto-reconnect so user doesn't need to tap Connect again.
                    self.reconnectAttempts = 0
                    self.startScan()
                } else if self.connectWhenReady {
                    self.connectWhenReady = false
                    self.startScan()
                } else if self.shouldAutoReconnect && self.connectionState == .disconnected {
                    // BT came back on (wake-from-sleep) after an unexpected drop — reconnect
                    self.shouldAutoReconnect = false
                    self.reconnectAttempts = 0
                    if let p = self.peripheral {
                        self.connectionState = .connecting
                        self.central.connect(p, options: nil)
                    } else {
                        self.startScan()
                    }
                }
            case .poweredOff:
                if self.connectionState == .scanning || self.connectionState == .connecting {
                    self.central.stopScan()
                    self.connectionState = .disconnected
                    self.connectionError = "Bluetooth is off — turn it on to connect"
                }
            case .unauthorized:
                self.connectionState = .disconnected
                self.bleNeedsPermission = true
                self.connectionError = "Bluetooth access denied. Open Privacy & Security → Bluetooth and enable LightStar."
                self.connectWhenReady = false
            case .resetting:
                // BT stack is resetting (e.g. after wake) — wait for poweredOn callback
                break
            default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        // Scan filters by 0x2022 service, so any result here is our device
        // Serialize advertisement before crossing actor boundary (not Sendable)
        var advStrings: [String: String] = [:]
        for (k, v) in advertisementData {
            if let data = v as? Data {
                advStrings[k] = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            } else if let uuids = v as? [CBUUID] {
                advStrings[k] = uuids.map { $0.uuidString }.joined(separator: ", ")
            } else {
                advStrings[k] = "\(v)"
            }
        }
        let rssi = RSSI.intValue
        Task { @MainActor in
            if self.multiLightEnabled && self.peripheral != nil {
                // Extra light — connect without stopping scan (more may appear)
                guard peripheral !== self.peripheral else { return }
                guard !self.extraLights.contains(where: { $0.peripheral === peripheral }) else { return }
                peripheral.delegate = self
                self.extraLights.append((peripheral: peripheral, writeChar: nil))
                central.connect(peripheral, options: nil)
                return
            }
            central.stopScan()
            self.peripheral = peripheral
            self.capturedAdvertisementStrings = advStrings
            self.capturedRSSI = rssi
            peripheral.delegate = self
            self.connectionState = .connecting
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.reconnectAttempts = 0
            self.deviceLog = ["Connecting to \(peripheral.name ?? "unknown")…"]
            // nil = discover ALL services (finds Device Info, DFU, etc.)
            peripheral.discoverServices(nil)
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
            // Extra light drop — just remove it, don't affect primary connection state
            if let idx = self.extraLights.firstIndex(where: { $0.peripheral === peripheral }) {
                self.extraLights.remove(at: idx)
                return
            }
            self.writeChar = nil
            self.connectionState = .disconnected
            self.coalescer.flush()
            self.transitionTask?.cancel()
            self.connectSequenceTask?.cancel()
            self.connectSequenceTask = nil
            self.probeTask?.cancel()
            self.probeTask = nil
            self.systemAudio.onBands = nil
            self.screenSampler.onColor = nil
            // Save active sync mode before clearing — restored on reconnect and next app launch
            self.lastSyncMode = self.syncMode
            UserDefaults.standard.set(self.syncMode.rawValue, forKey: "lastSyncMode")
            self.syncMode = .off
            self.syncTransitioning = false
            Task { await self.systemAudio.stop() }
            Task { await self.screenSampler.stop() }
            // reconnectAttempts == maxReconnectAttempts means user called disconnect() — skip auto-reconnect
            if error != nil && self.reconnectAttempts < self.maxReconnectAttempts {
                self.shouldAutoReconnect = true
                self.scheduleReconnect()
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension LightBLEManager: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverServices error: (any Error)?) {
        guard let services = peripheral.services else { return }
        let uuids = services.map { $0.uuid.uuidString }
        let line = "=== SERVICES (\(uuids.count)): \(uuids.joined(separator: ", "))"
        print("[LightStar] \(line)")
        Task { @MainActor in self.deviceLog.append(line) }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: (any Error)?) {
        let chars = service.characteristics ?? []
        let svcUUID = service.uuid.uuidString
        let summary = chars.map { ch -> String in
            var props: [String] = []
            if ch.properties.contains(.read)                { props.append("R") }
            if ch.properties.contains(.write)               { props.append("W") }
            if ch.properties.contains(.writeWithoutResponse){ props.append("WnR") }
            if ch.properties.contains(.notify)              { props.append("N") }
            if ch.properties.contains(.indicate)            { props.append("I") }
            return "\(ch.uuid.uuidString)[\(props.joined(separator: ","))]"
        }.joined(separator: " | ")
        let line = "--- \(svcUUID): \(summary)"
        print("[LightStar] \(line)")
        Task { @MainActor in self.deviceLog.append(line) }
        Task { @MainActor in
            // Check if this is an extra light
            if let idx = self.extraLights.firstIndex(where: { $0.peripheral === peripheral }) {
                if let ch = chars.first(where: { $0.uuid == Self.writeCharUUID }) {
                    self.extraLights[idx].writeChar = ch
                    print("[LightStar] extra light ready: \(peripheral.name ?? "unknown")")
                }
                return
            }
            for char in chars {
                if char.uuid == Self.writeCharUUID {
                    self.writeChar = char
                    print("[LightStar] write char ready: \(char.uuid) props:\(char.properties.rawValue)")
                }
                if char.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: char)
                }
                // Read any readable characteristic — gets manufacturer, model, firmware version
                if char.properties.contains(.read) {
                    peripheral.readValue(for: char)
                }
            }
            if self.writeChar != nil {
                self.connectionState = .connected
                self.sendTimeSync()
                let targetOn = self.isOn  // respect persisted power state from before disconnect
                // Power-cycle on connect (mirrors OEM app init), then clear animation
                self.connectSequenceTask = Task { @MainActor in
                    self.write(Cmd.powerOff)
                    do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                    if targetOn {
                        self.write(Cmd.powerOn)
                        do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                    }
                    self.isOn = targetOn
                    let (h, s, _) = self.color.hsvComponents
                    self.write(Cmd.hue(h, saturation: s))
                    self.write(Cmd.brightness(self.brightness))
                    // Restore the sync mode that was active before disconnect (e.g. after sleep)
                    let modeToRestore = self.lastSyncMode
                    self.lastSyncMode = .off
                    if modeToRestore != .off {
                        self.setSyncMode(modeToRestore)
                    } else if self.circadianEnabled {
                        self.applyCircadianCCT()
                    }
                }
            }
        }
    }

    // ACK from write-with-response — log failures only
    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didWriteValueFor characteristic: CBCharacteristic,
                                error: (any Error)?) {
        if let error {
            print("[LightStar] write error: \(error.localizedDescription)")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: (any Error)?) {
        guard let data = characteristic.value else { return }
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        let str = String(data: data, encoding: .utf8).map { "\"\($0)\"" } ?? ""
        let label = str.isEmpty ? hex : "\(hex)  \(str)"
        let line = "  READ \(characteristic.uuid): \(label)"
        print("[LightStar] \(line)")
        Task { @MainActor in
            self.deviceLog.append(line)
            self.saveDeviceInfoIfComplete()
            self.notifyTapHandler?(data)
        }
    }
}
