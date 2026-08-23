import SwiftUI
import AppKit

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
    private var globalMonitor: Any?
    lazy var ble = LightBLEManager()
    lazy var presets = PresetStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()
        ble.connect()             // always auto-connect on launch
        startObservingBLE()
        setupGlobalHotKey()
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

    private func setupGlobalHotKey() {
        // Request Accessibility permission — system shows one-time prompt.
        // Without it, global monitor silently receives no events.
        let opts: CFDictionary = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)

        guard trusted else {
            // Re-check after a delay; user may grant in System Settings
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await MainActor.run { self.setupGlobalHotKey() }
            }
            return
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // ⌘⇧L
            guard event.modifierFlags.intersection([.command, .shift, .option, .control])
                    == [.command, .shift],
                  event.keyCode == 37 else { return }   // 37 = L
            Task { @MainActor in
                guard let self else { return }
                self.ble.setPower(on: !self.ble.isOn)
            }
        }
    }
}
