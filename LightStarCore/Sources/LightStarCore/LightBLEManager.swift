@preconcurrency import CoreBluetooth
import SwiftUI

@MainActor
@Observable
public final class LightBLEManager: NSObject {

    // MARK: - Types

    public enum ConnectionState: String {
        case disconnected, scanning, connecting, connected
    }

    public enum SyncMode: String, CaseIterable, Equatable {
        case off      = "Off"
        case video    = "Video"
        case audio    = "Audio"
        case combined = "Video+Audio"

        public var displayName: String {
            switch self {
            case .off:      return "Off"
            case .video:    return "Screen"
            case .audio:    return "Music"
            case .combined: return "Both"
            }
        }
    }

    // MARK: - Observable state

    public var connectionState: ConnectionState = .disconnected
    public var connectionError: String?   // set on scan timeout or reconnect exhaustion
    public var bleNeedsPermission = false  // true when BT is .unauthorized → show settings button
    public var isOn: Bool = UserDefaults.standard.object(forKey: "lastPowerState") as? Bool ?? false {
        didSet { UserDefaults.standard.set(isOn, forKey: "lastPowerState") }
    }
    public var colorHue: Double = UserDefaults.standard.object(forKey: "colorHue") as? Double ?? 0 {
        didSet { UserDefaults.standard.set(colorHue, forKey: "colorHue") }
    }
    public var colorSat: Double = UserDefaults.standard.object(forKey: "colorSat") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(colorSat, forKey: "colorSat") }
    }
    public var color: Color = {
        guard let h = UserDefaults.standard.object(forKey: "colorHue") as? Double,
              let s = UserDefaults.standard.object(forKey: "colorSat") as? Double else { return .white }
        return Color(hue: h, saturation: s, brightness: 1)
    }()
    public var brightness: Double = UserDefaults.standard.object(forKey: "brightness") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(brightness, forKey: "brightness") }
    }
    public var effectID: UInt8 = 0x01
    public var effectSpeed: Double = 0.5   // 0–1 mapped to 0–100
    public var effectForward: Bool = true
    public var effectModeActive = false
    public var colorTemperature: Double = 0.5  // 0=warm 2700K … 1=cool 6500K; not persisted as a mode flag
    // Sync state machine
    public var syncMode: SyncMode = .off
    public var syncColor: Color? = nil          // live color during sync; nil when sync is off
    public var syncError: String?
    public var syncNeedsPermission = false   // true when syncError is a Screen Recording denial
    public var pendingSyncMode: SyncMode?  // mode to retry when permission is granted
    public var syncTransitioning = false
    // Called after the connect sequence completes with no sync mode to restore
    public var onConnect: (@MainActor () -> Void)?
    public enum AudioSyncMode: String, CaseIterable { case rainbow = "Rainbow"; case pulse = "Pulse"; case frequency = "Frequency" }
    public var audioSyncMode: AudioSyncMode = .pulse
    public enum AudioInputSource: String, CaseIterable { case system = "System Audio"; case mic = "Microphone"; case stripMic = "Strip Mic" }
    public var audioInputSource: AudioInputSource = {
        guard let raw = UserDefaults.standard.string(forKey: "audioInputSource"),
              let v = AudioInputSource(rawValue: raw) else { return .system }
        return v
    }() {
        didSet {
            UserDefaults.standard.set(audioInputSource.rawValue, forKey: "audioInputSource")
            guard oldValue != audioInputSource else { return }
            if AudioInputSyncPolicy.shouldDisableStripMic(previous: oldValue, next: audioInputSource) {
                write(Cmd.stripMic(enabled: false))
            }
            if AudioInputSyncPolicy.shouldRestartSync(
                mode: syncMode, previous: oldValue, next: audioInputSource
            ) {
                setSyncMode(syncMode)
            }
        }
    }
    // Strip onboard mic settings (BC11 style, BC12 sensitivity)
    public enum MicStyle: Int, CaseIterable {
        case classic = 1, soft = 2, dynamic = 3, disco = 4
        public var label: String {
            switch self { case .classic: "Classic"; case .soft: "Soft"; case .dynamic: "Dynamic"; case .disco: "Disco" }
        }
    }
    public var micStyle: MicStyle = .classic {
        didSet { if audioInputSource == .stripMic { write(Cmd.micStyle(UInt8(micStyle.rawValue))) } }
    }
    // 0–255 mapped to 0.0–1.0 for slider
    public var micSensitivity: Double = UserDefaults.standard.object(forKey: "micSensitivity") as? Double ?? 0.5 {
        didSet {
            UserDefaults.standard.set(micSensitivity, forKey: "micSensitivity")
            if audioInputSource == .stripMic { write(Cmd.micSensitivity(Int(micSensitivity * 255))) }
        }
    }

    // LED strip hardware config
    public enum LEDChannelOrder: Int, CaseIterable {
        case rgb = 1, rbg = 2, grb = 3, gbr = 4, brg = 5, bgr = 6
        public var label: String {
            switch self { case .rgb: "RGB"; case .rbg: "RBG"; case .grb: "GRB"; case .gbr: "GBR"; case .brg: "BRG"; case .bgr: "BGR" }
        }
    }
    public var ledChannelOrder: LEDChannelOrder = .rgb {
        didSet { write(Cmd.channelOrder(UInt8(ledChannelOrder.rawValue))) }
    }
    public var ledPixelCount: Int = 30 {
        didSet {
            let n = max(8, min(300, ledPixelCount))
            if n != ledPixelCount { ledPixelCount = n; return }
            write(Cmd.pixelCount(n))
        }
    }

    // Display picker
    public var availableDisplays: [(id: CGDirectDisplayID, name: String)] = []
    public var selectedDisplayID: CGDirectDisplayID? = nil {
        didSet {
            guard isSyncingVideo, oldValue != selectedDisplayID else { return }
            setSyncMode(syncMode)  // restart with the new display
        }
    }
    public var syncResponsiveness: Double = UserDefaults.standard.object(forKey: "syncResponsiveness") as? Double ?? 0.7 {
        didSet { UserDefaults.standard.set(syncResponsiveness, forKey: "syncResponsiveness") }
    }
    // Beat sensitivity: 0 = very hard to trigger, 0.5 = default (flux > 0.60), 1 = very sensitive (flux > 0.20)
    public var beatSensitivity: Double = UserDefaults.standard.object(forKey: "beatSensitivity") as? Double ?? 0.5 {
        didSet { UserDefaults.standard.set(beatSensitivity, forKey: "beatSensitivity") }
    }
    // When true, video sync also drives strip brightness from average screen brightness
    public var videoSyncBrightness: Bool = UserDefaults.standard.bool(forKey: "videoSyncBrightness") {
        didSet { UserDefaults.standard.set(videoSyncBrightness, forKey: "videoSyncBrightness") }
    }

    public var isSyncingVideo: Bool { syncMode == .video || syncMode == .combined }
    public var isSyncingAudio: Bool { syncMode == .audio || syncMode == .combined }

    // MARK: - Color history (last 12 manually set colors)

    public var colorHistory: [(h: Double, s: Double)] = {
        guard let data = UserDefaults.standard.data(forKey: "colorHistory"),
              let arr = try? JSONDecoder().decode([[Double]].self, from: data) else { return [] }
        return arr.compactMap { $0.count >= 2 ? ($0[0], $0[1]) : nil }
    }()

    // MARK: - Circadian auto color temperature

    public var circadianEnabled: Bool = UserDefaults.standard.bool(forKey: "circadianEnabled") {
        didSet {
            UserDefaults.standard.set(circadianEnabled, forKey: "circadianEnabled")
            if circadianEnabled { startCircadianTimer() } else { stopCircadianTimer() }
        }
    }
    // nonisolated(unsafe): Timer is only created/invalidated on the main actor;
    // deinit must be able to invalidate it under Swift 6 isolation rules.
    nonisolated(unsafe) public var circadianTimer: Timer?

    // MARK: - Protocol probe
    public var probeLog: [String] = []
    public var probeRunning = false

    // MARK: - Device discovery log
    public var deviceLog: [String] = []
    public var capturedAdvertisementStrings: [String: String] = [:]
    public var capturedRSSI: Int = 0
    // MARK: - BLE UUIDs

    private static let serviceUUID    = CBUUID(string: "FFF0")
    private static let writeCharUUID  = CBUUID(string: "FFF3")
    private static let notifyCharUUID = CBUUID(string: "FFF4")
    private static let advertisedUUID = CBUUID(string: "2022")

    // MARK: - Multi-light

    public var multiLightEnabled: Bool = UserDefaults.standard.bool(forKey: "multiLightEnabled") {
        didSet {
            UserDefaults.standard.set(multiLightEnabled, forKey: "multiLightEnabled")
            if !multiLightEnabled {
                disconnectExtraLights()
#if !os(iOS)
                if BLEDiscoveryPolicy.shouldStopScanWhenDisablingMultiLight(connectionState: connectionState) {
                    central.stopScan()
                }
#endif
            } else {
#if !os(iOS)
                if BLEDiscoveryPolicy.shouldStartExtraScanWhenEnablingMultiLight(connectionState: connectionState),
                   central.state == .poweredOn {
                    central.scanForPeripherals(withServices: [Self.advertisedUUID], options: nil)
                }
#endif
            }
        }
    }
    // Names of all connected lights (primary first, then extras)
    public var connectedLightNames: [String] {
        var names: [String] = []
        if let n = peripheral?.name { names.append(n) }
        names += extraLights.compactMap { $0.peripheral.name }
        return names
    }

    // MARK: - Private state

    public var central: CBCentralManager!
    public var peripheral: CBPeripheral?
    public var writeChar: CBCharacteristic?
    public var extraLights: [(peripheral: CBPeripheral, writeChar: CBCharacteristic?)] = []
    public var reconnectTask: Task<Void, Never>?
    public var silenceTask: Task<Void, Never>?
    public var probeTask: Task<Void, Never>?
    // Set during probe sweeps to mirror BLE notifications into probeLog
    public var notifyTapHandler: ((Data) -> Void)?
    public var connectSequenceTask: Task<Void, Never>?
    var powerOffConfirmTask: Task<Void, Never>?
    public var connectWhenReady = false
    public var shouldAutoReconnect = false
    // Restored after reconnect and after full app restart
    public var lastSyncMode: SyncMode = {
        guard let raw = UserDefaults.standard.string(forKey: "lastSyncMode"),
              let v = SyncMode(rawValue: raw) else { return .off }
        return v
    }()
    /// True when sync was actually running at the last unexpected drop (or is
    /// still the launch restore target). User turning sync off clears this so
    /// reconnect does not start capture again.
    public var restoreSyncOnReconnect: Bool = {
        guard let raw = UserDefaults.standard.string(forKey: "lastSyncMode"),
              let v = SyncMode(rawValue: raw), v != .off else { return false }
        return true
    }()
    public var colorDebounce: Task<Void, Never>?
    public var reconnectAttempts = 0
    public let maxReconnectAttempts = 5
    public var userInitiatedDisconnect = false
    public var connectingTimeoutTask: Task<Void, Never>?
    private var scanTimeoutTask: Task<Void, Never>?
    public let connectingTimeoutNanos: UInt64 = 10_000_000_000
    public let systemAudio = SystemAudioSampler()
    public let micAudio = MicAudioSampler()
    public var transitionTask: Task<Void, Never>?
    public var fadeTask: Task<Void, Never>?
    public var syncCleanupTask: Task<Void, Never>?
    public var coalescer: BLEWriteCoalescer!
    public var beatHue: Double = 0
    public var flashLevel: Double = 0
    public var lastScreenH: Double = 0
    public var lastScreenS: Double = 1
    public var audioPulseH: Double = 0   // cached hue for pulse mode — avoids 30Hz hsvComponents
    public let screenSampler = ScreenColorSampler()
#if os(iOS)
    public let remoteClient = RemoteControlClient()
    var wantsMacStripConnection = false
#endif

    public override init() {
        super.init()
        if circadianEnabled { startCircadianTimer() }
#if os(iOS)
        coalescer = BLEWriteCoalescer(
            send: { [weak self] data in
                self?.remoteClient.sendWriteFrame(Array(data))
            },
            isConnected: { [weak self] in self?.connectionState == .connected }
        )
        configureRemoteTransport()
#else
        central = CBCentralManager(delegate: self, queue: .main)
        coalescer = BLEWriteCoalescer(
            send: { [weak self] data in
                self?.transmit(data)
            },
            isConnected: { [weak self] in self?.connectionState == .connected }
        )
#endif
    }

    deinit {
        circadianTimer?.invalidate()
    }

    // MARK: - Public API

    public func connect() {
#if os(iOS)
        connectViaMac()
#else
        guard connectionState == .disconnected else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0
        userInitiatedDisconnect = false
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
#endif
    }

    // Call when the user returns from System Settings after (potentially) granting
    // Bluetooth permission. Recreates CBCentralManager so it re-evaluates current
    // auth state and triggers the permission dialog if still notDetermined.
    public func retryBluetoothPermission() {
#if os(iOS)
        return
#else
        guard bleNeedsPermission else { return }
        bleNeedsPermission = false
        connectionError = nil
        connectionState = .disconnected
        connectWhenReady = true
        central = CBCentralManager(delegate: self, queue: .main)
#endif
    }

    public func disconnect() {
#if os(iOS)
        disconnectViaMac()
#else
        reconnectTask?.cancel()
        reconnectTask = nil
        silenceTask?.cancel()
        silenceTask = nil
        probeTask?.cancel()
        probeTask = nil
        connectSequenceTask?.cancel()
        connectSequenceTask = nil
        connectingTimeoutTask?.cancel()
        connectingTimeoutTask = nil
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        connectWhenReady = false
        shouldAutoReconnect = false
        userInitiatedDisconnect = true
        reconnectAttempts = 0
        bleNeedsPermission = false
        connectionError = nil
        stopSyncInline()
        lastSyncMode = .off
        restoreSyncOnReconnect = false
        UserDefaults.standard.set(SyncMode.off.rawValue, forKey: "lastSyncMode")
        coalescer.flush()
        if probeRunning {
            probeRunning = false
            notifyTapHandler = nil
        }
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        disconnectExtraLights()
        connectionState = .disconnected
#endif
    }

    /// iPhone "Connect strip" must not run a user disconnect: that forgets
    /// `lastSyncMode` and marks the drop as intentional.
    public func reconnectPreservingSync() {
        guard connectionState != .connected else { return }
        if StripReconnectPolicy.shouldDisconnectBeforeReconnect(connectionState) {
            let savedSync = lastSyncMode
            disconnect()
            lastSyncMode = savedSync
            UserDefaults.standard.set(savedSync.rawValue, forKey: "lastSyncMode")
            userInitiatedDisconnect = false
        }
        connect()
    }

    public func sendRaw(_ bytes: [UInt8]) {
        print("[LightStar] sendRaw: \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        write(bytes)
    }

    public func setPower(on: Bool) {
        isOn = on
        // Cancel connect-sequence task in both directions so it cannot overwrite isOn.
        connectSequenceTask?.cancel(); connectSequenceTask = nil
        powerOffConfirmTask?.cancel(); powerOffConfirmTask = nil
        if !on {
            // Cancel ALL pending async work before powerOff — any hue/brightness
            // packet arriving after powerOff wakes the BC/55 strip back up.
            colorDebounce?.cancel(); colorDebounce = nil
            stopSyncInline()
            coalescer.flush()
            writeNow(Cmd.powerOff)
            // Connect-sequence powerOff works because the ATT link is quiet.
            // Repeat once after streaming writes drain so firmware actually latches off.
            powerOffConfirmTask = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                guard !self.isOn, self.connectionState == .connected else { return }
                self.writeNow(Cmd.powerOff)
            }
        } else {
            writeNow(Cmd.powerOn)
        }
    }

    // MARK: - Private helpers

    private func disconnectExtraLights() {
        for light in extraLights { central.cancelPeripheralConnection(light.peripheral) }
        extraLights.removeAll()
    }

    private func extraLightIndex(of peripheral: CBPeripheral) -> Int? {
        var foundIdx: Int? = nil
        for (idx, light) in extraLights.enumerated() {
            if light.peripheral === peripheral {
                foundIdx = idx
                break
            }
        }
        return foundIdx
    }

    /// Power-cycle on connect (mirrors OEM app init). Hue/brightness after
    /// powerOff wakes the BC/55, so appearance and sync restore only when on.
    func startConnectSequence(targetOn: Bool) {
        connectSequenceTask?.cancel()
        powerOffConfirmTask?.cancel(); powerOffConfirmTask = nil
        connectSequenceTask = Task { @MainActor in
            self.writeNow(Cmd.powerOff)
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            if targetOn {
                self.writeNow(Cmd.powerOn)
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            }
            guard !Task.isCancelled else { return }
            self.isOn = targetOn
            if BLEDiscoveryPolicy.shouldRestoreAppearanceOnConnect(targetOn: targetOn) {
                let (h, s, _) = self.color.hsvComponents
                self.write(Cmd.hue(h, saturation: s))
                self.write(Cmd.brightness(self.brightness))
                // Keep lastSyncMode until restore succeeds or the user turns sync
                // off. Clearing it here races onConnect's default preset.
                if SyncReconnectPolicy.shouldRestoreSync(
                    wasActiveAtDisconnect: self.restoreSyncOnReconnect,
                    lastSyncMode: self.lastSyncMode
                ) {
                    self.setSyncMode(self.lastSyncMode)
                } else if self.circadianEnabled {
                    self.applyCircadianCCT()
                }
            }
            self.onConnect?()
        }
    }

    private func startScan() {
        guard central.state == .poweredOn else { return }
        connectionError = nil
        connectionState = .scanning
        scanTimeoutTask?.cancel()
        central.scanForPeripherals(withServices: [Self.advertisedUUID], options: nil)
        scanTimeoutTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            guard self.connectionState == .scanning else { return }
            self.central.stopScan()
            self.connectionState = .disconnected
            self.connectionError = "Device not found — make sure it's powered on"
        }
    }

    public func armConnectingTimeout(for peripheral: CBPeripheral) {
        connectingTimeoutTask?.cancel()
        connectingTimeoutTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: self.connectingTimeoutNanos) } catch { return }
            guard self.connectionState == .connecting else { return }
            self.central.cancelPeripheralConnection(peripheral)
            self.connectionState = .disconnected
            self.connectionError = "Connection timed out — is the light powered on?"
        }
    }

    public func enterConnecting(_ peripheral: CBPeripheral) {
        connectionState = .connecting
        armConnectingTimeout(for: peripheral)
    }

    // FFF3 is Write + Write Without Response. OEM uses ATT Write Command
    // (withoutResponse); Write Request stalls when the firmware never ACKs.
    public func write(_ bytes: [UInt8]) {
        guard bytes.count >= 2 else { return }
        guard StripPowerWritePolicy.shouldEnqueue(isOn: isOn, commandByte: bytes[1]) else { return }
        coalescer.enqueue(bytes)
    }

    func writeNow(_ bytes: [UInt8]) {
        guard bytes.count >= 2 else { return }
        guard StripPowerWritePolicy.shouldEnqueue(isOn: isOn, commandByte: bytes[1]) else { return }
        coalescer.sendNow(bytes)
    }

    private func transmit(_ data: Data) {
        if let p = peripheral, let ch = writeChar {
            attWrite(data, to: p, characteristic: ch)
        }
        for light in extraLights {
            guard let ch = light.writeChar else { continue }
            attWrite(data, to: light.peripheral, characteristic: ch)
        }
    }

    private func attWrite(_ data: Data, to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        let type: CBCharacteristicWriteType = StripATTWritePolicy.useWriteWithoutResponse(
            characteristicSupportsIt: characteristic.properties.contains(.writeWithoutResponse)
        ) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: characteristic, type: type)
    }

    private func scheduleReconnect() {
        guard !userInitiatedDisconnect else { return }
        guard reconnectAttempts < maxReconnectAttempts else {
            connectionState = .disconnected
            connectionError = "Could not reconnect — tap Connect to retry"
            return
        }
        reconnectAttempts += 1
        let delay = UInt64(min(30, pow(2.0, Double(reconnectAttempts)))) * 1_000_000_000
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard !Task.isCancelled, !self.userInitiatedDisconnect else { return }
            if let p = self.peripheral {
                self.enterConnecting(p)
                self.central.connect(p, options: nil)
            } else {
                self.startScan()
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension LightBLEManager: CBCentralManagerDelegate {

    public nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
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
                    self.reconnectTask?.cancel()
                    self.reconnectTask = nil
                    self.shouldAutoReconnect = false
                    self.reconnectAttempts = 0
                    if let p = self.peripheral {
                        self.enterConnecting(p)
                        self.central.connect(p, options: nil)
                    } else {
                        self.startScan()
                    }
                }
            case .poweredOff:
                if self.connectionState != .disconnected {
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

    public nonisolated func centralManager(_ central: CBCentralManager,
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
        // nonisolated(unsafe) suppresses Swift 6 sending checks for CoreBluetooth delegate parameters
        // which are thread-safe in practice as CoreBluetooth manages their lifecycle.
        nonisolated(unsafe) let discoveredPeripheral = peripheral
        nonisolated(unsafe) let centralManager = central
        Task { @MainActor in
            if BLEDiscoveryPolicy.shouldTreatAdvertisementAsExtraLight(
                multiLightEnabled: self.multiLightEnabled,
                primaryConnectionState: self.connectionState
            ) {
                // Extra light — connect without stopping scan (more may appear)
                guard discoveredPeripheral !== self.peripheral else { return }
                guard self.extraLightIndex(of: discoveredPeripheral) == nil else { return }
                discoveredPeripheral.delegate = self
                self.extraLights.append((peripheral: discoveredPeripheral, writeChar: nil))
                centralManager.connect(discoveredPeripheral, options: nil)
                return
            }
            if BLEDiscoveryPolicy.shouldIgnoreNonPrimaryAdvertisement(
                hasPrimaryPeripheral: self.peripheral != nil,
                primaryConnectionState: self.connectionState
            ) {
                return
            }
            if !BLEDiscoveryPolicy.shouldAdoptAdvertisementAsPrimary(
                isAlreadyExtra: self.extraLightIndex(of: discoveredPeripheral) != nil
            ) {
                return
            }
            if BLEDiscoveryPolicy.shouldStopScanOnPrimaryDiscovery(multiLightEnabled: self.multiLightEnabled) {
                centralManager.stopScan()
                self.scanTimeoutTask?.cancel()
                self.scanTimeoutTask = nil
            }
            self.peripheral = discoveredPeripheral
            self.capturedAdvertisementStrings = advStrings
            self.capturedRSSI = rssi
            discoveredPeripheral.delegate = self
            self.enterConnecting(discoveredPeripheral)
            centralManager.connect(discoveredPeripheral, options: nil)
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        nonisolated(unsafe) let connectedPeripheral = peripheral
        Task { @MainActor in
            self.reconnectTask?.cancel()
            self.reconnectTask = nil
            self.reconnectAttempts = 0
            self.deviceLog = ["Connecting to \(connectedPeripheral.name ?? "unknown")…"]
            // nil = discover ALL services (finds Device Info, DFU, etc.)
            connectedPeripheral.discoverServices(nil)
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: (any Error)?) {
        nonisolated(unsafe) let failedPeripheral = peripheral
        Task { @MainActor in
            if let idx = self.extraLightIndex(of: failedPeripheral) {
                self.extraLights.remove(at: idx)
            }
            let isPrimary = failedPeripheral === self.peripheral
            if BLEDiscoveryPolicy.shouldReconnectPrimaryAfterConnectFailure(failedIsPrimary: isPrimary) {
                self.scheduleReconnect()
            }
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: (any Error)?) {
        nonisolated(unsafe) let disconnectedPeripheral = peripheral
        Task { @MainActor in
            if let idx = self.extraLightIndex(of: disconnectedPeripheral) {
                self.extraLights.remove(at: idx)
                return
            }
            self.writeChar = nil
            self.connectingTimeoutTask?.cancel()
            self.connectingTimeoutTask = nil
            self.connectionState = .disconnected
            self.coalescer.flush()
            self.transitionTask?.cancel()
            self.connectSequenceTask?.cancel()
            self.connectSequenceTask = nil
            self.probeTask?.cancel()
            self.probeTask = nil
            self.stopSyncInline()
            // reconnectAttempts == max was the old "user disconnect" sentinel.
            // userInitiatedDisconnect is the explicit flag; backoff exhaustion
            // no longer silently kills future auto-reconnect.
            if error != nil && !self.userInitiatedDisconnect && self.reconnectAttempts < self.maxReconnectAttempts {
                self.shouldAutoReconnect = true
                self.scheduleReconnect()
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension LightBLEManager: CBPeripheralDelegate {

    public nonisolated func peripheral(_ peripheral: CBPeripheral,
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

    public nonisolated func peripheral(_ peripheral: CBPeripheral,
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
        nonisolated(unsafe) let discoveredPeripheral = peripheral
        Task { @MainActor in
            if let idx = self.extraLightIndex(of: discoveredPeripheral) {
                if let ch = chars.first(where: { $0.uuid == Self.writeCharUUID }) {
                    self.extraLights[idx].writeChar = ch
                    print("[LightStar] extra light ready: \(discoveredPeripheral.name ?? "unknown")")
                }
                return
            }
            let writeCharWasNil = self.writeChar == nil
            for char in chars {
                if char.uuid == Self.writeCharUUID {
                    self.writeChar = char
                    print("[LightStar] write char ready: \(char.uuid) props:\(char.properties.rawValue)")
                }
                if char.properties.contains(.notify) {
                    discoveredPeripheral.setNotifyValue(true, for: char)
                }
                // Read any readable characteristic — gets manufacturer, model, firmware version
                if char.properties.contains(.read) {
                    discoveredPeripheral.readValue(for: char)
                }
            }
            if BLEDiscoveryPolicy.shouldStartConnectSequence(writeCharAlreadyReady: !writeCharWasNil),
               self.writeChar != nil {
                self.connectingTimeoutTask?.cancel()
                self.connectingTimeoutTask = nil
                self.connectionState = .connected
                self.connectionError = nil
                self.sendTimeSync()
                let targetOn = self.isOn  // respect persisted power state from before disconnect
                self.startConnectSequence(targetOn: targetOn)
            }
        }
    }

    // ACK from write-with-response — log failures only
    public nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didWriteValueFor characteristic: CBCharacteristic,
                                error: (any Error)?) {
        if let error {
            print("[LightStar] write error: \(error.localizedDescription)")
            Task { @MainActor in
                self.connectionError = "Write failed: \(error.localizedDescription)"
            }
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral,
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

/// BLE connect / scan decisions extracted so they can be regression-tested
/// without a CoreBluetooth stack.
public enum BLEDiscoveryPolicy: Sendable {
    public static func shouldStopScanOnPrimaryDiscovery(multiLightEnabled: Bool) -> Bool {
        !multiLightEnabled
    }

    /// Extra lights are only attached while the primary is actually connected.
    /// `peripheral != nil` is not enough: disconnect keeps the CBPeripheral for
    /// reconnect, and treating that leftover as "already have a primary" swallows
    /// rediscovery of the primary itself.
    public static func shouldTreatAdvertisementAsExtraLight(
        multiLightEnabled: Bool,
        primaryConnectionState: LightBLEManager.ConnectionState
    ) -> Bool {
        multiLightEnabled && primaryConnectionState == .connected
    }

    /// While connecting or already connected, a second advertisement must not
    /// replace the in-flight / live primary. Scanning after a drop with a leftover
    /// peripheral is allowed to adopt whoever is discovered as the new primary.
    public static func shouldIgnoreNonPrimaryAdvertisement(
        hasPrimaryPeripheral: Bool,
        primaryConnectionState: LightBLEManager.ConnectionState
    ) -> Bool {
        hasPrimaryPeripheral
            && (primaryConnectionState == .connecting || primaryConnectionState == .connected)
    }

    /// After a primary drop, extras stay in `extraLights`. Their advertisements
    /// must not replace `self.peripheral` or GATT discovery treats them as extras
    /// and never starts the connect sequence.
    public static func shouldAdoptAdvertisementAsPrimary(isAlreadyExtra: Bool) -> Bool {
        !isAlreadyExtra
    }

    public static func shouldStopScanWhenDisablingMultiLight(
        connectionState: LightBLEManager.ConnectionState
    ) -> Bool {
        connectionState == .connected
    }

    public static func shouldStartExtraScanWhenEnablingMultiLight(
        connectionState: LightBLEManager.ConnectionState
    ) -> Bool {
        connectionState == .connected
    }

    public static func shouldReconnectPrimaryAfterConnectFailure(failedIsPrimary: Bool) -> Bool {
        failedIsPrimary
    }

    public static func shouldStartConnectSequence(writeCharAlreadyReady: Bool) -> Bool {
        !writeCharAlreadyReady
    }

    /// Hue/brightness after powerOff wakes the BC/55 (see `setPower`).
    public static func shouldRestoreAppearanceOnConnect(targetOn: Bool) -> Bool {
        targetOn
    }
}

/// PacketLogger: Miracles Star sends ATT Write Command on FFF3. Write Request
/// (withResponse) waits for an ATT response the firmware never sends, so later
/// frames — including powerOff — sit in CoreBluetooth until disconnect.
public enum StripATTWritePolicy: Sendable {
    public static func useWriteWithoutResponse(characteristicSupportsIt: Bool) -> Bool {
        characteristicSupportsIt
    }
}

/// Remote "Connect strip" while scanning/connecting may abort the in-flight
/// attempt, but a fully disconnected strip must not run `disconnect()`.
public enum StripReconnectPolicy: Sendable {
    public static func shouldDisconnectBeforeReconnect(_ state: LightBLEManager.ConnectionState) -> Bool {
        switch state {
        case .connected, .disconnected:
            return false
        case .scanning, .connecting:
            return true
        }
    }
}

/// Display-sleep wake must not undo an explicit user disconnect.
public enum WakeReconnectPolicy: Sendable {
    public static func shouldReconnect(
        autoConnect: Bool,
        connectionState: LightBLEManager.ConnectionState,
        userInitiatedDisconnect: Bool
    ) -> Bool {
        autoConnect && connectionState == .disconnected && !userInitiatedDisconnect
    }
}

/// lastSyncMode is the toggle restore target. Connect resume is separate:
/// only restore capture if it was actually running when the link dropped.
public enum SyncModePersistence: Sendable {
    public static func lastSyncModeToPersist(
        previous: LightBLEManager.SyncMode,
        next: LightBLEManager.SyncMode
    ) -> LightBLEManager.SyncMode? {
        guard next == .off, previous != .off else { return nil }
        return previous
    }
}

public enum SyncReconnectPolicy: Sendable {
    public static func shouldRestoreSync(
        wasActiveAtDisconnect: Bool,
        lastSyncMode: LightBLEManager.SyncMode
    ) -> Bool {
        wasActiveAtDisconnect && lastSyncMode != .off
    }

    public static func restoreFlagAfterUserTurnsSyncOff() -> Bool { false }

    public static func restoreFlagAfterSyncInterrupted(wasSyncing: Bool) -> Bool { wasSyncing }
}

/// Combined stays `.combined` whenever either sampler is up. Falling through
/// to `.audio` when screen failed used to start Music rainbow and steal hue.
public enum CombinedSyncAssembly: Sendable {
    public static func resolvedMode(screenAvailable: Bool, audioAvailable: Bool) -> LightBLEManager.SyncMode {
        switch (screenAvailable, audioAvailable) {
        case (true, true): return .combined
        case (true, false): return .video
        case (false, true): return .combined
        case (false, false): return .off
        }
    }
}

/// Independent ownership per sync mode:
/// - Screen: BC04 hue (optional BC05 if Follow-screen-brightness)
/// - Music: BC05 brightness; Rainbow/Frequency may also write BC09
/// - Both: screen BC04 + audio BC05 only — never BC09, never suppress screen hue
public enum CombinedSyncMixer: Sendable {
    /// `flashLevel` decays by 0.82 per 30 Hz audio tick. Used for brightness pulse only.
    public static let beatFlashHold: Double = 0.5

    public static func screenShouldWriteBrightness(
        mode: LightBLEManager.SyncMode,
        videoSyncBrightness: Bool
    ) -> Bool {
        mode == .video && videoSyncBrightness
    }

    public static func screenShouldWriteHue(
        mode: LightBLEManager.SyncMode,
        flashLevel: Double
    ) -> Bool {
        _ = flashLevel
        switch mode {
        case .video, .combined: return true
        case .audio, .off: return false
        }
    }

    public static func audioShouldWriteStreamingHue(
        mode: LightBLEManager.SyncMode,
        audioSyncMode: LightBLEManager.AudioSyncMode
    ) -> Bool {
        mode == .audio && audioSyncMode != .pulse
    }

    public static func shouldRestoreScreenHueAfterFlash(previousFlash: Double, nextFlash: Double) -> Bool {
        _ = previousFlash
        _ = nextFlash
        return false
    }

    /// Screen color stays visible at the user's brightness; beats lift toward full.
    /// The old bass-only curve collapsed to ~4% between beats, so Combined looked off.
    public static func combinedBrightness(
        userBrightness: Double,
        bass: Double,
        rms: Double,
        flashLevel: Double
    ) -> Double {
        let floor = min(1.0, max(0.15, userBrightness))
        let pulse = min(1.0, max(0.0, flashLevel * 0.9 + bass * 0.35 + rms * 0.15))
        return min(1.0, floor + (1.0 - floor) * pulse)
    }
}

/// Quiet passages and "I have not hit play yet" must not end Music or Combined.
public enum SilenceAutoOffPolicy: Sendable {
    public static func shouldTurnAudioSyncOff(silentFor: TimeInterval) -> Bool {
        false
    }
}

/// Combined mixer needs Mac-side `FrequencyBands` (BC05 brightness pulse).
/// The audio-only picker persists `.mic` / `.stripMic`; using those in combined
/// skips `setupAudioCallback` or re-arms the leftover sampler after teardown.
public enum AudioInputSyncPolicy: Sendable {
    public static func effectiveSource(
        mode: LightBLEManager.SyncMode,
        selected: LightBLEManager.AudioInputSource
    ) -> LightBLEManager.AudioInputSource {
        mode == .combined ? .system : selected
    }

    public static func shouldRestartSync(
        mode: LightBLEManager.SyncMode,
        previous: LightBLEManager.AudioInputSource,
        next: LightBLEManager.AudioInputSource
    ) -> Bool {
        guard previous != next else { return false }
        switch mode {
        case .audio: return true
        case .combined:
            return effectiveSource(mode: .combined, selected: previous)
                != effectiveSource(mode: .combined, selected: next)
        default: return false
        }
    }

    public static func shouldDisableStripMic(
        previous: LightBLEManager.AudioInputSource,
        next: LightBLEManager.AudioInputSource
    ) -> Bool {
        previous == .stripMic && next != .stripMic
    }
}
