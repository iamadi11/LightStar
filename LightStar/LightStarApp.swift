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
            SettingsView()
                .environment(appDelegate.ble)
                .environment(appDelegate.presets)
                .environment(appDelegate.schedules)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        LightStarRuntime.register(ble: ble, presets: presets, schedules: schedules)
        WindowActions.openControl = { [weak self] in self?.showControlWindow() }
        WindowActions.closePopover = { [weak self] in self?.popover?.performClose(nil) }
        setupMenuBar()
        if UserDefaults.standard.object(forKey: "autoConnectOnLaunch") as? Bool ?? true {
            ble.connect()
        }
        startObservingBLE()
        setupGlobalHotKey()
        setupSleepWakeObserver()
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
                hasSyncToRestore: self.ble.lastSyncMode != .off
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
            rootView: MenuBarView()
                .environment(ble)
                .environment(presets)
                .environment(schedules)
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
        withObservationTracking {
            _ = ble.color
            _ = ble.isOn
            _ = ble.connectionState
            _ = ble.syncMode
            _ = ble.syncColor
            updateIcon()
            writeWidgetState()
        } onChange: {
            Task { @MainActor in self.startObservingBLE() }
        }
    }

    private func writeWidgetState() {
        widgetStateTask?.cancel()
        widgetStateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let (h, s, _) = self.ble.color.hsvComponents
            WidgetState(
                connected: self.ble.connectionState == .connected,
                isOn: self.ble.isOn,
                hue: h,
                saturation: s
            ).save()
            WidgetCenter.shared.reloadTimelines(ofKind: "LightStarWidget")
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
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
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
        let root = ControlWindowView()
            .environment(ble)
            .environment(presets)
            .environment(schedules)
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
        popover?.performClose(nil)
        openLightStarSettings()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openLightStarControlWindow()
    }

    // MARK: - Global keyboard shortcuts
    // ⌘⇧L — toggle power (id=1)
    // ⌘⇧S — toggle sync  (id=2)
    // Carbon RegisterEventHotKey needs no Accessibility permission.

    private var hotKeyRef2: EventHotKeyRef?

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

    func applicationWillTerminate(_ notification: Notification) {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = hotKeyRef2 { UnregisterEventHotKey(ref) }
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
            Task { @MainActor in self?.ble.pauseScreenSync() }
        }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.ble.resumeScreenSync() }
        }
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        removePopoverClickMonitor()
    }
}
