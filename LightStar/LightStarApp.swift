import SwiftUI
import LightStarCore
import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import WidgetKit

@main
struct LightStarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            appDelegate.withAppState(SettingsView())
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var popoverClickMonitor: Any?
    private var hotKeyRef: EventHotKeyRef?
    private var controlWindowController: NSWindowController?
    private var settingsWindowController: NSWindowController?
    lazy var ble = LightBLEManager()
    lazy var presets = PresetStore()
    private var widgetStateTask: Task<Void, Never>?
    private var cachedIconImage: NSImage?
    private var cachedIconColor: NSColor?
    private var cachedIconIsOn: Bool = false
    private var cachedIconSyncing: Bool = false
    lazy var schedules: ScheduleStore = {
        let s = ScheduleStore()
        s.ble = ble
        return s
    }()
    
    /// Remote control coordinator for iPhone connectivity.
    lazy var remoteControl: RemoteControlCoordinator = {
        RemoteControlCoordinator(ble: ble)
    }()

    /// Echo Dot discovers this as a Hue bridge; commands land on `ble`.
    lazy var alexaBridge = AlexaHueBridge()

    /// Mi Bedside Lamp on the LAN. Follows strip colour without writing BLE.
    lazy var yeelight = YeelightLampController()
    lazy var homeKitLamp = HomeKitLampController()
    /// Philips / WiZ gradient floor lamp over WiZ UDP. Follows the strip and takes segments.
    lazy var wizLamp = WizLampController()
    /// The Canvas liquid; runs for its window and, in canvas mode, for the lights.
    lazy var canvas: CanvasEngine = {
        let engine = CanvasEngine()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { engine.motionScale = 0.4 }
        let sound = CanvasSound()
        sound.enabled = CanvasSound.stored
        engine.sound = sound
        return engine
    }()
    /// The Mac's sound for the Canvas's Music mode; separate from Music sync's own tap.
    private let canvasAudio = SystemAudioSampler()

    /// Every shared object a LightStar view may read. One list for the popover,
    /// the control window, and both ways of opening Settings: the ⌘, Settings
    /// scene had its own list without the lightbar and crashed on open.
    func withAppState<V: View>(_ view: V) -> some View {
        view
            .environment(ble)
            .environment(presets)
            .environment(schedules)
            .environment(yeelight)
            .environment(homeKitLamp)
            .environment(wizLamp)
            .environment(\.canvasEngine, canvas)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        LightStarRuntime.register(ble: ble, presets: presets, schedules: schedules)
        LightStarRuntime.wizLamp = wizLamp
        ble.onLightbarLook = { [weak self] look in
            guard let self else { return }
            self.ble.setLampEffect(nil)
            if let scene = look.scene {
                self.wizLamp.setScene(scene)
            } else if let colours = look.segmentColours {
                self.wizLamp.setSegments(colours)
            }
        }
        WindowActions.openControl = { [weak self] in self?.showControlWindow() }
        WindowActions.openSettings = { [weak self] in self?.showSettingsWindow() }
        WindowActions.openCanvas = { [weak self] in self?.showCanvasWindow() }
        WindowActions.closePopover = { [weak self] in self?.popover?.performClose(nil) }
        setupMenuBar()
        if UserDefaults.standard.object(forKey: "autoConnectOnLaunch") as? Bool ?? true {
            ble.connect()
        }
        startObservingBLE()
        setupGlobalHotKey()
        setupSleepWakeObserver()
        configureAlexaBridge()
        ble.onConnect = { [weak self] in
            guard let self else { return }
            // Drain first: a schedule that fired while disconnected is what asked
            // for this connection, so it should win over the default preset.
            let pendingCount = self.schedules.drainPendingActions()
            self.schedules.pushFirmwareTimers()
            guard ConnectAppearancePolicy.shouldApplyDefaultPreset(
                isOn: self.ble.isOn,
                isSyncing: self.ble.syncMode != .off,
                pendingScheduleCount: pendingCount,
                hasSyncToRestore: self.ble.restoreSyncOnReconnect
            ),
                  let id = self.presets.defaultPresetID,
                  let preset = self.presets.presets.first(where: { $0.id == id })
            else { return }
            self.ble.setColor(preset.color)
            self.ble.setBrightness(preset.brightness)
        }
        schedules.fireDue()
        
        // Start remote control server for iPhone connectivity
        if UserDefaults.standard.object(forKey: "remoteControlEnabled") as? Bool ?? true {
            remoteControl.start()
        }

        if UserDefaults.standard.object(forKey: AlexaHueBridge.enabledDefaultsKey) as? Bool ?? false {
            alexaBridge.start()
        }
        configureYeelight()
        remoteControl.lampStatus = { [weak self] in
            guard let self else { return ("stopped", nil) }
            // The phone has one lamp row: the lightbar when it is chosen, joined
            // with the Mi lamp's name when both are on.
            let target = self.ble.outputTarget
            if target.sendsToLightbar, case .following(let bar) = self.wizLamp.state {
                if target.sendsToMiLamp, case .following(let mi) = self.homeKitLamp.state {
                    return ("following", "\(mi) & \(bar)")
                }
                return ("following", bar)
            }
            if !target.sendsToMiLamp {
                if case .notFound = self.wizLamp.state { return ("failed", "No lightbar on this network") }
                if case .blocked = self.wizLamp.state { return ("failed", "Allow Local Network for LightStar on the Mac") }
                return ("searching", nil)
            }
            switch self.homeKitLamp.state {
            case .stopped: return ("stopped", nil)
            case .searching: return ("searching", nil)
            case .needsCode: return ("needsCode", nil)
            case .pairing: return ("pairing", nil)
            case .following(let name): return ("following", name)
            case .failed(let message): return ("failed", message)
            }
        }
        remoteControl.onLampCode = { [weak self] code in
            self?.homeKitLamp.connect(setupCode: code)
        }
        remoteControl.lightbarStatus = { [weak self] in
            guard let self else { return nil }
            let phase: String
            switch self.wizLamp.state {
            case .stopped: phase = "stopped"
            case .searching: phase = "searching"
            case .following: phase = "following"
            case .notFound: phase = "notFound"
            case .blocked: phase = "blocked"
            }
            let effect = self.ble.lampEffect?.name
            return LightbarState(
                phase: phase,
                effect: effect,
                sceneID: effect == nil ? self.wizLamp.look?.scene : nil,
                whiteTone: UserDefaults.standard.object(forKey: WizLampController.whiteToneDefaultsKey) as? Double ?? 1,
                gradientSync: LampGradient.enabled,
                musicStyle: LampGradient.musicStyle.rawValue,
                edge: LampGradient.edge.rawValue,
                ignoreBars: LampGradient.ignoreBars,
                orientation: LampGradient.orientation.rawValue
            )
        }
        // Same actions as Settings → Lightbar.
        remoteControl.onLightbar = { [weak self] change in
            guard let self else { return }
            let d = UserDefaults.standard
            if change.stopEffect == true { self.ble.setLampEffect(nil) }
            if let name = change.effect, let effect = LampEffect.named(name) {
                self.ble.setLampEffect(effect.withUserPalette())
            }
            if let id = change.scene, WizScene.all.contains(where: { $0.id == id }) {
                self.ble.setLampEffect(nil)
                self.wizLamp.setScene(id)
            }
            if let tone = change.whiteTone, tone.isFinite { self.wizLamp.setWhiteTone(max(0, min(1, tone))) }
            if let on = change.gradientSync { d.set(on, forKey: LampGradient.enabledDefaultsKey) }
            if let style = change.musicStyle, LampGradient.MusicStyle(rawValue: style) != nil {
                d.set(style, forKey: LampGradient.musicStyleDefaultsKey)
            }
            if let edge = change.edge, LampGradient.Edge(rawValue: edge) != nil {
                d.set(edge, forKey: LampGradient.edgeDefaultsKey)
            }
            if let ignore = change.ignoreBars { d.set(ignore, forKey: LampGradient.ignoreBarsDefaultsKey) }
            self.remoteControl.publishState()
        }
        remoteControl.canvasStatus = { [weak self] in self?.canvas.remoteState(quality: .stored) }
        // Same settings as the Canvas section, plus play from the phone (stirs,
        // taps, wells, tilt, shakes). Each phone paints in its own colour.
        remoteControl.onCanvas = { [weak self] change in
            guard let self else { return }
            self.applyCanvasChange(change)
        }
        homeKitLamp.onStateChange = { [weak self] in
            self?.remoteControl.publishState()
        }
        wizLamp.onStateChange = { [weak self] in
            self?.remoteControl.publishState()
        }
        ble.onOutputTargetChange = { [weak self] target in
            if !target.sendsToLightbar { self?.ble.setLampEffect(nil) }
            self?.applyLampFollow(target)
            self?.remoteControl.publishState()
        }
        applyLampFollow(ble.outputTarget)
        let lamp = wizLamp
        ble.startLampPipe { frame in lamp.streamFrame(frame.zones, sides: frame.sides) }
        let ble = self.ble
        let (w, h) = CanvasEngine.lightSize
        canvas.onLightFrame = { bytes, bytesPerRow in
            ble.takeCanvasFrame(bytes, bytesPerRow: bytesPerRow, width: w, height: h)
        }
        ble.onCanvasMode = { [weak self] on in self?.canvas.drivesLights = on }
        let canvasAudio = self.canvasAudio
        canvas.onNeedsAudio = { [weak self] on in
            Task { @MainActor in
                if on {
                    canvasAudio.onBands = { b in
                        self?.canvas.feedAudio(bass: b.bass, mid: b.mid, high: b.high, rms: b.rms, flux: b.flux)
                    }
                    try? await canvasAudio.start()
                } else {
                    await canvasAudio.stop()
                }
            }
        }
        canvas.onStateChange = { [weak self] in self?.remoteControl.publishState() }
        canvas.onMoodEnded = { [weak self] mood in
            guard let self, mood == .windDown else { return }
            // Wind-down's room has already dimmed to almost nothing: finish by turning the lights off.
            if self.ble.syncMode == .canvas { self.ble.setSyncMode(.off) }
            self.ble.setPower(on: false)
            UserDefaults.standard.set(CanvasMood.none.rawValue, forKey: CanvasMood.defaultsKey)
            self.canvas.applySettings()
        }
        startDayWhiteTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        yeelight.stop()
        homeKitLamp.stop()
        wizLamp.stop()
    }

    private func configureAlexaBridge() {
        alexaBridge.getLightSnapshot = { [weak self] in
            guard let self else {
                return HueLightSnapshot(isOn: false, hue: 0, saturation: 0, brightness: 1)
            }
            return HueLightSnapshot(
                isOn: self.ble.isOn,
                hue: self.ble.colorHue,
                saturation: self.ble.colorSat,
                brightness: self.ble.brightness
            )
        }
        alexaBridge.onApplyState = { [weak self] patch in
            guard let self else { return }
            if let on = patch.on {
                self.ble.setPower(on: on)
            }
            if let kelvin = patch.kelvin {
                let t = max(0, min(1, (kelvin - 2700) / 3800))
                self.ble.setColorTemperature(t)
            } else if patch.hue != nil || patch.saturation != nil {
                let h = patch.hue ?? self.ble.colorHue
                let s = patch.saturation ?? self.ble.colorSat
                self.ble.setHue(h, saturation: s)
            }
            if let bri = patch.brightness {
                self.ble.setBrightness(bri)
            }
            if patch.on == true, !self.ble.isOn {
                self.ble.setPower(on: true)
            }
        }
    }

    private func configureYeelight() {
        ble.onLampZones = { [weak self] zones, placement in
            self?.wizLamp.stream(zones, placement: placement)
        }
        ble.onLampMirror = { [weak self] update in
            self?.mirrorToLamps(update)
        }
        ble.onLampSides = { [weak self] sides in
            self?.wizLamp.streamSides(sides)
        }
        let push = { [weak self] in
            guard let self else { return }
            let updates: [YeelightMirrorUpdate] = [
                .power(self.ble.isOn),
                .color(hue: self.ble.colorHue, saturation: self.ble.colorSat),
                .brightness(self.ble.brightness)
            ]
            for update in updates {
                self.mirrorToLamps(update)
            }
        }
        yeelight.onFollowing = push
        homeKitLamp.onFollowing = push
        wizLamp.onFollowing = push
    }

    func setYeelightMirrorEnabled(_ enabled: Bool) {
        ble.outputTarget = enabled ? .both : .strip
    }

    /// Only the lamps chosen under Control follow the strip.
    private func mirrorToLamps(_ update: YeelightMirrorUpdate) {
        if ble.outputTarget.sendsToMiLamp {
            yeelight.submit(update)
            homeKitLamp.submit(update)
        }
        if ble.outputTarget.sendsToLightbar {
            if case .color = update, LampGradient.dayWhiteEnabled {
                let white = LampGradient.dayWhite()
                wizLamp.submit(.color(hue: white.hue, saturation: white.saturation))
            } else {
                wizLamp.submit(update)
            }
        }
    }

    /// Day-cycle white drifts through the day; a scene or effect keeps the bar.
    private func startDayWhiteTimer() {
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, LampGradient.dayWhiteEnabled, self.ble.outputTarget.sendsToLightbar,
                      self.wizLamp.look == nil, self.ble.lampEffect == nil else { return }
                let white = LampGradient.dayWhite()
                self.wizLamp.submit(.color(hue: white.hue, saturation: white.saturation))
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    /// Each lamp runs only while it is a chosen light.
    private func applyLampFollow(_ target: LightOutputTarget) {
        UserDefaults.standard.set(target.sendsToMiLamp, forKey: YeelightLampController.enabledDefaultsKey)
        if target.sendsToLamp { configureYeelight() }
        if target.sendsToMiLamp {
            yeelight.start()
            homeKitLamp.start()
        } else {
            yeelight.stop()
            homeKitLamp.stop()
        }
        if target.sendsToLightbar {
            wizLamp.start()
        } else {
            wizLamp.stop()
        }
    }

    func setAlexaBridgeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: AlexaHueBridge.enabledDefaultsKey)
        if enabled {
            configureAlexaBridge()
            alexaBridge.start()
        } else {
            alexaBridge.stop()
        }
    }

    // MARK: - Menu bar icon

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }
        button.image = iconImage(color: nil, isOn: false)
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 336, height: 420)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        schedules.reschedule()
        let hosting = NSHostingController(
            rootView: withAppState(MenuBarView())
        )
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        popover.contentViewController = hosting
        self.popover = popover
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closePopoverOnBlur),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    // Recursively re-registers with @Observable so every state change redraws the icon.
    private func startObservingBLE() {
        startObservingWidgetAndConnection()
        startObservingIcon()
    }

    /// Widget JSON uses static color/power/connection — not 20–30 Hz syncColor.
    private func startObservingWidgetAndConnection() {
        withObservationTracking {
            _ = ble.color
            _ = ble.isOn
            _ = ble.connectionState
            _ = ble.outputTarget
            _ = wizLamp.state
            _ = homeKitLamp.state
            writeWidgetState()
        } onChange: {
            Task { @MainActor in self.startObservingWidgetAndConnection() }
        }
    }

    /// Menu-bar icon still follows live syncColor (product), plus power/connection/mode.
    private func startObservingIcon() {
        withObservationTracking {
            _ = ble.color
            _ = ble.isOn
            _ = ble.connectionState
            _ = ble.syncMode
            _ = ble.syncColor
            updateIcon()
        } onChange: {
            Task { @MainActor in self.startObservingIcon() }
        }
    }

    private func writeWidgetState() {
        widgetStateTask?.cancel()
        widgetStateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let (h, s, _) = self.ble.color.hsvComponents
            // "Connected" means any chosen light, so a lightbar-only setup isn't "Offline".
            WidgetState(
                connected: LightReach.any(self.ble, miLamp: self.homeKitLamp, lightbar: self.wizLamp),
                isOn: self.ble.isOn,
                hue: h,
                saturation: s,
                lightbar: self.widgetLightbarLine
            ).saveInBackground {
                WidgetCenter.shared.reloadTimelines(ofKind: "LightStarWidget")
            }
        }
    }

    private var widgetLightbarLine: String? {
        guard ble.outputTarget.sendsToLightbar else { return nil }
        switch wizLamp.state {
        case .following(let name): return "\(name) · \(ble.isOn ? "On" : "Off")"
        case .searching: return "Lightbar · Finding"
        case .notFound, .blocked: return "Lightbar · Not found"
        case .stopped: return nil
        }
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let syncing = ble.syncMode != .off
        // During sync show live syncColor; otherwise show the static color when on.
        let color: NSColor?
        if syncing, let sc = ble.syncColor {
            color = NSColor(sc)
        } else if ble.connectionState == .connected && ble.isOn {
            color = NSColor(ble.color)
        } else {
            color = nil
        }
        button.image = iconImage(color: color, isOn: ble.isOn, syncing: syncing)
        if let err = ble.connectionError {
            button.toolTip = "LightStar — \(err)"
        } else {
            switch ble.connectionState {
            case .connected:  button.toolTip = "LightStar — Connected\(ble.isOn ? "" : " (off)")"
            case .scanning:   button.toolTip = "LightStar — Scanning…"
            case .connecting: button.toolTip = "LightStar — Connecting…"
            case .disconnected: button.toolTip = "LightStar — Disconnected"
            }
        }
    }

    // Draws a colored lightbulb (syncing → waveform); gray when off/disconnected.
    // Cached: returns the same NSImage when color+state haven't changed (skips alloc + CA redraw).
    private func iconImage(color: NSColor?, isOn: Bool, syncing: Bool = false) -> NSImage {
        let colorUnchanged: Bool = {
            switch (cachedIconColor, color) {
            case (nil, nil): return true
            case (nil, _), (_, nil): return false
            case let (a?, b?):
                guard let a = a.usingColorSpace(.sRGB),
                      let b = b.usingColorSpace(.sRGB) else { return false }
                var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0
                var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0
                a.getRed(&r1, green: &g1, blue: &b1, alpha: nil)
                b.getRed(&r2, green: &g2, blue: &b2, alpha: nil)
                return abs(r1-r2) < 0.008 && abs(g1-g2) < 0.008 && abs(b1-b2) < 0.008
            }
        }()
        if colorUnchanged, isOn == cachedIconIsOn, syncing == cachedIconSyncing,
           let cached = cachedIconImage { return cached }

        let size = NSSize(width: 18, height: 18)
        let symbolName = syncing ? "waveform" : "lightbulb.fill"
        let img = NSImage(size: size, flipped: false) { rect in
            guard let sym = NSImage(systemSymbolName: symbolName,
                                    accessibilityDescription: nil) else { return false }
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            let tinted = sym.withSymbolConfiguration(cfg) ?? sym
            let tintColor = color ?? (isOn ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor)
            tintColor.setFill()
            rect.fill()
            tinted.draw(in: rect, from: NSRect(origin: .zero, size: tinted.size),
                        operation: .destinationIn, fraction: 1.0)
            return true
        }
        img.isTemplate = false
        cachedIconImage = img
        cachedIconColor = color
        cachedIconIsOn = isOn
        cachedIconSyncing = syncing
        return img
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            statusItem?.popUpMenu(buildContextMenu())
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if let window = popover.contentViewController?.view.window {
                window.isOpaque = false
                window.backgroundColor = .clear
                window.makeKey()
            }
            NSApp.activate(ignoringOtherApps: true)
            installPopoverClickMonitor()
        }
    }

    @objc private func closePopoverOnBlur() {
        popover?.performClose(nil)
    }

    private func installPopoverClickMonitor() {
        removePopoverClickMonitor()
        popoverClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.popover?.performClose(nil)
            }
        }
    }

    private func removePopoverClickMonitor() {
        if let popoverClickMonitor {
            NSEvent.removeMonitor(popoverClickMonitor)
            self.popoverClickMonitor = nil
        }
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        // Power toggle
        let powerTitle = ble.connectionState == .connected
            ? (ble.isOn ? "Turn Off" : "Turn On")
            : "Not Connected"
        let powerItem = NSMenuItem(title: powerTitle, action: #selector(contextTogglePower), keyEquivalent: "")
        powerItem.isEnabled = ble.connectionState == .connected
        menu.addItem(powerItem)

        // Sync toggle
        let syncTitle = ble.syncMode == .off ? "Enable Sync" : "Disable Sync (\(ble.syncMode.rawValue))"
        let syncItem = NSMenuItem(title: syncTitle, action: #selector(contextToggleSync), keyEquivalent: "")
        syncItem.isEnabled = ble.connectionState == .connected
        menu.addItem(syncItem)

        menu.addItem(.separator())

        // Presets submenu
        if !presets.presets.isEmpty {
            let presetsMenu = NSMenu()
            for preset in presets.presets {
                let item = NSMenuItem(title: preset.name, action: #selector(contextApplyPreset(_:)), keyEquivalent: "")
                item.representedObject = preset.id.uuidString
                item.isEnabled = ble.connectionState == .connected
                if presets.defaultPresetID == preset.id {
                    item.state = .on
                }
                presetsMenu.addItem(item)
            }
            let presetsItem = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
            presetsItem.submenu = presetsMenu
            menu.addItem(presetsItem)
            menu.addItem(.separator())
        }

        menu.addItem(NSMenuItem(title: "Open Window", action: #selector(showControlWindow), keyEquivalent: ""))
        let canvasItem = NSMenuItem(title: "Open Canvas", action: #selector(showCanvasWindow), keyEquivalent: "")
        canvasItem.target = self
        menu.addItem(canvasItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Send Feedback…", action: #selector(contextSendFeedback), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LightStar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func contextSendFeedback() {
        let subject = "LightStar Feedback".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        NSWorkspace.shared.open(URL(string: "mailto:adityaraj92.20@gmail.com?subject=\(subject)")!)
    }

    @objc private func contextTogglePower() {
        ble.setPower(on: !ble.isOn)
    }

    @objc private func contextToggleSync() {
        ble.toggleSync()
    }

    @objc private func contextApplyPreset(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr),
              let preset = presets.presets.first(where: { $0.id == id })
        else { return }
        if !ble.isOn { ble.setPower(on: true) }
        ble.setColor(preset.color)
        ble.setBrightness(preset.brightness)
    }

    @objc private func showControlWindow() {
        popover?.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let existing = controlWindowController?.window {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let root = withAppState(ControlWindowView())
        let vc = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: vc)
        window.title = "LightStar"
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
        window.setContentSize(NSSize(width: 720, height: 640))
        window.identifier = NSUserInterfaceItemIdentifier("control")
        window.isReleasedWhenClosed = false
        let controller = NSWindowController(window: window)
        controlWindowController = controller
        controller.showWindow(nil)
    }

    @objc private func showSettings() {
        showSettingsWindow()
    }

    private func showSettingsWindow() {
        popover?.performClose(nil)
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let existing = settingsWindowController?.window {
            existing.level = .floating
            existing.center()
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            return
        }
        let root = withAppState(SettingsView())
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 480, height: 640))
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .managed]
        window.center()
        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in
                if NSApp.activationPolicy() == .regular {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.host == "canvas" }) {
            showCanvasWindow()
        } else {
            openLightStarControlWindow()
        }
    }

    // MARK: - Canvas

    /// A Canvas change from the phone: settings first, then play.
    private func applyCanvasChange(_ change: SetCanvasMessage) {
        let d = UserDefaults.standard
        var settingsChanged = false
        if let raw = change.mood, let mood = CanvasMood(rawValue: raw) { canvas.applyMood(mood) }
        if let raw = change.mode, CanvasMode(rawValue: raw) != nil {
            d.set(raw, forKey: CanvasMode.defaultsKey); settingsChanged = true
        }
        if let raw = change.style, CanvasStyle(rawValue: raw) != nil {
            d.set(raw, forKey: CanvasStyle.defaultsKey); settingsChanged = true
        }
        if let folds = change.symmetry, CanvasSymmetry.choices.contains(folds) {
            d.set(folds, forKey: CanvasSymmetry.defaultsKey); settingsChanged = true
        }
        if let raw = change.quality, CanvasQuality(rawValue: raw) != nil {
            d.set(raw, forKey: CanvasQuality.defaultsKey)
            canvas.applyQuality()
        }
        if let on = change.sound {
            d.set(on, forKey: CanvasSound.defaultsKey)
            canvas.sound?.enabled = on
        }
        if settingsChanged { canvas.applySettings() }

        // Phones send points 0…1; anything outside a small margin is dropped.
        func point(_ v: [Double], _ i: Int = 0) -> CGPoint? {
            guard v.count >= i + 2, v[i...i + 1].allSatisfy({ $0.isFinite && (-0.1...1.1).contains($0) }) else { return nil }
            return CGPoint(x: v[i], y: v[i + 1])
        }
        let player = change.player.map { String($0.prefix(64)) }
        let finger = "finger\(change.finger ?? 0)"
        if let s = change.stir, s.count == 4, let a = point(s), let b = point(s, 2) {
            canvas.stir(from: a, to: b, pressure: 0.5, player: player, pointer: finger)
        }
        if change.strokeEnd == true { canvas.endStroke(player: player, pointer: finger) }
        if let t = change.tap, let p = point(t) { canvas.tap(at: p, player: player) }
        if let w = change.well, w.count == 3, let p = point(w) { canvas.plantWell(at: p, repel: w[2] < 0, player: player) }
        if change.clearWells == true { canvas.clearWells() }
        if let g = change.tilt, g.count == 2, g.allSatisfy(\.isFinite) { canvas.setTilt(x: g[0], y: g[1]) }
        if change.shake == true { canvas.shake() }
    }

    private var canvasWindowController: NSWindowController?

    /// Live liquid art. Closing the window frees its GPU textures.
    @objc func showCanvasWindow() {
        popover?.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let existing = canvasWindowController?.window {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        // Opening the Canvas is asking for it: the lights follow it right away.
        if ble.syncMode != .canvas { ble.setSyncMode(.canvas) }
        let window = NSWindow(contentViewController: NSHostingController(rootView: withAppState(CanvasView(engine: canvas))))
        window.title = "Canvas"
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.setContentSize(NSSize(width: 960, height: 600))
        window.backgroundColor = .black
        window.identifier = NSUserInterfaceItemIdentifier("canvas")
        window.isReleasedWhenClosed = false
        // Opening it switches the lights to Canvas, so it must not reopen by itself after a relaunch.
        window.isRestorable = false
        // Open on the screen being used (the pointer's), not wherever the menu bar is.
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            let v = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: v.midX - window.frame.width / 2, y: v.midY - window.frame.height / 2))
        } else {
            window.center()
        }
        let controller = NSWindowController(window: window)
        canvasWindowController = controller
        controller.showWindow(nil)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.canvasWindowController = nil }
        }
    }

    // MARK: - Global keyboard shortcuts
    // ⌘⇧L — toggle power (id=1)
    // ⌘⇧S — toggle sync  (id=2)
    // Carbon RegisterEventHotKey needs no Accessibility permission.

    private var hotKeyRef2: EventHotKeyRef?
    private var awayReasons: Set<String> = []

    private func setupGlobalHotKey() {
        guard hotKeyRef == nil else { return }

        var hkID = EventHotKeyID()
        hkID.signature = 0x4C535452   // 'LSTR'

        hkID.id = 1
        RegisterEventHotKey(37, UInt32(cmdKey | shiftKey),
                             hkID, GetApplicationEventTarget(), 0, &hotKeyRef)

        hkID.id = 2
        RegisterEventHotKey(1, UInt32(cmdKey | shiftKey),       // keycode 1 = S
                             hkID, GetApplicationEventTarget(), 0, &hotKeyRef2)

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let ptr = userData, let event else { return noErr }
                var fired = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &fired)
                let d = Unmanaged<AppDelegate>.fromOpaque(ptr).takeUnretainedValue()
                switch fired.id {
                case 1: Task { @MainActor in d.ble.setPower(on: !d.ble.isOn) }
                case 2: Task { @MainActor in d.ble.toggleSync() }
                default: break
                }
                return noErr
            },
            1, &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            nil)
    }

    // MARK: - App activate (return from System Settings after granting permission)

    func applicationDidBecomeActive(_ notification: Notification) {
        // Retry sync if user just granted Screen Recording or Mic in System Settings.
        ble.retryPendingSyncIfNeeded()
        // Retry BT connect if user just granted Bluetooth in System Settings.
        ble.retryBluetoothPermission()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let ref = hotKeyRef2 { UnregisterEventHotKey(ref); hotKeyRef2 = nil }
        Task { @MainActor in
            await ble.restoreBrowserHardwareAccelerationForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Sleep / Wake reconnect

    private func setupSleepWakeObserver() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let autoConnect = UserDefaults.standard.object(forKey: "autoConnectOnLaunch") as? Bool ?? true
            Task { @MainActor in
                guard WakeReconnectPolicy.shouldReconnect(
                    autoConnect: autoConnect,
                    connectionState: self.ble.connectionState,
                    userInitiatedDisconnect: self.ble.userInitiatedDisconnect
                ) else { return }
                self.ble.connect()
                self.schedules.fireDue()
            }
        }
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.ble.pauseScreenSync()
                self?.setAway("screens", true)
            }
        }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.ble.resumeScreenSync()
                self?.setAway("screens", false)
            }
        }
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setAway("sleep", true) }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setAway("sleep", false) }
        }
        let dnc = DistributedNotificationCenter.default()
        let away: [(String, String, Bool)] = [
            ("com.apple.screenIsLocked", "lock", true), ("com.apple.screenIsUnlocked", "lock", false),
            ("com.apple.screensaver.didstart", "saver", true), ("com.apple.screensaver.didstop", "saver", false),
        ]
        for (name, reason, on) in away {
            dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setAway(reason, on) }
            }
        }
    }

    /// WiZ lights stay dark while any reason holds (screens off, asleep,
    /// locked, screensaver), so unlocking with the screens still off doesn't wake them.
    private func setAway(_ reason: String, _ on: Bool) {
        if on { awayReasons.insert(reason) } else { awayReasons.remove(reason) }
        wizLamp.setAway(LampGradient.offWhenAway && !awayReasons.isEmpty)
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        removePopoverClickMonitor()
    }
}
