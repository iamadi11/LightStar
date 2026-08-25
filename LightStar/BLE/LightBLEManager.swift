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
    private var pendingSyncMode: SyncMode?  // mode to retry when permission is granted
    var syncTransitioning = false
    // Called after the connect sequence completes with no sync mode to restore
    var onConnect: (@MainActor () -> Void)?
    enum AudioSyncMode: String, CaseIterable { case rainbow = "Rainbow"; case pulse = "Pulse"; case frequency = "Frequency" }
    var audioSyncMode: AudioSyncMode = .rainbow
    enum AudioInputSource: String, CaseIterable { case system = "System Audio"; case mic = "Microphone" }
    var audioInputSource: AudioInputSource = {
        guard let raw = UserDefaults.standard.string(forKey: "audioInputSource"),
              let v = AudioInputSource(rawValue: raw) else { return .system }
        return v
    }() {
        didSet {
            UserDefaults.standard.set(audioInputSource.rawValue, forKey: "audioInputSource")
            guard syncMode == .audio, oldValue != audioInputSource else { return }
            setSyncMode(.audio)  // restart with the new input source
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

    private func recordColorHistory(_ h: Double, _ s: Double) {
        guard s > 0.05 else { return }   // skip near-whites
        colorHistory = ([(h, s)] + colorHistory.filter {
            abs($0.h - h) > 0.03 || abs($0.s - s) > 0.08
        }).prefix(12).map { $0 }
        let encoded = colorHistory.map { [$0.h, $0.s] }
        UserDefaults.standard.set(try? JSONEncoder().encode(encoded), forKey: "colorHistory")
    }

    // MARK: - Circadian auto color temperature

    var circadianEnabled: Bool = UserDefaults.standard.bool(forKey: "circadianEnabled") {
        didSet {
            UserDefaults.standard.set(circadianEnabled, forKey: "circadianEnabled")
            if circadianEnabled { startCircadianTimer() } else { stopCircadianTimer() }
        }
    }
    private var circadianTimer: Timer?

    private func startCircadianTimer() {
        circadianTimer?.invalidate()
        applyCircadianCCT()
        circadianTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyCircadianCCT() }
        }
    }

    private func stopCircadianTimer() {
        circadianTimer?.invalidate()
        circadianTimer = nil
    }

    private func applyCircadianCCT() {
        guard circadianEnabled, connectionState == .connected, isOn, syncMode == .off else { return }
        setColorTemperature(Self.circadianCCTValue())
    }

    // Maps current time to a 0–1 CCT value (0=2700K warm, 1=6500K cool).
    static func circadianCCTValue(for date: Date = .now) -> Double {
        let cal = Calendar.current
        let h = Double(cal.component(.hour, from: date))
        let m = Double(cal.component(.minute, from: date))
        let t = h + m / 60.0        // 0…24
        switch t {
        case 6..<12:  return (t - 6) / 6.0           // ramp up: 0→1 (warm→cool)
        case 12..<17: return 1.0                      // peak daylight
        case 17..<22: return 1.0 - (t - 17) / 5.0   // ramp down: 1→0 (cool→warm)
        default:      return 0.0                      // night: warm
        }
    }

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

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var extraLights: [(peripheral: CBPeripheral, writeChar: CBCharacteristic?)] = []
    private var reconnectTask: Task<Void, Never>?
    var probeTask: Task<Void, Never>?
    // Set during probe sweeps to mirror BLE notifications into probeLog
    var notifyTapHandler: ((Data) -> Void)?
    private var connectSequenceTask: Task<Void, Never>?
    private var connectWhenReady = false       // deferred connect until BT powered on
    private var shouldAutoReconnect = false    // true on unexpected drop; false on manual disconnect
    // Restored after reconnect and after full app restart
    private var lastSyncMode: SyncMode = {
        guard let raw = UserDefaults.standard.string(forKey: "lastSyncMode"),
              let v = SyncMode(rawValue: raw) else { return .off }
        return v
    }()
    private var colorDebounce: Task<Void, Never>?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private let systemAudio = SystemAudioSampler()
    private let micAudio = MicAudioSampler()
    private var transitionTask: Task<Void, Never>?
    private var fadeTask: Task<Void, Never>?
    private var coalescer: BLEWriteCoalescer!
    private var beatHue: Double = 0
    private var flashLevel: Double = 0
    private var lastScreenH: Double = 0
    private var lastScreenS: Double = 1
    private var audioPulseH: Double = 0   // cached hue for pulse mode — avoids 30Hz hsvComponents
    private let screenSampler = ScreenColorSampler()

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

    func sendRaw(_ bytes: [UInt8]) {
        print("[LightStar] sendRaw: \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        write(bytes)
    }

    // Preferred over setColor — avoids lossy Color→NSColor→getHue round-trip.
    func setHue(_ h: Double, saturation s: Double) {
        if syncMode != .off { stopSyncInline() }
        color = Color(hue: h, saturation: s, brightness: 1)
        UserDefaults.standard.set(h, forKey: "colorHue")
        UserDefaults.standard.set(s, forKey: "colorSat")
        recordColorHistory(h, s)
        audioPulseH = h
        effectModeActive = false
        fadeTask?.cancel()
        colorDebounce?.cancel()
        colorDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            self.write(Cmd.hue(h, saturation: s))
            self.write(Cmd.brightness(self.brightness))
        }
    }

    func setColor(_ newColor: Color) {
        let (h, s, _) = newColor.hsvComponents
        setHue(h, saturation: s)
    }

    // Color temperature 0=warm 2700K … 1=cool 6500K.
    // Converts Kelvin → blackbody-approximated RGB → HSV, then writes hue.
    func setColorTemperature(_ t: Double) {
        let kelvin = 2700 + t * 3800   // 2700–6500 K
        let (h, s) = kelvinToHS(kelvin)
        setHue(h, saturation: s)
    }

    // Approximation: low K = warm orange, mid = white, high K = cool blue-white.
    // Uses simple linear interpolation across three anchor points.
    private func kelvinToHS(_ k: Double) -> (Double, Double) {
        // Anchors: 2700K=warm orange, 4000K=neutral, 6500K=cool blue
        switch k {
        case ..<3350:
            let t = (k - 2700) / 650    // 0…1 within 2700–3350
            let h = 0.08 - t * 0.02     // 0.08 (warm orange) → 0.06 (yellow-white)
            let s = 0.8 - t * 0.5       // 0.8 → 0.3
            return (h, s)
        case ..<5000:
            let t = (k - 3350) / 1650   // 0…1 within 3350–5000
            let h = 0.06 - t * 0.06     // 0.06 → 0.0 (white)
            let s = 0.3 - t * 0.3       // 0.3 → 0.0 (pure white)
            return (h, s)
        default:
            let t = min(1.0, (k - 5000) / 1500)   // 0…1 within 5000–6500
            let h = 0.55 + t * 0.08     // 0.55 → 0.63 (cool blue-white)
            let s = t * 0.25            // 0.0 → 0.25
            return (h, s)
        }
    }

    func setBrightness(_ value: Double) {
        if syncMode != .off { stopSyncInline() }
        brightness = value
        write(Cmd.brightness(value))
    }

    func setEffect(id: UInt8) {
        stopSyncInline()
        effectID = id
        effectModeActive = true
        write(Cmd.effect(id: id))
        write(Cmd.speed(effectSpeed))
    }

    func setEffectSpeed(_ value: Double) {
        effectSpeed = value
        write(Cmd.speed(value))
    }

    func exitEffectMode() {
        effectModeActive = false
        // BC13 animations run in device firmware — BC04+BC05 alone can't stop them.
        // Power-cycle (OFF→ON) is the only reliable reset, then restore solid color.
        Task { @MainActor in
            // BC06 effects run in device firmware — power-cycle is the only reliable reset.
            self.write(Cmd.powerOff)
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.write(Cmd.powerOn)
            try? await Task.sleep(nanoseconds: 200_000_000)
            let (h, s, _) = self.color.hsvComponents
            self.write(Cmd.hue(h, saturation: s))
            self.write(Cmd.brightness(self.brightness))
        }
    }

    // MARK: - Sync state machine

    func toggleSync() {
        setSyncMode(syncMode == .off ? (lastSyncMode == .off ? .video : lastSyncMode) : .off)
    }

    func setSyncMode(_ mode: SyncMode) {
        let prevMode = syncMode
        transitionTask?.cancel()
        syncTransitioning = true
        syncError = nil
        syncNeedsPermission = false
        transitionTask = Task { @MainActor in
            await self.teardownSync()
            guard !Task.isCancelled else {
                self.syncTransitioning = false
                return
            }
            await self.buildSync(mode, previousMode: prevMode)
            if !Task.isCancelled { self.syncTransitioning = false }
        }
    }

    private func teardownSync() async {
        fadeTask?.cancel()
        systemAudio.onBands = nil
        micAudio.onBands = nil
        screenSampler.onColor = nil
        flashLevel = 0
        await systemAudio.stop()
        await micAudio.stop()
        await screenSampler.stop()
    }

    // Synchronously tears down all sync state — safe to call from non-async context.
    private func stopSyncInline() {
        transitionTask?.cancel(); transitionTask = nil
        probeTask?.cancel(); probeTask = nil
        syncTransitioning = false
        systemAudio.onBands = nil
        micAudio.onBands = nil
        screenSampler.onColor = nil
        flashLevel = 0
        syncMode = .off
        syncColor = nil
        Task { await self.systemAudio.stop(); await self.micAudio.stop(); await self.screenSampler.stop() }
    }

    private func buildSync(_ mode: SyncMode, previousMode: SyncMode = .off) async {
        effectModeActive = false
        guard mode == .off || connectionState == .connected else {
            syncMode = .off
            syncError = "Not connected"
            return
        }
        switch mode {
        case .off:
            syncMode = .off
            fadeToSteadyState(from: previousMode)

        case .video:
            setupScreenCallback()
            screenSampler.selectedDisplayID = selectedDisplayID
            do {
                try await screenSampler.start()
                syncMode = .video
            } catch {
                screenSampler.onColor = nil
                syncMode = .off
                setSyncError(error)
                restoreSteadyState()
            }

        case .audio:
            let (h, _, _) = color.hsvComponents
            beatHue = h
            audioPulseH = h
            let useMic = audioInputSource == .mic
            setupAudioCallback(useMic: useMic)
            do {
                if useMic { try await micAudio.start() } else { try await systemAudio.start() }
                syncMode = .audio
            } catch {
                if useMic { micAudio.onBands = nil } else { systemAudio.onBands = nil }
                syncMode = .off
                setSyncError(error)
                restoreSteadyState()
            }

        case .combined:
            setupScreenCallback()
            setupAudioCallback()
            screenSampler.selectedDisplayID = selectedDisplayID
            var screenErr: Error? = nil
            var audioErr:  Error? = nil
            // Start both streams concurrently — total latency = max(screen, audio)
            async let screenStart: () = screenSampler.start()
            async let audioStart: () = systemAudio.start()
            do { try await screenStart } catch { screenSampler.onColor = nil; screenErr = error }
            do { try await audioStart  } catch { systemAudio.onBands  = nil; audioErr  = error }
            let screenOk = screenSampler.onColor != nil
            let audioOk  = systemAudio.onBands  != nil
            syncMode = screenOk && audioOk ? .combined
                     : screenOk           ? .video
                     : audioOk            ? .audio
                     :                     .off
            // Prefer permission error so UI shows "Open Settings"
            if let e = screenErr ?? audioErr { setSyncError(e) }
            if syncMode == .off { restoreSteadyState() }
        }
    }

    private func setupScreenCallback() {
        var smoothH: Double = -1
        var smoothS: Double = 0
        var smoothV: Double = -1
        var lastWrite: Double = 0
        screenSampler.onColor = { [weak self] h, s, v in
            guard let self, self.isSyncingVideo, self.isOn else { return }
            guard v > 0.04 else { return }
            let now = CACurrentMediaTime()
            guard now - lastWrite >= 1.0 / 20.0 else { return }
            let α = self.syncResponsiveness
            if smoothH < 0 { smoothH = h; smoothS = s; smoothV = v }  // first sample
            // Hue EMA with wraparound — go the short way around the circle
            var dh = h - smoothH
            if dh > 0.5 { dh -= 1 }; if dh < -0.5 { dh += 1 }
            smoothH = (smoothH + dh * α).truncatingRemainder(dividingBy: 1)
            if smoothH < 0 { smoothH += 1 }
            smoothS = smoothS + (s - smoothS) * α
            smoothV = smoothV + (v - smoothV) * 0.15  // gentle brightness tracking
            let hueDelta = min(abs(smoothH - (self.lastScreenH)), 1 - abs(smoothH - self.lastScreenH))
            guard hueDelta > 0.008 || now - lastWrite > 0.5 else { return }
            lastWrite = now
            let boostedS = smoothS < 0.3 ? min(1.0, smoothS * 3.0) : min(1.0, smoothS * 1.5)
            self.lastScreenH = smoothH
            self.lastScreenS = boostedS
            self.syncColor = Color(hue: smoothH, saturation: boostedS, brightness: 1)
            self.write(Cmd.hue(smoothH, saturation: boostedS))
            if self.videoSyncBrightness {
                self.write(Cmd.brightness(min(1.0, max(0.05, smoothV * 1.3))))
            }
        }
    }

    private func setupAudioCallback(useMic: Bool = false) {
        var lastWrite: Double = 0
        var silenceStart: Double = 0   // CACurrentMediaTime() when silence began (0 = not silent)
        let callback: (FrequencyBands) -> Void = { [weak self] (bands: FrequencyBands) in
            guard let self, self.isSyncingAudio, self.isOn else { return }
            let now = CACurrentMediaTime()

            // Silence detection: fade to steady state after 2 s of quiet
            if bands.rms < 0.01 {
                if silenceStart == 0 { silenceStart = now }
                if now - silenceStart >= 2.0 {
                    silenceStart = 0
                    Task { @MainActor [weak self] in
                        guard let self, self.isSyncingAudio else { return }
                        self.setSyncMode(.off)
                    }
                    return
                }
            } else {
                silenceStart = 0
            }

            guard now - lastWrite >= 1.0 / 30.0 else { return }
            lastWrite = now

            // Beat detection using configurable flux threshold:
            // sensitivity 0.5 → threshold 0.60 (default), 1.0 → 0.20 (very sensitive)
            let beatThreshold = 1.0 - self.beatSensitivity * 0.8
            let isBeat = bands.flux > beatThreshold && bands.rms > 0.03

            if self.syncMode == .combined {
                if isBeat {
                    self.flashLevel = 1.0
                    self.write(Cmd.hue(self.lastScreenH, saturation: min(1.0, self.lastScreenS * 1.3 + 0.15)))
                } else {
                    self.flashLevel = max(0.0, self.flashLevel * 0.82)
                }
                self.syncColor = Color(hue: self.lastScreenH, saturation: self.lastScreenS, brightness: 1)
                let bri = min(1.0, max(0.04, bands.bass * 0.55 + bands.rms * 0.15 + self.flashLevel * 0.80))
                self.write(Cmd.brightness(bri))
                return
            }

            switch self.audioSyncMode {
            case .rainbow:
                if isBeat {
                    self.beatHue = (self.beatHue + 1.0/12.0).truncatingRemainder(dividingBy: 1.0)
                } else {
                    self.beatHue = (self.beatHue + bands.high * 0.006).truncatingRemainder(dividingBy: 1.0)
                }
                let rainbowS = min(1.0, 0.6 + bands.mid * 0.4)
                self.syncColor = Color(hue: self.beatHue, saturation: rainbowS, brightness: 1)
                self.write(Cmd.audioHue(self.beatHue, saturation: rainbowS))
                self.write(Cmd.brightness(min(1.0, max(0.05, bands.bass * 1.3 + bands.rms * 0.3))))
            case .pulse:
                self.syncColor = Color(hue: self.audioPulseH, saturation: 1.0, brightness: 1)
                self.write(Cmd.audioHue(self.audioPulseH, saturation: min(1.0, 0.8 + bands.mid * 0.2)))
                self.write(Cmd.brightness(min(1.0, max(0.03, bands.bass * 1.5 + bands.rms * 0.2))))
            case .frequency:
                // Hue blends mid→green and high→blue; bass excluded from denominator so
                // bass-heavy music doesn't pull hue toward zero (red) unintentionally.
                let hTotal = bands.mid + bands.high + 0.001
                let h = (bands.mid * (120/360.0) + bands.high * (240/360.0)) / hTotal
                self.syncColor = Color(hue: h, saturation: 1.0, brightness: 1)
                self.write(Cmd.audioHue(h, saturation: 1.0))
                self.write(Cmd.brightness(min(1.0, max(0.05, (bands.bass + bands.mid + bands.high) / 3 * 1.5 + bands.rms * 0.2))))
            }
        }
        if useMic { micAudio.onBands = callback } else { systemAudio.onBands = callback }
    }

    private func setSyncError(_ error: Error) {
        let nsErr = error as NSError
        // Mic denial from MicAudioSampler
        if nsErr.domain == "MicAudio" && nsErr.code == -5001 {
            syncNeedsPermission = true
            syncError = "Microphone access required. Open Privacy & Security → Microphone and enable LightStar. (Re-grant required after each update.)"
            pendingSyncMode = syncMode == .off ? pendingSyncMode : syncMode
            return
        }
        // SCStreamError.userDeclined = -3801; also catches .notEntitled (-3827)
        let isPermission = nsErr.code == -3801 || nsErr.code == -3827
            || nsErr.domain.contains("ScreenCaptureKit")
        syncNeedsPermission = isPermission
        syncError = isPermission
            ? "Screen Recording access required. Open Privacy & Security → Screen Recording and enable LightStar. (Re-grant required after each update.)"
            : error.localizedDescription
        if isPermission {
            pendingSyncMode = syncMode == .off ? pendingSyncMode : syncMode
        }
    }

    // Called by AppDelegate when app becomes active (returns from System Settings).
    // If a sync mode failed due to permissions, retry it automatically.
    func retryPendingSyncIfNeeded() {
        guard syncNeedsPermission, let mode = pendingSyncMode else { return }
        pendingSyncMode = nil
        syncNeedsPermission = false
        syncError = nil
        setSyncMode(mode)
    }

    private func restoreSteadyState() {
        guard isOn else { return }
        let (h, s, _) = color.hsvComponents
        write(Cmd.hue(h, saturation: s))
        write(Cmd.brightness(brightness))
    }

    private func fadeToSteadyState(from prevMode: SyncMode) {
        guard isOn else { return }
        let (targetH, targetS, _) = color.hsvComponents
        let targetBri = brightness

        // Pick start values from the last-known live strip state
        let startH: Double
        let startS: Double
        let startBri: Double
        switch prevMode {
        case .video, .combined:
            startH = lastScreenH
            startS = lastScreenS
            startBri = targetBri  // video doesn't drive brightness; slider value unchanged
        case .audio:
            startH = audioPulseH
            startS = 0.9
            startBri = 1.0  // audio sync drives brightness high on beats
        case .off:
            restoreSteadyState(); return
        }

        // Skip fade if strip is already close to target
        let hueDist = min(abs(startH - targetH), 1.0 - abs(startH - targetH))
        guard hueDist > 0.02 || abs(startS - targetS) > 0.05 || abs(startBri - targetBri) > 0.05 else {
            restoreSteadyState(); return
        }

        fadeTask = Task { @MainActor in
            let steps = 18  // ~300ms at 60Hz
            for i in 1...steps {
                guard !Task.isCancelled else { return }
                let t = Double(i) / Double(steps)
                let e = t < 0.5 ? 2*t*t : -1 + (4 - 2*t)*t  // ease-in-out

                var dH = targetH - startH
                if dH > 0.5 { dH -= 1.0 }
                if dH < -0.5 { dH += 1.0 }
                var h = (startH + dH * e).truncatingRemainder(dividingBy: 1.0)
                if h < 0 { h += 1.0 }
                let s = max(0, min(1, startS + (targetS - startS) * e))
                let bri = max(0, min(1, startBri + (targetBri - startBri) * e))

                self.write(Cmd.hue(h, saturation: s))
                self.write(Cmd.brightness(bri))
                do { try await Task.sleep(nanoseconds: 16_700_000) }
                catch { return }  // cancelled — leave strip at last written color
            }
            self.restoreSteadyState()
        }
    }

    func loadAvailableDisplays() {
        Task {
            let displays = await ScreenColorSampler.availableDisplays()
            await MainActor.run { self.availableDisplays = displays }
        }
    }

    // MARK: - Protocol dump (debug)

    // MARK: - Device info save

    func saveDeviceLog() {
        guard !deviceLog.isEmpty else { return }
        let ts = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/lightstar-device-info-\(ts).txt")
        let content = "=== LightStar Device Info ===\n" + deviceLog.joined(separator: "\n")
        try? content.write(to: url, atomically: true, encoding: .utf8)
        deviceLog.append("Saved → \(url.lastPathComponent)")
    }

    // Full protocol + device backup — call from Debug tab "Backup" button.
    // Saves human-readable .txt and machine-readable .json to Desktop.
    func saveFullBackup() {
        let ts = Int(Date().timeIntervalSince1970)
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let base = desktop.appendingPathComponent("lightstar-backup-\(ts)").path

        // ── Human-readable text ──────────────────────────────────────────
        var txt = """
        ╔══════════════════════════════════════════════════════╗
        ║          LightStar — Device Backup                   ║
        ╚══════════════════════════════════════════════════════╝
        Date: \(Date())

        ── Advertisement ────────────────────────────────────────
        RSSI: \(capturedRSSI) dBm
        Name: \(peripheral?.name ?? "unknown")
        UUID: \(peripheral?.identifier.uuidString ?? "unknown")

        """
        for (k, v) in capturedAdvertisementStrings.sorted(by: { $0.key < $1.key }) {
            txt += "  \(k): \(v)\n"
        }

        txt += "\n── GATT Profile ─────────────────────────────────────\n"
        txt += deviceLog.joined(separator: "\n")

        txt += """


        ── Known BC/55 Commands (confirmed via APK reverse-engineering 2026-08-26) ──
        Frame: BC [cmd] [data_len] [data × data_len] 55
        Transport: ATT Write-with-Response on FFF3
        Service: 0000FFF0-0000-1000-8000-00805F9B34FB
        Notify:  0000FFF4-0000-1000-8000-00805F9B34FB (device never sends)
        Scan UUID: 0x2022 (filterByte1=0x22 filterByte2=0x20)

        BC01 01 01 00 55          — Power OFF
        BC01 01 01 01 55          — Power ON
        BC04 06 H_hi H_lo S_hi S_lo 00 00 55  — Hue (0–360 BE) + Sat (0–1000 BE), static
        BC05 06 B_hi B_lo 00 00 00 00 55       — Brightness (100–1000 BE)
        BC06 02 [hi] [lo] 55      — Effect mode (58 IDs: see knownEffects in BLEProtocol.swift)
        BC07 01 [0/1] 55          — Effect direction (0=backward 1=forward)
        BC08 01 [0–100] 55        — Effect speed
        BC09 06 H_hi H_lo S_hi S_lo 00 00 55  — Streaming color (used during phone-mic audio sync)
        BC0F 01 01 55             — Strip's onboard mic ON (strip reacts to ambient sound itself)
        BC0F 01 00 55             — Strip's onboard mic OFF (app drives color via BC09)
        BC11 01 [1–4] 55          — Onboard mic style: 1=Classic 2=Soft 3=Dynamic 4=Disco
        BC12 01 [0–100] 55        — Mic sensitivity
        BC13 01 [id 0x00–0xFD] 55 — Firmware animation scenes (253 scenes, 3 gap IDs)

        ── Unconfirmed ──────────────────────────────────────────
        BC03: unknown
        BC10: unknown

        ── Restore Instructions ─────────────────────────────────
        If custom firmware breaks the device:
        1. Identify chip from lightstar-device-info-*.txt (look for DFU service UUID)
        2. Nordic nRF (FE59 / 1530): flash OEM firmware via nRF Connect DFU
        3. Telink TLSR: requires USB programmer + Telink BDT tool
        4. Restore git tag: git checkout pre-firmware-research
           Then rebuild from Xcode — the app will work with OEM firmware again.

        Git snapshot: pre-firmware-research tag (run: git log --oneline -5)
        """

        try? txt.write(toFile: "\(base).txt", atomically: true, encoding: .utf8)

        // ── JSON for machine parsing ──────────────────────────────────────
        var json: [String: Any] = [
            "timestamp": ts,
            "deviceName": peripheral?.name ?? "unknown",
            "deviceUUID": peripheral?.identifier.uuidString ?? "unknown",
            "rssi": capturedRSSI,
            "gattLog": deviceLog,
            "knownCommands": [
                ["cmd": "BC01", "desc": "Power", "format": "BC 01 01 [00=off|01=on] 55"],
                ["cmd": "BC04", "desc": "Static color (Hue+Sat)", "format": "BC 04 06 H_hi H_lo S_hi S_lo 00 00 55"],
                ["cmd": "BC05", "desc": "Brightness", "format": "BC 05 06 B_hi B_lo 00 00 00 00 55"],
                ["cmd": "BC06", "desc": "Effect (58 IDs)", "format": "BC 06 02 hi lo 55"],
                ["cmd": "BC07", "desc": "Effect direction", "format": "BC 07 01 [0=back|1=fwd] 55"],
                ["cmd": "BC08", "desc": "Effect speed", "format": "BC 08 01 [0-100] 55"],
                ["cmd": "BC09", "desc": "Streaming color (audio sync)", "format": "BC 09 06 H_hi H_lo S_hi S_lo 00 00 55"],
                ["cmd": "BC0F", "desc": "Strip onboard mic", "format": "BC 0F 01 [0=off|1=on] 55"],
                ["cmd": "BC11", "desc": "Mic style", "format": "BC 11 01 [1=Classic|2=Soft|3=Dynamic|4=Disco] 55"],
                ["cmd": "BC12", "desc": "Mic sensitivity", "format": "BC 12 01 [0-100] 55"],
                ["cmd": "BC13", "desc": "Firmware animation scene", "format": "BC 13 01 [id 0x00-0xFD] 55"],
            ]
        ]
        json["advertisement"] = capturedAdvertisementStrings

        if let jsonData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            try? jsonStr.write(toFile: "\(base).json", atomically: true, encoding: .utf8)
        }

        deviceLog.append("")
        deviceLog.append("✓ Backup saved:")
        deviceLog.append("  \(base).txt")
        deviceLog.append("  \(base).json")
    }

    func saveDeviceInfoIfComplete() {
        // Auto-save once all readable chars have been read (heuristic: log has a READ line)
        guard deviceLog.contains(where: { $0.hasPrefix("  READ") }) else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let existing = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("lightstar-device-info-") } ?? []
        guard existing.isEmpty else { return }
        saveDeviceLog()
    }

    // Single comprehensive protocol dump:
    //   1. Device state queries (BC06, BC00, BC02)
    //   2. BC00–BC1F command sweep (0-byte + 1-byte payloads)
    //   3. BC0F mic-mode sweep (b1 0-3, b2 0-8)
    //   4. BC13 animation sweep (ID 0x01-0x3C, 3s each)
    //   5. BC11 sub-param sweep
    //   All TX and RX logged to probeLog; auto-saved to Desktop on finish.
    func protocolDump() {
        guard !probeRunning, connectionState == .connected else { return }
        probeRunning = true
        notifyTapHandler = nil

        let ts = Date()
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        probeLog = [
            "╔══════════════════════════════════════╗",
            "║   LightStar — Protocol Dump          ║",
            "╚══════════════════════════════════════╝",
            "Started: \(fmt.string(from: ts))",
            "→ TX  ← RX",
            "",
        ]

        probeTask = Task { @MainActor in
            // Mirror all BLE notifications into probeLog
            self.notifyTapHandler = { [weak self] data in
                guard let self else { return }
                let rx = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                self.probeLog.append("  ← \(rx)")
            }

            let tx: ([UInt8], String) -> Void = { bytes, label in
                let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                self.probeLog.append("→ [\(label)] \(hex)")
                self.write(bytes)
            }
            func ms(_ n: Int) async { try? await Task.sleep(nanoseconds: UInt64(n) * 1_000_000) }

            // ── 1. Device state queries ─────────────────────────────────────
            self.probeLog.append("── 1. State queries ────────────────────────────────────────")
            self.write(Cmd.powerOn)
            self.write(Cmd.brightness(1.0))
            await ms(400)
            for (cmd, label) in [(([0xBC, 0x06, 0x00, 0x55] as [UInt8]), "status?"),
                                  ([0xBC, 0x00, 0x00, 0x55], "ping?"),
                                  ([0xBC, 0x02, 0x00, 0x55], "query02?"),
                                  ([0xBC, 0x08, 0x00, 0x55], "query08?")] {
                if Task.isCancelled { break }
                tx(cmd, label)
                await ms(600)
            }

            // ── 2. BC00–BC1F command sweep ──────────────────────────────────
            self.probeLog.append("")
            self.probeLog.append("── 2. BC00–BC1F sweep (0-byte + 1-byte payload) ─────────────")
            let knownCmds: Set<UInt8> = [0x01, 0x04, 0x05, 0x06, 0x07, 0x0B, 0x0F, 0x11, 0x13]
            for cmd: UInt8 in 0x00...0x1F {
                if Task.isCancelled { break }
                let tag = knownCmds.contains(cmd) ? "KNOWN" : "?"
                tx([0xBC, cmd, 0x00, 0x55], String(format: "BC%02X 0b[%@]", cmd, tag))
                await ms(200)
                tx([0xBC, 0x06, 0x00, 0x55], "status?")
                await ms(300)
                tx([0xBC, cmd, 0x01, 0x01, 0x55], String(format: "BC%02X b=01", cmd))
                await ms(200)
                tx([0xBC, 0x06, 0x00, 0x55], "status?")
                await ms(300)
            }

            // ── 3. BC0F mic-mode sweep ──────────────────────────────────────
            self.probeLog.append("")
            self.probeLog.append("── 3. BC0F mic-mode sweep (b1 0x00–0x03, b2 0x00–0x08) ─────")
            for b1: UInt8 in 0x00...0x03 {
                for b2: UInt8 in 0x00...0x08 {
                    if Task.isCancelled { break }
                    tx([0xBC, 0x0F, 0x02, b1, b2, 0x55], String(format: "BC0F b1=%02X b2=%02X", b1, b2))
                    await ms(200)
                    tx([0xBC, 0x06, 0x00, 0x55], "status?")
                    await ms(400)
                }
            }

            // ── 4. BC13 animation sweep ─────────────────────────────────────
            self.probeLog.append("")
            self.probeLog.append("── 4. BC13 animation sweep (ID 0x01–0x3C, 3s each) ──────────")
            self.probeLog.append("   !! Play music near strip — watch for audio beam !!")
            self.write(Cmd.powerOn)
            self.write(Cmd.brightness(1.0))
            await ms(500)
            for id: UInt8 in 0x01...0x3C {
                if Task.isCancelled { break }
                tx([0xBC, 0x13, 0x02, 0x00, id, 0x55], String(format: "anim ID=0x%02X", id))
                await ms(300)
                tx([0xBC, 0x06, 0x00, 0x55], "status?")
                await ms(2700)
            }

            // ── 5. BC11 sub-param sweep ─────────────────────────────────────
            self.probeLog.append("")
            self.probeLog.append("── 5. BC11 sub-param sweep (0x01–0x06) ──────────────────────")
            for v: UInt8 in 0x01...0x06 {
                if Task.isCancelled { break }
                tx([0xBC, 0x11, 0x01, v, 0x55], String(format: "BC11 val=0x%02X", v))
                await ms(300)
                tx([0xBC, 0x06, 0x00, 0x55], "status?")
                await ms(600)
            }

            self.notifyTapHandler = nil
            self.probeLog.append("")
            self.probeLog.append("═══════════════════════════════════════════════════════════")
            self.probeLog.append("Finished: \(fmt.string(from: Date()))")
            self.saveProbeLog()
            self.probeRunning = false
        }
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
    private func write(_ bytes: [UInt8]) { coalescer.enqueue(bytes) }

    private func saveProbeLog() {
        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
        let ts = Int(Date().timeIntervalSince1970)
        let file = desktop.appendingPathComponent("lightstar-protocol-\(ts).txt")
        let content = probeLog.joined(separator: "\n")
        try? content.write(to: file, atomically: true, encoding: .utf8)
        print("[Probe] saved → \(file.path)")
        probeLog.append("Saved → \(file.lastPathComponent)")
    }

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
