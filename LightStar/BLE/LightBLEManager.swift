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
    var isOn = false
    var color: Color = .white
    var brightness: Double = 1.0
    var effectID: UInt8 = 0x01
    var effectSpeed: Double = 0.5   // 0–1 mapped to 0–100
    var effectModeActive = false
    // Sync state machine
    var syncMode: SyncMode = .off
    var syncError: String?
    var syncTransitioning = false
    enum AudioSyncMode: String, CaseIterable { case rainbow = "Rainbow"; case pulse = "Pulse"; case frequency = "Frequency" }
    var audioSyncMode: AudioSyncMode = .rainbow
    // Display picker
    var availableDisplays: [(id: CGDirectDisplayID, name: String)] = []
    var selectedDisplayID: CGDirectDisplayID? = nil

    var isSyncingVideo: Bool { syncMode == .video || syncMode == .combined }
    var isSyncingAudio: Bool { syncMode == .audio || syncMode == .combined }

    // MARK: - Protocol probe
    var probeLog: [String] = []
    var probeRunning = false
    var cameraProbeEnabled = false
    var selectedCameraID: String? = nil   // nil = auto (iPhone first, then built-in)

    // MARK: - Device discovery log
    var deviceLog: [String] = []
    var capturedAdvertisementStrings: [String: String] = [:]
    var capturedRSSI: Int = 0
    // Live camera reading for debug tab (hue 0-1, brightness 0-1, -1 = no camera)
    var liveHue: Double = -1
    var liveBrightness: Double = -1

    // MARK: - BLE UUIDs

    nonisolated(unsafe) private static let serviceUUID    = CBUUID(string: "FFF0")
    nonisolated(unsafe) private static let writeCharUUID  = CBUUID(string: "FFF3")
    nonisolated(unsafe) private static let notifyCharUUID = CBUUID(string: "FFF4")
    nonisolated(unsafe) private static let advertisedUUID = CBUUID(string: "2022")

    // MARK: - Private state

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var reconnectTask: Task<Void, Never>?
    private var connectWhenReady = false   // deferred connect until BT powered on
    private var colorDebounce: Task<Void, Never>?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private let systemAudio = SystemAudioSampler()
    private var transitionTask: Task<Void, Never>?
    private var writeQueue: [UInt8: Data] = [:]   // keyed by command byte — latest wins
    private var drainTimer: Timer?
    private var beatHue: Double = 0
    private var flashLevel: Double = 0
    private var lastScreenH: Double = 0
    private var lastScreenS: Double = 1
    private var audioPulseH: Double = 0   // cached hue for pulse mode — avoids 30Hz hsvComponents
    private let camera = CameraChangeDetector()
    private let screenSampler = ScreenColorSampler()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Public API

    func connect() {
        guard connectionState == .disconnected else { return }
        reconnectAttempts = 0
        if central.state == .poweredOn {
            startScan()
        } else {
            // BT not ready yet — startScan deferred to centralManagerDidUpdateState
            connectWhenReady = true
            connectionState = .scanning
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = maxReconnectAttempts
        drainTimer?.invalidate(); drainTimer = nil; writeQueue.removeAll()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        connectionState = .disconnected
    }

    func setPower(on: Bool) {
        isOn = on
        if !on {
            // Nil closures synchronously so no callbacks fire after powerOff
            systemAudio.onBands = nil
            screenSampler.onColor = nil
            flashLevel = 0
            setSyncMode(.off)
        }
        write(on ? Cmd.powerOn : Cmd.powerOff)
    }

    func sendRaw(_ bytes: [UInt8]) {
        print("[LightStar] sendRaw: \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        write(bytes)
    }

    // Preferred over setColor — avoids lossy Color→NSColor→getHue round-trip.
    func setHue(_ h: Double, saturation s: Double) {
        color = Color(hue: h, saturation: s, brightness: 1)
        audioPulseH = h
        effectModeActive = false
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

    func setBrightness(_ value: Double) {
        brightness = value
        write(Cmd.brightness(value))
    }

    func setEffect(id: UInt8) {
        // Nil closures synchronously so async teardown can't overwrite the effect packet
        systemAudio.onBands = nil
        screenSampler.onColor = nil
        flashLevel = 0
        transitionTask?.cancel()
        syncMode = .off
        syncTransitioning = false
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

    func setSyncMode(_ mode: SyncMode) {
        transitionTask?.cancel()
        syncTransitioning = true
        syncError = nil
        transitionTask = Task { @MainActor in
            await self.teardownSync()
            guard !Task.isCancelled else {
                self.syncTransitioning = false
                return
            }
            await self.buildSync(mode)
            if !Task.isCancelled { self.syncTransitioning = false }
        }
    }

    private func teardownSync() async {
        systemAudio.onBands = nil
        screenSampler.onColor = nil
        flashLevel = 0
        await systemAudio.stop()
        await screenSampler.stop()
    }

    private func buildSync(_ mode: SyncMode) async {
        effectModeActive = false
        guard mode == .off || connectionState == .connected else {
            syncMode = .off
            syncError = "Not connected"
            return
        }
        switch mode {
        case .off:
            syncMode = .off
            restoreSteadyState()

        case .video:
            setupScreenCallback()
            screenSampler.selectedDisplayID = selectedDisplayID
            do {
                try await screenSampler.start()
                syncMode = .video
            } catch {
                screenSampler.onColor = nil
                syncMode = .off
                syncError = error.localizedDescription
                restoreSteadyState()
            }

        case .audio:
            let (h, _, _) = color.hsvComponents
            beatHue = h
            audioPulseH = h
            setupAudioCallback()
            do {
                try await systemAudio.start()
                syncMode = .audio
            } catch {
                systemAudio.onBands = nil
                syncMode = .off
                syncError = error.localizedDescription
                restoreSteadyState()
            }

        case .combined:
            setupScreenCallback()
            setupAudioCallback()
            screenSampler.selectedDisplayID = selectedDisplayID
            var errors: [String] = []
            // Start both streams concurrently — total latency = max(screen, audio)
            async let screenStart: () = screenSampler.start()
            async let audioStart: () = systemAudio.start()
            do { try await screenStart } catch {
                screenSampler.onColor = nil
                errors.append("Screen: \(error.localizedDescription)")
            }
            do { try await audioStart } catch {
                systemAudio.onBands = nil
                errors.append("Audio: \(error.localizedDescription)")
            }
            let screenOk = screenSampler.onColor != nil
            let audioOk  = systemAudio.onBands != nil
            syncMode = screenOk && audioOk ? .combined
                     : screenOk           ? .video
                     : audioOk            ? .audio
                     :                     .off
            if !errors.isEmpty { syncError = errors.joined(separator: "; ") }
            if syncMode == .off { restoreSteadyState() }
        }
    }

    private func setupScreenCallback() {
        var lastH: Double = -1
        var lastWrite: Double = 0
        screenSampler.onColor = { [weak self] h, s, v in
            guard let self, self.isSyncingVideo, self.isOn else { return }
            guard v > 0.04 else { return }
            let now = CACurrentMediaTime()
            let hueDelta = min(abs(h - lastH), 1.0 - abs(h - lastH))
            guard hueDelta > 0.008 || now - lastWrite > 0.5 else { return }
            guard now - lastWrite >= 1.0 / 20.0 else { return }
            lastWrite = now; lastH = h
            let boostedS = s < 0.3 ? min(1.0, s * 3.0) : min(1.0, s * 1.5)
            self.lastScreenH = h
            self.lastScreenS = boostedS
            self.write(Cmd.hue(h, saturation: boostedS))
        }
    }

    private func setupAudioCallback() {
        var lastWrite: Double = 0
        systemAudio.onBands = { [weak self] (bands: FrequencyBands) in
            guard let self, self.isSyncingAudio, self.isOn else { return }
            let now = CACurrentMediaTime()
            guard now - lastWrite >= 1.0 / 30.0 else { return }
            lastWrite = now

            if self.syncMode == .combined {
                if bands.isBeat {
                    self.flashLevel = 1.0
                    self.write(Cmd.hue(self.lastScreenH, saturation: min(1.0, self.lastScreenS * 1.3 + 0.15)))
                } else {
                    self.flashLevel = max(0.0, self.flashLevel * 0.82)
                }
                let bri = min(1.0, max(0.04, bands.bass * 0.55 + bands.rms * 0.15 + self.flashLevel * 0.80))
                self.write(Cmd.brightness(bri))
                return
            }

            switch self.audioSyncMode {
            case .rainbow:
                if bands.isBeat {
                    self.beatHue = (self.beatHue + 1.0/12.0).truncatingRemainder(dividingBy: 1.0)
                } else {
                    self.beatHue = (self.beatHue + bands.high * 0.006).truncatingRemainder(dividingBy: 1.0)
                }
                self.write(Cmd.hue(self.beatHue, saturation: min(1.0, 0.6 + bands.mid * 0.4)))
                self.write(Cmd.brightness(min(1.0, max(0.05, bands.bass * 1.3 + bands.rms * 0.3))))
            case .pulse:
                self.write(Cmd.hue(self.audioPulseH, saturation: min(1.0, 0.8 + bands.mid * 0.2)))
                self.write(Cmd.brightness(min(1.0, max(0.03, bands.bass * 1.5 + bands.rms * 0.2))))
            case .frequency:
                // Hue blends mid→green and high→blue; bass excluded from denominator so
                // bass-heavy music doesn't pull hue toward zero (red) unintentionally.
                let hTotal = bands.mid + bands.high + 0.001
                let h = (bands.mid * (120/360.0) + bands.high * (240/360.0)) / hTotal
                self.write(Cmd.hue(h, saturation: 1.0))
                self.write(Cmd.brightness(min(1.0, max(0.05, (bands.bass + bands.mid + bands.high) / 3 * 1.5 + bands.rms * 0.2))))
            }
        }
    }

    private func restoreSteadyState() {
        let (h, s, _) = color.hsvComponents
        write(Cmd.hue(h, saturation: s))
        write(Cmd.brightness(brightness))
    }

    func loadAvailableDisplays() {
        Task {
            let displays = await ScreenColorSampler.availableDisplays()
            await MainActor.run { self.availableDisplays = displays }
        }
    }

    // MARK: - Live camera for debug tab

    private var liveCameraActive = false
    private var liveCameraTimer: Task<Void, Never>?

    func startLiveCamera() {
        guard !liveCameraActive else { return }
        liveCameraActive = true
        liveCameraTimer = Task { @MainActor in
            do {
                try await camera.start(preferredDeviceID: selectedCameraID)
                while liveCameraActive {
                    let s = await camera.snapshot(afterMs: 0)
                    self.liveHue = s.hue
                    self.liveBrightness = s.brightness
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            } catch {
                liveHue = -1; liveBrightness = -1
            }
        }
    }

    func stopLiveCamera() {
        liveCameraActive = false
        liveCameraTimer?.cancel()
        liveCameraTimer = nil
        camera.stop()
        liveHue = -1; liveBrightness = -1
    }

    // MARK: - Device info save

    func saveDeviceLog() {
        guard !deviceLog.isEmpty else { return }
        let ts = Int(Date().timeIntervalSince1970)
        let url = URL(fileURLWithPath: "/Users/adityaraj/Desktop/lightstar-device-info-\(ts).txt")
        let content = "=== LightStar Device Info ===\n" + deviceLog.joined(separator: "\n")
        try? content.write(to: url, atomically: true, encoding: .utf8)
        deviceLog.append("Saved → \(url.lastPathComponent)")
    }

    // Full protocol + device backup — call from Debug tab "Backup" button.
    // Saves human-readable .txt and machine-readable .json to Desktop.
    func saveFullBackup() {
        let ts = Int(Date().timeIntervalSince1970)
        let base = "/Users/adityaraj/Desktop/lightstar-backup-\(ts)"

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


        ── Known BC/55 Commands (reverse-engineered) ────────────
        Frame: BC [cmd] [data_len] [data × data_len] 55
        Transport: ATT Write Command (withoutResponse) on FFF3
        Service: 0000FFF0-0000-1000-8000-00805F9B34FB
        Scan UUID: 0x2022

        BC01 01 01 00 55  — Power OFF
        BC01 01 01 01 55  — Power ON
        BC04 06 [H_hi][H_lo][S_hi][S_lo] 00 00 55  — Hue (0–360 BE) + Sat (0–1000 BE)
        BC05 06 [B_hi][B_lo] 00 00 00 00 55  — Brightness (100–1000 BE)
        BC06 02 00 [id] 55  — Effect (IDs: 01, 03, 35 confirmed)
        BC08 01 [speed 0–100] 55  — Effect speed
        BC13 01 [id 0–FD] 55  — Firmware animation (ignores BC04/05 until power-cycle)
        BC13 02 00 00 55  — Speculative: stop animation (unconfirmed)

        ── Unconfirmed / To-Explore ─────────────────────────────
        BC07: zone select (speculative — 01 00, 01 02 tested, effect unknown)
        BC10: force solid mode (speculative — 0x00, effect unknown)
        BC11: unknown
        BC03: unknown

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
                ["cmd": "BC04", "desc": "Hue+Sat", "format": "BC 04 06 H_hi H_lo S_hi S_lo 00 00 55"],
                ["cmd": "BC05", "desc": "Brightness", "format": "BC 05 06 B_hi B_lo 00 00 00 00 55"],
                ["cmd": "BC06", "desc": "Effect", "format": "BC 06 02 00 [id] 55"],
                ["cmd": "BC08", "desc": "Speed", "format": "BC 08 01 [0-100] 55"],
                ["cmd": "BC13", "desc": "Animation", "format": "BC 13 01 [id] 55"],
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
        let dir = URL(fileURLWithPath: "/Users/adityaraj/Desktop/")
        let existing = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("lightstar-device-info-") } ?? []
        guard existing.isEmpty else { return }
        saveDeviceLog()
    }

    // Comprehensive color mapping test:
    //   Phase 1 — full hue sweep 0–350° every 10°, S=100% (36 points)
    //   Phase 2 — saturation linearity: 6 hues × S=25/50/75/100% (24 points)
    //   Phase 3 — white (S=0)
    // Total ~63 tests, ~65 seconds. Point iPhone at strip, dim room lights first.
    func testColorMapping() {
        guard !probeRunning, connectionState == .connected else { return }
        probeRunning = true
        setSyncMode(.off); effectModeActive = false

        probeLog = [
            "=== COMPREHENSIVE COLOR MAPPING TEST ===",
            "63 test points — ~90 seconds (each point sent twice to survive BLE drops)",
            "Point iPhone camera at strip, 20-30cm away, dim ambient light.",
            "Starting camera…"
        ]

        Task { @MainActor in
            guard self.connectionState == .connected else {
                self.probeLog.append("❌ Not connected — connect to strip first")
                self.probeRunning = false; return
            }

            do { try await self.camera.start(preferredDeviceID: self.selectedCameraID) }
            catch {
                self.probeLog.append("❌ Camera: \(error.localizedDescription)")
                self.probeRunning = false; return
            }
            self.probeLog.append("Camera: \(self.camera.activeCameraName)  Warm-up 2s…")
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            // Try static mode without power-cycling first — power cycles can re-trigger
            // BC13 animations saved in flash. Only cycle if verify step fails.
            self.probeLog.append("Clearing effect mode…")
            self.write(Cmd.effect(id: 0x00))
            try? await Task.sleep(nanoseconds: 300_000_000)

            // Verify: retry up to 5× until strip actually shows red (hue within 40°)
            // Brightness-only check let prior tests proceed with wrong color.
            var verified = false
            for attempt in 1...5 {
                self.write(Cmd.hue(0, saturation: 1.0))
                self.write(Cmd.brightness(1.0))
                try? await Task.sleep(nanoseconds: 150_000_000)
                self.write(Cmd.hue(0, saturation: 1.0))
                self.write(Cmd.brightness(1.0))
                let snap = await self.camera.snapshot(afterMs: 1000)
                let hueDelta = min(abs(snap.hue - 0.0), 1.0 - abs(snap.hue - 0.0))
                self.probeLog.append(String(format: "Verify attempt %d: got %.0f° (Δ%.0f°) bri=%.2f",
                    attempt, snap.hue * 360, hueDelta * 360, snap.brightness))
                if snap.brightness < 0.05 {
                    self.probeLog.append("❌ Strip not visible — point camera closer and retry")
                    self.camera.stop(); self.probeRunning = false; return
                }
                if hueDelta < 0.111 {   // within 40°
                    self.probeLog.append("✓ Strip showing red — BC04 responding")
                    verified = true; break
                }
                // Not red yet — power-cycle again and retry
                if attempt < 5 {
                    self.probeLog.append("  Strip not red yet, power-cycling again…")
                    self.write(Cmd.powerOff)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self.write(Cmd.powerOn)
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    self.write(Cmd.effect(id: 0x00))
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            if !verified {
                self.probeLog.append("❌ Strip won't show red after 5 attempts — BC04 not working, aborting")
                self.camera.stop(); self.probeRunning = false; return
            }

            struct Row {
                let phase: String; let label: String
                let sentH: Double; let sentS: Double
                let obsH: Double;  let obsBri: Double
                var hueDelta: Double {
                    min(abs(sentH - obsH), 1.0 - abs(sentH - obsH))
                }
            }
            var rows: [Row] = []

            // Helper — send color twice (100ms apart) to survive BLE TX drops, then snapshot
            let measure = { @MainActor [self] (phase: String, label: String, h: Double, s: Double) async -> Row in
                self.write(Cmd.hue(h, saturation: s))
                self.write(Cmd.brightness(1.0))
                try? await Task.sleep(nanoseconds: 120_000_000)  // let BLE stack flush
                self.write(Cmd.hue(h, saturation: s))            // send again — strip drops ~10%
                self.write(Cmd.brightness(1.0))
                let obs = await self.camera.snapshot(afterMs: 1200)
                return Row(phase: phase, label: label, sentH: h, sentS: s,
                           obsH: obs.hue, obsBri: obs.brightness)
            }

            // ── PHASE 1: Full hue sweep every 10° at S=100% ──────────────
            self.probeLog.append("")
            self.probeLog.append("PHASE 1 — Hue sweep 0°–350° (S=100%) — 36 points")
            self.probeLog.append("  \("Label".padding(toLength: 18, withPad: " ", startingAt: 0))  Sent    Got   Δ")
            for deg in stride(from: 0, through: 350, by: 10) {
                let h = Double(deg) / 360.0
                let name = "\(deg)°"
                let row = await measure("HueSweep", name, h, 1.0)
                rows.append(row)
                let ok = row.hueDelta < 0.083
                let pad = name.padding(toLength: 18, withPad: " ", startingAt: 0)
                self.probeLog.append(String(format: "  %@  %5.1f°  %5.1f°  %3.0f°  %@",
                    pad, h * 360, row.obsH * 360, row.hueDelta * 360, ok ? "✓" : "⚠"))
            }

            // ── PHASE 2: Saturation linearity at 6 key hues ──────────────
            self.probeLog.append("")
            self.probeLog.append("PHASE 2 — Saturation linearity (6 hues × S=25/50/75/100%) — 24 points")
            self.probeLog.append("  Label                   SentS   ObsH  ObsBri")
            let keyHues: [(String, Double)] = [
                ("Red",     0/360.0), ("Yellow", 60/360.0), ("Green", 120/360.0),
                ("Cyan",  180/360.0), ("Blue",  240/360.0), ("Magenta", 300/360.0)
            ]
            for (hueName, h) in keyHues {
                for s in [0.25, 0.50, 0.75, 1.00] {
                    let label = "\(hueName) S=\(Int(s*100))%"
                    let row = await measure("SatTest", label, h, s)
                    rows.append(row)
                    let pad = label.padding(toLength: 22, withPad: " ", startingAt: 0)
                    self.probeLog.append(String(format: "  %@  %3.0f%%  %5.1f°  %.2f",
                        pad, s * 100, row.obsH * 360, row.obsBri))
                }
            }

            // ── PHASE 3: White ────────────────────────────────────────────
            self.probeLog.append("")
            self.probeLog.append("PHASE 3 — White (S=0)")
            let white = await measure("White", "White S=0", 0, 0)
            rows.append(white)
            let whiteOk = white.obsBri > 0.25
            self.probeLog.append(String(format: "  White  bri=%.2f  %@",
                white.obsBri, whiteOk ? "✓" : "⚠ TOO DIM"))

            self.camera.stop()

            // ── ANALYSIS ─────────────────────────────────────────────────
            self.probeLog.append("")
            self.probeLog.append("══════════════════════════════════════")
            self.probeLog.append("ANALYSIS")

            let hueSweep = rows.filter { $0.phase == "HueSweep" }
            let mismatches = hueSweep.filter { $0.hueDelta >= 0.083 }
            let avgDelta = hueSweep.map { $0.hueDelta * 360 }.reduce(0, +) / Double(hueSweep.count)
            let maxRow = hueSweep.max(by: { $0.hueDelta < $1.hueDelta })

            self.probeLog.append(String(format: "Hue sweep:  avg error %.1f°  max error %.1f° @ %@",
                avgDelta, (maxRow?.hueDelta ?? 0) * 360, maxRow?.label ?? "?"))
            self.probeLog.append("Mismatches (>30°): \(mismatches.count)/36")

            if !mismatches.isEmpty {
                self.probeLog.append("  Affected hues:")
                for m in mismatches {
                    self.probeLog.append(String(format: "    %@  sent %.0f°  got %.0f°  Δ%.0f°",
                        m.label, m.sentH * 360, m.obsH * 360, m.hueDelta * 360))
                }
            }

            // Detect systematic offset
            let offsets = hueSweep.map { r -> Double in
                var d = r.obsH - r.sentH
                if d >  0.5 { d -= 1 }
                if d < -0.5 { d += 1 }
                return d * 360
            }
            let medianOffset = offsets.sorted()[offsets.count / 2]
            if abs(medianOffset) > 10 {
                self.probeLog.append(String(format: "⚠ SYSTEMATIC HUE OFFSET detected: %.0f°", medianOffset))
                self.probeLog.append("  → Cmd.hue() needs correction: H_sent = H_wanted - \(Int(medianOffset.rounded()))°")
            } else {
                self.probeLog.append(String(format: "✓ No systematic offset (median %.1f°)", medianOffset))
            }

            // Saturation check
            self.probeLog.append("")
            self.probeLog.append("Saturation linearity: check if brightness drops as S decreases")
            let satRows = rows.filter { $0.phase == "SatTest" && $0.label.hasPrefix("Red") }
            for r in satRows {
                self.probeLog.append(String(format: "  %@  bri=%.2f", r.label, r.obsBri))
            }

            // Save full CSV + report
            var csv = "phase,label,sentH_deg,sentS_pct,obsH_deg,obsBri,hueDelta_deg\n"
            for r in rows {
                csv += String(format: "%@,%@,%.1f,%.0f,%.1f,%.3f,%.1f\n",
                    r.phase, r.label, r.sentH * 360, r.sentS * 100,
                    r.obsH * 360, r.obsBri, r.hueDelta * 360)
            }
            let ts = Int(Date().timeIntervalSince1970)
            let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            let txtFile = desktop.appendingPathComponent("lightstar-color-test-\(ts).txt")
            let csvFile = desktop.appendingPathComponent("lightstar-color-test-\(ts).csv")
            try? (self.probeLog.joined(separator: "\n")).write(to: txtFile, atomically: true, encoding: .utf8)
            try? csv.write(to: csvFile, atomically: true, encoding: .utf8)

            self.probeLog.append("")
            self.probeLog.append("Saved → lightstar-color-test-\(ts).txt")
            self.probeLog.append("Saved → lightstar-color-test-\(ts).csv  (open in Excel/Numbers)")
            self.probeLog.append("=== DONE ===")
            self.probeRunning = false
        }
    }

    // Steps through 12 hues at full saturation so user can see which colors
    // the strip actually renders. 1 second per hue, resets to white when done.
    func sweepColorPalette() {
        guard connectionState == .connected, !probeRunning else { return }
        probeRunning = true
        setSyncMode(.off); effectModeActive = false
        let hues: [(String, Double)] = [
            ("Red", 0/12.0), ("Orange", 1/12.0), ("Yellow", 2/12.0),
            ("Chartreuse", 3/12.0), ("Green", 4/12.0), ("Spring", 5/12.0),
            ("Cyan", 6/12.0), ("Azure", 7/12.0), ("Blue", 8/12.0),
            ("Violet", 9/12.0), ("Magenta", 10/12.0), ("Rose", 11/12.0),
            ("White (S=0)", -1),
        ]
        probeLog = ["=== COLOR PALETTE SWEEP ==="]
        Task { @MainActor in
            for (name, h) in hues {
                let hue = h < 0 ? 0.0 : h
                let sat = h < 0 ? 0.0 : 1.0
                self.write(Cmd.hue(hue, saturation: sat))
                self.write(Cmd.brightness(1.0))
                self.probeLog.append("→ \(name)  H=\(Int(hue*360))  S=\(Int(sat*1000))")
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
            self.probeLog.append("=== DONE — note any missing/wrong colors ===")
            self.probeRunning = false
        }
    }

    // Probes BC00–BC3F. With cameraProbeEnabled=true, samples the MacBook
    // camera before/after each command and marks visual changes automatically.
    // Point camera at the light bar before running.
    func probeProtocol() {
        guard !probeRunning, connectionState == .connected else { return }
        probeRunning = true
        let usingCamera = cameraProbeEnabled
        probeLog = ["=== PROBE START — camera:\(usingCamera ? "ON" : "OFF") ==="]
        Task { @MainActor in
            if usingCamera {
                do {
                    try await self.camera.start(preferredDeviceID: self.selectedCameraID)
                    self.probeLog.append("Camera started — point it at the light bar")
                    // Warm-up: let camera auto-expose
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                } catch {
                    self.probeLog.append("Camera failed: \(error.localizedDescription) — running without detection")
                }
            }

            self.probeLog.append("--- Round 1: query (0-byte) BC00–BC3F ---")
            for cmd in UInt8(0x00)...UInt8(0x3F) {
                let frame: [UInt8] = [0xBC, cmd, 0x00, 0x55]
                let hex = frame.map { String(format: "%02X", $0) }.joined(separator: " ")
                let before = usingCamera ? await self.camera.snapshot(afterMs: 0) : (0.0, 0.0)
                self.write(frame)
                let after = usingCamera ? await self.camera.snapshot(afterMs: 400) : (0.0, 0.0)
                let change = usingCamera ? Self.visualChange(before, after) : ""
                let line = "TX BC\(String(format: "%02X", cmd)) (query) → \(hex)\(change)"
                self.probeLog.append(line)
                print("[Probe] \(line)")
                if !usingCamera { try? await Task.sleep(nanoseconds: 300_000_000) }
            }

            self.probeLog.append("--- Round 2: write (1-byte) BC00–BC3F ---")
            for cmd in UInt8(0x00)...UInt8(0x3F) {
                for payload: [UInt8] in [[0x00], [0x01], [0x64]] {
                    let frame: [UInt8] = [0xBC, cmd, UInt8(payload.count)] + payload + [0x55]
                    let hex = frame.map { String(format: "%02X", $0) }.joined(separator: " ")
                    let payHex = payload.map { String(format: "%02X", $0) }.joined()
                    let before = usingCamera ? await self.camera.snapshot(afterMs: 0) : (0.0, 0.0)
                    self.write(frame)
                    let after = usingCamera ? await self.camera.snapshot(afterMs: 400) : (0.0, 0.0)
                    let change = usingCamera ? Self.visualChange(before, after) : ""
                    let line = "TX BC\(String(format: "%02X", cmd)) \(payHex) → \(hex)\(change)"
                    self.probeLog.append(line)
                    print("[Probe] \(line)")
                    if !usingCamera { try? await Task.sleep(nanoseconds: 300_000_000) }
                }
            }

            if usingCamera { self.camera.stop() }
            self.probeLog.append("=== PROBE DONE ===")
            print("[Probe] DONE")
            self.probeRunning = false
            self.saveProbeLog()
        }
    }

    // One-shot deep analysis of specific commands discovered in broad probe.
    // Sweeps each target with 0x00–0xFF, resets device between commands,
    // writes a complete analysis doc to Desktop. ~5 min with camera.
    func probeDeep() {
        guard !probeRunning, connectionState == .connected else { return }
        probeRunning = true
        probeLog = ["=== DEEP PROBE START ==="]

        // Commands to analyse: (cmd, name, known_context)
        let targets: [(UInt8, String, String)] = [
            (0x03, "BC03", "1-byte write 01 caused minor change — unknown"),
            (0x07, "BC07", "query + 1-byte 00 cause brightness shift — unknown"),
            (0x10, "BC10", "all 3 payloads cause big hue cycle — suspected color/effect"),
            (0x11, "BC11", "known mic sub-param; independent effect confirmed"),
            (0x13, "BC13", "all 3 payloads cause bri+hue shift — completely unknown"),
        ]

        Task { @MainActor in
            do { try await self.camera.start() } catch {
                self.probeLog.append("Camera failed: \(error.localizedDescription)")
                self.probeRunning = false; return
            }
            self.probeLog.append("Camera warm-up…")
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            // Per-command result storage
            struct Hit { var payload: UInt8; var dBri: Double; var dHue: Double }
            var results: [(cmd: UInt8, name: String, context: String, hits: [Hit])] = []

            for (cmd, name, context) in targets {
                self.probeLog.append("")
                self.probeLog.append("━━━ \(name) — \(context) ━━━")
                self.probeLog.append("Resetting device to known state…")

                // Reset: power ON, solid red, medium brightness
                self.write(Cmd.powerOn)
                try? await Task.sleep(nanoseconds: 200_000_000)
                self.write(Cmd.hue(0.0, saturation: 1.0))   // red
                try? await Task.sleep(nanoseconds: 200_000_000)
                self.write(Cmd.brightness(0.5))
                try? await Task.sleep(nanoseconds: 600_000_000) // let it settle

                var hits: [Hit] = []

                for payload in UInt8(0x00)...UInt8(0xFF) {
                    let frame: [UInt8] = [0xBC, cmd, 0x01, payload, 0x55]
                    let hex = frame.map { String(format: "%02X", $0) }.joined(separator: " ")
                    let before = await self.camera.snapshot(afterMs: 0)
                    self.write(frame)
                    let after = await self.camera.snapshot(afterMs: 250)
                    let dBri = after.brightness - before.brightness
                    let dHue = abs(after.hue - before.hue)
                    let changed = abs(dBri) > 0.04 || dHue > 0.04
                    if changed {
                        hits.append(Hit(payload: payload, dBri: dBri, dHue: dHue))
                        let mark = String(format: "  ★ %02X bri%+.2f hue Δ%.2f", payload, dBri, dHue)
                        self.probeLog.append("TX \(hex)\(mark)")
                        print("[Deep] \(name) \(mark)")
                    }
                    // Progress every 16 payloads
                    if payload % 16 == 15 {
                        self.probeLog.append("  … scanned 0x\(String(format: "%02X", payload - 14))–0x\(String(format: "%02X", payload)) (\(hits.count) hits so far)")
                    }
                    if payload == 0xFF { break } // avoid overflow
                }

                results.append((cmd, name, context, hits))
                self.probeLog.append("Done: \(hits.count)/256 payloads triggered change.")
            }

            self.camera.stop()
            self.probeLog.append("")
            self.probeLog.append("=== ANALYSIS ===")

            // Build analysis report
            var report: [String] = [
                "LightStar Deep Protocol Analysis",
                "Generated: \(Date())",
                "Target commands: BC03 BC07 BC10 BC11 BC13",
                "",
            ]

            for r in results {
                report.append("══════════════════════════════════════")
                report.append("Command: \(r.name)  (0x\(String(format: "%02X", r.cmd)))")
                report.append("Prior context: \(r.context)")
                report.append("Responding payloads: \(r.hits.count)/256")
                report.append("")

                if r.hits.isEmpty {
                    report.append("  → NO visual change detected for any payload.")
                    report.append("  → Hypothesis: command requires different frame structure (>1 byte payload)")
                    report.append("    or operates in a mode not currently active.")
                } else {
                    // Characterise change type
                    let briOnly  = r.hits.filter { abs($0.dBri) > 0.04 && abs($0.dHue) <= 0.04 }
                    let hueOnly  = r.hits.filter { abs($0.dBri) <= 0.04 && abs($0.dHue) > 0.04 }
                    let both     = r.hits.filter { abs($0.dBri) > 0.04 && abs($0.dHue) > 0.04 }

                    report.append("  Change breakdown:")
                    report.append("    Brightness-only: \(briOnly.count)")
                    report.append("    Hue-only:        \(hueOnly.count)")
                    report.append("    Both:            \(both.count)")
                    report.append("")

                    // Find contiguous ranges
                    let payloads = r.hits.map { Int($0.payload) }.sorted()
                    var ranges: [(Int, Int)] = []
                    var start = payloads[0], prev = payloads[0]
                    for p in payloads.dropFirst() {
                        if p == prev + 1 { prev = p }
                        else { ranges.append((start, prev)); start = p; prev = p }
                    }
                    ranges.append((start, prev))

                    report.append("  Responding payload ranges:")
                    for (lo, hi) in ranges {
                        if lo == hi { report.append("    0x\(String(format: "%02X", lo))") }
                        else { report.append("    0x\(String(format: "%02X", lo))–0x\(String(format: "%02X", hi)) (\(hi-lo+1) values)") }
                    }
                    report.append("")

                    // Hypothesis
                    let coverage = Double(r.hits.count) / 256.0
                    var hypothesis = ""
                    if coverage > 0.7 {
                        hypothesis = "Continuous range parameter (>70% coverage). "
                        if briOnly.count > hueOnly.count { hypothesis += "Primarily affects brightness — likely intensity/dimmer control." }
                        else if hueOnly.count > briOnly.count { hypothesis += "Primarily affects hue — likely color temperature or zone color." }
                        else { hypothesis += "Affects both bri+hue — may be combined color+mode selector." }
                    } else if coverage < 0.1 {
                        hypothesis = "Sparse hits (<10%) — likely enum selector. "
                        hypothesis += "Valid values: \(payloads.map { String(format: "0x%02X", $0) }.joined(separator: ", "))"
                    } else {
                        hypothesis = "Partial coverage (\(Int(coverage*100))%). "
                        if ranges.count <= 4 { hypothesis += "Possible stepped enum or mode-gated range." }
                        else { hypothesis += "Multiple active ranges — may encode sub-command + value." }
                    }
                    report.append("  Hypothesis: \(hypothesis)")
                    report.append("")

                    // Recommended frame for confirmed behavior
                    if let first = r.hits.first {
                        report.append("  Confirmed working frame:")
                        let frame: [UInt8] = [0xBC, r.cmd, 0x01, first.payload, 0x55]
                        report.append("    \(frame.map { String(format: "%02X", $0) }.joined(separator: " "))")
                    }

                    // Full hit table
                    report.append("")
                    report.append("  Full hit table (payload → ΔBri  ΔHue):")
                    for h in r.hits {
                        report.append(String(format: "    0x%02X → bri%+.3f  hue Δ%.3f", h.payload, h.dBri, h.dHue))
                    }
                }
                report.append("")
            }

            report.append("══════════════════════════════════════")
            report.append("SUMMARY — commands to add to protocol-confirmed.md:")
            for r in results where !r.hits.isEmpty {
                let payloads = r.hits.map { Int($0.payload) }.sorted()
                let min = payloads.first!, max = payloads.last!
                report.append("  \(r.name): payload range 0x\(String(format: "%02X", min))–0x\(String(format: "%02X", max)), \(r.hits.count) active values")
            }

            let content = report.joined(separator: "\n")
            let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            let file = desktop.appendingPathComponent("lightstar-deep-analysis-\(Int(Date().timeIntervalSince1970)).txt")
            try? content.write(to: file, atomically: true, encoding: .utf8)

            self.probeLog.append("Analysis saved → \(file.path)")
            self.probeLog.append("=== DEEP PROBE DONE ===")
            self.probeRunning = false
            self.saveProbeLog()
        }
    }

    // Returns "  ★ CHANGE bri 0.30→0.45 hue 0.12→0.15" or "" if no change.
    private static func visualChange(_ before: (brightness: Double, hue: Double),
                                     _ after: (brightness: Double, hue: Double)) -> String {
        let dBri = abs(after.brightness - before.brightness)
        let dHue = abs(after.hue - before.hue)
        guard dBri > 0.04 || dHue > 0.04 else { return "" }
        return String(format: "  ★ CHANGE bri %.2f→%.2f hue %.2f→%.2f",
                      before.brightness, after.brightness, before.hue, after.hue)
    }

    private func saveProbeLog() {
        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
        let file = desktop.appendingPathComponent("lightstar-probe-\(Int(Date().timeIntervalSince1970)).txt")
        let content = probeLog.joined(separator: "\n")
        try? content.write(to: file, atomically: true, encoding: .utf8)
        print("[Probe] saved → \(file.path)")
        probeLog.append("Saved → \(file.path)")
    }

    // MARK: - Private helpers

    private func startScan() {
        guard central.state == .poweredOn else { return }
        connectionState = .scanning
        central.scanForPeripherals(withServices: [Self.advertisedUUID], options: nil)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard self.connectionState == .scanning else { return }
            self.central.stopScan()
            self.connectionState = .disconnected
        }
    }

    // FFF3 supports write-with-response (.write) — CB queues internally, ACK guaranteed.
    private func write(_ bytes: [UInt8]) {
        guard connectionState == .connected else { return }
        writeQueue[bytes[0]] = Data(bytes)
        guard drainTimer == nil else { return }
        let t = Timer(timeInterval: 0.020, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                guard self.connectionState == .connected,
                      let p = self.peripheral, let ch = self.writeChar else {
                    timer.invalidate(); self.drainTimer = nil; return
                }
                guard let (cmd, data) = self.writeQueue.first else {
                    timer.invalidate(); self.drainTimer = nil; return
                }
                self.writeQueue.removeValue(forKey: cmd)
                p.writeValue(data, for: ch, type: .withResponse)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        drainTimer = t
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
        guard central.state == .poweredOn else { return }
        Task { @MainActor in
            guard self.connectWhenReady else { return }
            self.connectWhenReady = false
            self.startScan()
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
            self.writeChar = nil
            self.connectionState = .disconnected
            self.drainTimer?.invalidate(); self.drainTimer = nil; self.writeQueue.removeAll()
            self.transitionTask?.cancel()
            self.systemAudio.onBands = nil
            self.screenSampler.onColor = nil
            self.syncMode = .off
            self.syncTransitioning = false
            Task { await self.systemAudio.stop() }
            Task { await self.screenSampler.stop() }
            if error != nil { self.scheduleReconnect() }
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
                self.isOn = true
                // Power-cycle on connect (mirrors OEM app init), then clear animation
                Task { @MainActor in
                    self.write(Cmd.powerOff)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    self.write(Cmd.powerOn)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let (h, s, _) = self.color.hsvComponents
                    self.write(Cmd.hue(h, saturation: s))
                    self.write(Cmd.brightness(self.brightness))
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
        }
    }
}

// MARK: - Command encoder (BC/55 protocol, confirmed via PacketLogger 2026-08-23)
// Frame: BC [cmd] [data_len] [data × data_len] 55

private enum Cmd {
    // BC01: power. state=0x01 = ON, state=0x00 = OFF (confirmed by user 2026-08-23)
    // Miracles Star power-cycles on connect: sends OFF then ON as init reset
    static let powerOn:  [UInt8] = [0xBC, 0x01, 0x01, 0x01, 0x55]
    static let powerOff: [UInt8] = [0xBC, 0x01, 0x01, 0x00, 0x55]

    // BC04: hue (0–360°) + saturation (0–1000), big-endian 16-bit
    // Hue correction: strip's internal RGB mapping is non-linear.
    // LUT derived from color test 2026-08-23 + residual recal 2026-08-24:
    // (observed_display_deg, protocol_send_deg)
    // Inverts (sent→observed) pairs so user's intended color maps to correct protocol value.
    // 305-360° entries rederived from Phase 1 sweep residual errors (5-13° undershoot).
    private static let hueLUT: [(obs: Double, send: Double)] = [
        (0,   0), (8,   0), (20,  10), (32,  20), (41,  30), (60,  40),
        (89,  50), (109, 60), (123, 70), (135, 80), (145, 90),
        (149, 120),  // 100°-120° all display ~147-149°; send 120° as upper bound
        (173, 130), (188, 140), (198, 150), (203, 160), (206, 170),
        (209, 180), (212, 190), (215, 200), (217, 210), (220, 220),
        (222, 230), (226, 240), (229, 250), (239, 260), (247, 270),
        (252, 280), (255, 290), (259, 300), (264, 310), (269, 320),
        (276, 330), (286, 340),
        // Recalibrated from Phase 1 residuals — strip underperforms 5-13° in purple/magenta
        (305, 351), (310, 353), (320, 355), (330, 357), (340, 358), (360, 360)
    ]

    private static func correctedHueDeg(_ h: Double) -> Double {
        let deg = (h * 360).truncatingRemainder(dividingBy: 360)
        for i in 0..<hueLUT.count - 1 {
            let lo = hueLUT[i], hi = hueLUT[i + 1]
            if deg >= lo.obs && deg <= hi.obs {
                let t = (hi.obs - lo.obs) < 0.001 ? 0.0
                      : (deg - lo.obs) / (hi.obs - lo.obs)
                return lo.send + t * (hi.send - lo.send)
            }
        }
        return deg
    }

    static func hue(_ h: Double, saturation s: Double) -> [UInt8] {
        let H = UInt16(max(0, min(360, Int(correctedHueDeg(h)))))
        let S = UInt16(max(0, min(1000, Int(s * 1000))))
        return [0xBC, 0x04, 0x06,
                UInt8(H >> 8), UInt8(H & 0xFF),
                UInt8(S >> 8), UInt8(S & 0xFF),
                0x00, 0x00, 0x55]
    }

    // BC05: brightness 100–1000 (min 100 observed in capture)
    static func brightness(_ value: Double) -> [UInt8] {
        let B = UInt16(max(100, min(1000, Int(100 + value * 900))))
        return [0xBC, 0x05, 0x06,
                UInt8(B >> 8), UInt8(B & 0xFF),
                0x00, 0x00, 0x00, 0x00, 0x55]
    }

    // BC06: select effect (IDs seen: 0x01, 0x03, 0x35)
    static func effect(id: UInt8) -> [UInt8] {
        [0xBC, 0x06, 0x02, 0x00, id, 0x55]
    }

    // BC08: effect speed 0–100
    static func speed(_ value: Double) -> [UInt8] {
        let s = UInt8(max(0, min(100, Int(value * 100))))
        return [0xBC, 0x08, 0x01, s, 0x55]
    }

    // BC13 animation ID 0 = stop / no animation (IDs 1–253 start firmware patterns)
    static let stopAnimation: [UInt8] = [0xBC, 0x13, 0x02, 0x00, 0x00, 0x55]

    // (BC0F mic-reactive mode intentionally not used — app drives color directly)
}

// MARK: - Color helper

extension Color {
    // Returns (hue: 0-1, saturation: 0-1, brightness: 0-1)
    var hsvComponents: (Double, Double, Double) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        (NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self))
            .getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s), Double(b))
    }
}
