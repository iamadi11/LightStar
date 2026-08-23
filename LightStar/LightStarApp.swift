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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()
        ble.connect()
        startObservingBLE()
        setupGlobalHotKey()
        Task { await requestAllPermissions() }
    }

    // MARK: - Permissions (request all upfront so macOS shows dialogs at launch)

    private func requestAllPermissions() async {
        // Camera (for protocol debug tab)
        await AVCaptureDevice.requestAccess(for: .video)
        // Screen Recording — triggers TCC prompt; also covers system audio via SCStream
        _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // Bluetooth triggered automatically by CBCentralManager init
    }

    // MARK: - Menu bar icon

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }
        button.image = iconImage(color: nil, isOn: false)
        button.action = #selector(togglePopover)
        button.target = self

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 480)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView()
                .environment(ble)
                .environment(presets)
        )
        self.popover = popover
    }

    // Recursively re-registers with @Observable so every state change redraws the icon.
    private func startObservingBLE() {
        withObservationTracking {
            _ = ble.color
            _ = ble.isOn
            _ = ble.connectionState
            updateIcon()
        } onChange: {
            Task { @MainActor in self.startObservingBLE() }
        }
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let color: NSColor? = (ble.connectionState == .connected && ble.isOn)
            ? NSColor(ble.color) : nil
        button.image = iconImage(color: color, isOn: ble.isOn)
    }

    // Draws a colored lightbulb; falls back to gray when off/disconnected.
    private func iconImage(color: NSColor?, isOn: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            guard let sym = NSImage(systemSymbolName: "lightbulb.fill",
                                    accessibilityDescription: nil) else { return false }
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            let tinted = sym.withSymbolConfiguration(cfg) ?? sym
            if let c = color {
                c.setFill()
            } else {
                (isOn ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setFill()
            }
            // Draw symbol as mask then fill with color
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.clip(to: rect, mask: tinted.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
            rect.fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Global keyboard shortcut (⌘⇧L — toggle power)
    // Carbon RegisterEventHotKey needs no Accessibility permission and
    // survives debug re-signs — no system prompt ever shown.

    private func setupGlobalHotKey() {
        guard hotKeyRef == nil else { return }

        var hkID = EventHotKeyID()
        hkID.signature = 0x4C535452   // 'LSTR'
        hkID.id = 1

        let status = RegisterEventHotKey(37, UInt32(cmdKey | shiftKey),
                                         hkID, GetApplicationEventTarget(),
                                         0, &hotKeyRef)
        guard status == noErr else {
            print("[LightStar] hotkey registration failed: \(status)")
            return
        }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let ptr = userData else { return noErr }
                let d = Unmanaged<AppDelegate>.fromOpaque(ptr).takeUnretainedValue()
                Task { @MainActor in d.ble.setPower(on: !d.ble.isOn) }
                return noErr
            },
            1, &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            nil)
    }
}
