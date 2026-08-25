import SwiftUI
import AppKit
import Carbon.HIToolbox
import AVFoundation
import ScreenCaptureKit

@main
struct LightStarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hotKeyRef: EventHotKeyRef?
    lazy var ble = LightBLEManager()
    lazy var presets = PresetStore()
    lazy var schedules: ScheduleStore = {
        let s = ScheduleStore()
        s.ble = ble
        return s
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()
        if UserDefaults.standard.object(forKey: "autoConnectOnLaunch") as? Bool ?? true {
            ble.connect()
        }
        startObservingBLE()
        setupGlobalHotKey()
        setupSleepWakeObserver()
        ble.onConnect = { [weak self] in
            guard let self,
                  let id = self.presets.defaultPresetID,
                  let preset = self.presets.presets.first(where: { $0.id == id })
            else { return }
            self.ble.setColor(preset.color)
            self.ble.setBrightness(preset.brightness)
        }
        Task { await requestAllPermissions() }
    }

    // MARK: - Permissions

    private func requestAllPermissions() async {
        // Camera — only prompt once; macOS TCC handles subsequent launches automatically.
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            await AVCaptureDevice.requestAccess(for: .video)
        }
        // Screen Recording / system audio: do NOT call SCShareableContent here.
        // On macOS 15 it re-shows the TCC dialog on every launch even when already
        // granted. ScreenCaptureKit requests the entitlement lazily the first time
        // sync actually starts, which is the correct UX.
        // Bluetooth triggered automatically by CBCentralManager init.
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
        popover.contentSize = NSSize(width: 320, height: 480)
        popover.behavior = .transient
        schedules.reschedule()
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView()
                .environment(ble)
                .environment(presets)
                .environment(schedules)
        )
        self.popover = popover
    }

    // Recursively re-registers with @Observable so every state change redraws the icon.
    private func startObservingBLE() {
        withObservationTracking {
            _ = ble.color
            _ = ble.isOn
            _ = ble.connectionState
            _ = ble.syncMode
            updateIcon()
        } onChange: {
            Task { @MainActor in self.startObservingBLE() }
        }
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let syncing = ble.syncMode != .off
        let color: NSColor? = (ble.connectionState == .connected && ble.isOn)
            ? NSColor(ble.color) : nil
        button.image = iconImage(color: color, isOn: ble.isOn, syncing: syncing)
    }

    // Draws a colored lightbulb (syncing → waveform overlay); gray when off/disconnected.
    private func iconImage(color: NSColor?, isOn: Bool, syncing: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let symbolName = syncing ? "waveform" : "lightbulb.fill"
        let img = NSImage(size: size, flipped: false) { rect in
            guard let sym = NSImage(systemSymbolName: symbolName,
                                    accessibilityDescription: nil) else { return false }
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            let tinted = sym.withSymbolConfiguration(cfg) ?? sym
            let tintColor = color ?? (isOn ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor)
            // Fill with tint, then composite symbol as alpha mask — avoids cgImage nil crash
            tintColor.setFill()
            rect.fill()
            tinted.draw(in: rect, from: NSRect(origin: .zero, size: tinted.size),
                        operation: .destinationIn, fraction: 1.0)
            return true
        }
        img.isTemplate = false
        return img
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        // Right-click → context menu with Quit; left-click → toggle popover
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "Quit LightStar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            statusItem?.popUpMenu(menu)
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
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

    // MARK: - Sleep / Wake reconnect

    private func setupSleepWakeObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                let autoConnect = UserDefaults.standard.object(forKey: "autoConnectOnLaunch") as? Bool ?? true
                guard autoConnect, self.ble.connectionState == .disconnected else { return }
                Task { @MainActor in self.ble.connect() }
            }
    }
}
