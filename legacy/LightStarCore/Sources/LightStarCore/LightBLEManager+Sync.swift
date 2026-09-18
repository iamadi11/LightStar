import SwiftUI
import CoreGraphics

public extension LightBLEManager {

    // MARK: - Sync state machine

    public func toggleSync() {
        let fallback: SyncMode
        #if os(macOS)
        fallback = .video
        #else
        fallback = .audio
        #endif
        setSyncMode(syncMode == .off ? (lastSyncMode == .off ? fallback : lastSyncMode) : .off)
    }

    public func setSyncMode(_ mode: SyncMode) {
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

    public func teardownSync() async {
        fadeTask?.cancel()
        systemAudio.onBands = nil
        micAudio.onBands = nil
        screenSampler.onColor = nil
        flashLevel = 0
        if audioInputSource == .stripMic { write(Cmd.stripMic(enabled: false)) }
        await systemAudio.stop()
        await micAudio.stop()
        await screenSampler.stop()
    }

    // MARK: - Display sleep/wake

    public func pauseScreenSync() {
        guard isSyncingVideo else { return }
        screenSampler.onColor = nil
        Task { await self.screenSampler.stop() }
    }

    public func resumeScreenSync() {
        guard isSyncingVideo else { return }
        Task { [weak self] in
            guard let self else { return }
            try? await self.screenSampler.start()
            await MainActor.run { self.setupScreenCallback() }
        }
    }

    // Synchronously tears down all sync state — safe to call from non-async context.
    public func stopSyncInline() {
        transitionTask?.cancel(); transitionTask = nil
        fadeTask?.cancel(); fadeTask = nil
        probeTask?.cancel(); probeTask = nil
        syncTransitioning = false
        if syncMode != .off {
            lastSyncMode = syncMode
            UserDefaults.standard.set(syncMode.rawValue, forKey: "lastSyncMode")
        }
        systemAudio.onBands = nil
        micAudio.onBands = nil
        screenSampler.onColor = nil
        flashLevel = 0
        syncMode = .off
        syncColor = nil
        Task { await self.systemAudio.stop(); await self.micAudio.stop(); await self.screenSampler.stop() }
    }

    public func buildSync(_ mode: SyncMode, previousMode: SyncMode = .off) async {
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
            if audioInputSource == .stripMic {
                write(Cmd.stripMic(enabled: true))
                write(Cmd.micStyle(UInt8(micStyle.rawValue)))
                write(Cmd.micSensitivity(Int(micSensitivity * 255)))
                syncMode = .audio
            } else {
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
            }

        case .combined:
            setupScreenCallback()
            screenSampler.selectedDisplayID = selectedDisplayID
            var screenErr: Error? = nil
            var audioErr:  Error? = nil
            async let screenStart: () = screenSampler.start()
            do { try await screenStart } catch { screenSampler.onColor = nil; screenErr = error }

            if audioInputSource == .stripMic {
                write(Cmd.stripMic(enabled: true))
                write(Cmd.micStyle(UInt8(micStyle.rawValue)))
                write(Cmd.micSensitivity(Int(micSensitivity * 255)))
            } else {
                let useMic = audioInputSource == .mic
                setupAudioCallback(useMic: useMic)
                do {
                    if useMic { try await micAudio.start() } else { try await systemAudio.start() }
                } catch {
                    if useMic { micAudio.onBands = nil } else { systemAudio.onBands = nil }
                    audioErr = error
                }
            }
            let screenOk = screenSampler.onColor != nil
            let audioOk: Bool
            if audioInputSource == .stripMic {
                audioOk = true
            } else if audioInputSource == .mic {
                audioOk = micAudio.onBands != nil
            } else {
                audioOk = systemAudio.onBands != nil
            }
            syncMode = screenOk && audioOk ? .combined
                     : screenOk           ? .video
                     : audioOk            ? .audio
                     :                     .off
            if let e = screenErr ?? audioErr { setSyncError(e) }
            if syncMode == .off { restoreSteadyState() }
        }
    }

    public func setupScreenCallback() {
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
            if smoothH < 0 { smoothH = h; smoothS = s; smoothV = v }
            var dh = h - smoothH
            if dh > 0.5 { dh -= 1 }; if dh < -0.5 { dh += 1 }
            smoothH = (smoothH + dh * α).truncatingRemainder(dividingBy: 1)
            if smoothH < 0 { smoothH += 1 }
            smoothS = smoothS + (s - smoothS) * α
            smoothV = smoothV + (v - smoothV) * 0.15
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

    public func setupAudioCallback(useMic: Bool = false) {
        var lastWrite: Double = 0
        var silenceStart: Double = 0
        let callback: (FrequencyBands) -> Void = { [weak self] (bands: FrequencyBands) in
            guard let self, self.isSyncingAudio, self.isOn else { return }
            let now = CACurrentMediaTime()

            if bands.rms < 0.01 {
                if silenceStart == 0 { silenceStart = now }
                // Silence auto-off is audio-only. Combined would kill screen sync
                // during a quiet film scene, and must not clobber lastSyncMode.
                if now - silenceStart >= 2.0 {
                    silenceStart = 0
                    Task { @MainActor [weak self] in
                        guard let self, self.syncMode == .audio else { return }
                        self.lastSyncMode = .audio
                        UserDefaults.standard.set(SyncMode.audio.rawValue, forKey: "lastSyncMode")
                        self.setSyncMode(.off)
                    }
                    return
                }
            } else {
                silenceStart = 0
            }

            guard now - lastWrite >= 1.0 / 30.0 else { return }
            lastWrite = now

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
                let hTotal = bands.mid + bands.high + 0.001
                let h = (bands.mid * (120/360.0) + bands.high * (240/360.0)) / hTotal
                self.syncColor = Color(hue: h, saturation: 1.0, brightness: 1)
                self.write(Cmd.audioHue(h, saturation: 1.0))
                self.write(Cmd.brightness(min(1.0, max(0.05, (bands.bass + bands.mid + bands.high) / 3 * 1.5 + bands.rms * 0.2))))
            }
        }
        if useMic { micAudio.onBands = callback } else { systemAudio.onBands = callback }
    }

    public func setSyncError(_ error: Error) {
        let nsErr = error as NSError
        if nsErr.domain == "MicAudio" && nsErr.code == -5001 {
            syncNeedsPermission = true
            syncError = "Microphone access required. Open Privacy & Security → Microphone and enable LightStar. (Re-grant required after each update.)"
            pendingSyncMode = syncMode == .off ? pendingSyncMode : syncMode
            return
        }
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
    public func retryPendingSyncIfNeeded() {
        guard syncNeedsPermission, let mode = pendingSyncMode else { return }
        pendingSyncMode = nil
        syncNeedsPermission = false
        syncError = nil
        setSyncMode(mode)
    }

    public func restoreSteadyState() {
        guard isOn else { return }
        let (h, s, _) = color.hsvComponents
        write(Cmd.hue(h, saturation: s))
        write(Cmd.brightness(brightness))
    }

    public func fadeToSteadyState(from prevMode: SyncMode) {
        guard isOn else { return }
        let (targetH, targetS, _) = color.hsvComponents
        let targetBri = brightness

        let startH: Double
        let startS: Double
        let startBri: Double
        switch prevMode {
        case .video, .combined:
            startH = lastScreenH
            startS = lastScreenS
            startBri = targetBri
        case .audio:
            startH = audioPulseH
            startS = 0.9
            startBri = 1.0
        case .off:
            restoreSteadyState(); return
        }

        let hueDist = min(abs(startH - targetH), 1.0 - abs(startH - targetH))
        guard hueDist > 0.02 || abs(startS - targetS) > 0.05 || abs(startBri - targetBri) > 0.05 else {
            restoreSteadyState(); return
        }

        fadeTask = Task { @MainActor in
            let steps = 18
            for i in 1...steps {
                guard !Task.isCancelled else { return }
                let t = Double(i) / Double(steps)
                let e = t < 0.5 ? 2*t*t : -1 + (4 - 2*t)*t

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
                catch { return }
            }
            self.restoreSteadyState()
        }
    }

    public func loadAvailableDisplays() {
        Task {
            let displays = await ScreenColorSampler.availableDisplays()
            await MainActor.run { self.availableDisplays = displays }
        }
    }
}
