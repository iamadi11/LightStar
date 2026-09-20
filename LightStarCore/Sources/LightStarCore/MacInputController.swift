#if os(macOS)
import Foundation
import CoreGraphics
import AppKit
import ApplicationServices
import CoreAudio
import Darwin
import os

private let inputLog = Logger(subsystem: "com.adityaraj.LightStar", category: "remote")

/// Posts iPhone trackpad/keyboard events as HID input. Requires Accessibility TCC.
@MainActor
public final class MacInputController: ObservableObject {

    @Published public private(set) var accessibilityEnabled = false
    @Published public var mouseSensitivity: Double = 1.0 {
        didSet { pointerInjector.mouseSensitivity = mouseSensitivity }
    }
    @Published public var scrollSensitivity: Double = 1.0 {
        didSet { pointerInjector.scrollSensitivity = scrollSensitivity }
    }

    public let pointerInjector = MacPointerInjector()
    private var didPromptAccessibility = false
    private var lastPromptAt: CFTimeInterval = -100
    private let eventSource = CGEventSource(stateID: .hidSystemState)

    public init() {
        eventSource?.localEventsSuppressionInterval = 0
        checkAccessibility()
        pointerInjector.mouseSensitivity = mouseSensitivity
        pointerInjector.scrollSensitivity = scrollSensitivity
    }

    public func checkAccessibility() {
        accessibilityEnabled = AXIsProcessTrusted()
    }

    /// Returns true when events can be injected. Prompts if missing, at most every 20s.
    @discardableResult
    public func ensureAccessibility() -> Bool {
        checkAccessibility()
        if accessibilityEnabled { return true }
        let now = ProcessInfo.processInfo.systemUptime
        if !didPromptAccessibility || now - lastPromptAt > 20 {
            didPromptAccessibility = true
            lastPromptAt = now
            requestAccessibility()
            checkAccessibility()
        }
        return accessibilityEnabled
    }

    public func requestAccessibility() {
        let previous = NSApp.activationPolicy()
        if previous != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        requestAccessibilityPermissionPrompt()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if NSApp.activationPolicy() == .regular {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    // MARK: - Mouse Control

    public func moveMouse(deltaX: Double, deltaY: Double) {
        guard ensureAccessibility() else { return }
        pointerInjector.move(deltaX: deltaX, deltaY: deltaY)
    }

    public func setMousePosition(x: Double, y: Double) {
        guard ensureAccessibility() else { return }
        pointerInjector.setPosition(x: x, y: y)
    }

    public func leftClick() {
        mouseDown(button: 0)
        mouseUp(button: 0)
    }

    public func rightClick() {
        mouseDown(button: 1)
        mouseUp(button: 1)
    }

    public func doubleClick() {
        guard ensureAccessibility() else { return }
        pointerInjector.doubleClick()
    }

    public func mouseDown(button: Int = 0, clickCount: Int = 1) {
        guard ensureAccessibility() else { return }
        pointerInjector.mouseDown(button: button, clickCount: clickCount)
    }

    public func mouseUp(button: Int = 0, clickCount: Int = 1) {
        guard ensureAccessibility() else { return }
        pointerInjector.mouseUp(button: button, clickCount: clickCount)
    }

    public func startDrag() {
        mouseDown(button: 0)
    }

    public func endDrag() {
        mouseUp(button: 0)
    }

    public func drag(deltaX: Double, deltaY: Double) {
        guard ensureAccessibility() else { return }
        pointerInjector.drag(deltaX: deltaX, deltaY: deltaY)
    }

    // MARK: - Scroll

    public func scroll(deltaX: Double, deltaY: Double) {
        guard ensureAccessibility() else { return }
        pointerInjector.scroll(deltaX: deltaX, deltaY: deltaY)
    }

    // MARK: - Keyboard

    public func pressKey(keyCode: UInt16, modifiers: CGEventFlags = []) {
        pressHotkey(keyCode: keyCode, modifiers: modifiers)
    }

    public func perform(_ action: MacSystemAction) {
        switch action {
        case .spotlight:
            pressHotkey(keyCode: 0x31, modifiers: .maskCommand)
        case .missionControl:
            if !openApp("/System/Applications/Mission Control.app") {
                pressHotkey(keyCode: 0x7E, modifiers: .maskControl)
            }
        case .applicationWindows:
            pressHotkey(keyCode: 0x7D, modifiers: .maskControl)
        case .desktop:
            if functionKeysAreStandard {
                pressHotkey(keyCode: 0x67)
            } else {
                pressHotkey(keyCode: 0x67, modifiers: .maskSecondaryFn)
            }
        case .launchpad:
            if !openApp("/System/Applications/Launchpad.app") && !openApp("/Applications/Launchpad.app") {
                pressHotkey(keyCode: 0x76, modifiers: functionKeysAreStandard ? [] : .maskSecondaryFn)
            }
        case .lockScreen:
            lockScreen()
        case .undo:
            pressHotkey(keyCode: 0x06, modifiers: .maskCommand)
        case .cut:
            pressHotkey(keyCode: 0x07, modifiers: .maskCommand)
        case .copy:
            pressHotkey(keyCode: 0x08, modifiers: .maskCommand)
        case .paste:
            pressHotkey(keyCode: 0x09, modifiers: .maskCommand)
        case .selectAll:
            pressHotkey(keyCode: 0x00, modifiers: .maskCommand)
        case .emoji:
            pressHotkey(keyCode: 0x31, modifiers: [.maskCommand, .maskControl])
        case .screenshot:
            pressHotkey(keyCode: 0x14, modifiers: [.maskCommand, .maskShift])
        case .screenshotSelection:
            pressHotkey(keyCode: 0x15, modifiers: [.maskCommand, .maskShift])
        case .spaceLeft:
            pressHotkey(keyCode: 0x7B, modifiers: .maskControl)
        case .spaceRight:
            pressHotkey(keyCode: 0x7C, modifiers: .maskControl)
        case .centerPointer:
            pointerInjector.centerOnCurrentDisplay()
        case .wakeDisplay:
            wakeDisplay()
        }
    }

    public func pressHotkey(keyCode: UInt16, modifiers: CGEventFlags = []) {
        guard ensureAccessibility() else { return }

        let modifierKeys: [(CGEventFlags, UInt16)] = [
            (.maskCommand, 0x37),
            (.maskShift, 0x38),
            (.maskAlternate, 0x3A),
            (.maskControl, 0x3B),
            (.maskSecondaryFn, 0x3F),
        ]
        let active = modifierKeys.filter { modifiers.contains($0.0) }

        for (_, code) in active {
            if let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: true) {
                event.flags = modifiers
                event.post(tap: .cghidEventTap)
                event.post(tap: .cgSessionEventTap)
            }
        }

        if let down = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true) {
            down.flags = modifiers
            down.post(tap: .cghidEventTap)
            down.post(tap: .cgSessionEventTap)
        }
        if let up = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false) {
            up.flags = modifiers
            up.post(tap: .cghidEventTap)
            up.post(tap: .cgSessionEventTap)
        }

        for (_, code) in active.reversed() {
            if let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: false) {
                event.flags = modifiers
                event.post(tap: .cghidEventTap)
                event.post(tap: .cgSessionEventTap)
            }
        }
    }

    public func keyDown(keyCode: UInt16, modifiers: CGEventFlags = []) {
        guard ensureAccessibility() else { return }
        if let event = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true) {
            event.flags = modifiers
            event.post(tap: .cghidEventTap)
            event.post(tap: .cgSessionEventTap)
        }
    }

    public func keyUp(keyCode: UInt16, modifiers: CGEventFlags = []) {
        guard ensureAccessibility() else { return }
        if let event = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false) {
            event.flags = modifiers
            event.post(tap: .cghidEventTap)
            event.post(tap: .cgSessionEventTap)
        }
    }

    public func typeText(_ text: String) {
        guard ensureAccessibility() else { return }
        for char in text.unicodeScalars {
            var utf16 = Array(String(char).utf16)
            if let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                down.post(tap: .cghidEventTap)
                down.post(tap: .cgSessionEventTap)
            }
            if let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                up.post(tap: .cghidEventTap)
                up.post(tap: .cgSessionEventTap)
            }
        }
    }

    public func sendMediaKey(_ key: MediaKeyMessage.MediaKey) {
        inputLog.info("media key \(String(describing: key), privacy: .public)")
        switch key {
        case .playPause:
            sendTransport(remote: MediaRemoteCommand.togglePlayPause, hid: NXKey.play, script: "playpause")
        case .nextTrack:
            sendTransport(remote: MediaRemoteCommand.nextTrack, hid: NXKey.next, script: "next track")
        case .previousTrack:
            sendTransport(remote: MediaRemoteCommand.previousTrack, hid: NXKey.previous, script: "previous track")
        case .volumeUp:
            if !postHIDSystemKey(NXKey.soundUp) {
                adjustVolume(by: 1.0 / 16.0)
            }
        case .volumeDown:
            if !postHIDSystemKey(NXKey.soundDown) {
                adjustVolume(by: -1.0 / 16.0)
            }
        case .mute:
            if !postHIDSystemKey(NXKey.mute) {
                toggleMute()
            }
        case .brightnessUp:
            if !postHIDSystemKey(NXKey.brightnessUp) {
                adjustBrightness(by: 1.0 / 16.0)
            }
        case .brightnessDown:
            if !postHIDSystemKey(NXKey.brightnessDown) {
                adjustBrightness(by: -1.0 / 16.0)
            }
        }
    }

    /// One command only. MediaRemote and HID both reach Safari/Chrome Media Session,
    /// so firing both pauses Netflix and immediately plays it again.
    private func sendTransport(remote: UInt32, hid: Int, script: String) {
        if mediaRemoteCommand(remote) { return }
        if postHIDSystemKey(hid) { return }
        appleScriptTransport(script)
    }

    /// Hardware-key equivalent (NX aux). Shows the system volume/brightness HUD.
    @discardableResult
    private func postHIDSystemKey(_ key: Int) -> Bool {
        _ = ensureAccessibility()
        func post(down: Bool) -> Bool {
            let flag = down ? 0x0A00 : 0x0B00
            guard let nsEvent = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.RawValue(flag)),
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: (key << 16) | flag,
                data2: -1
            ), let event = nsEvent.cgEvent else {
                inputLog.error("media HID event create failed key=\(key)")
                return false
            }
            event.post(tap: .cghidEventTap)
            return true
        }
        return post(down: true) && post(down: false)
    }

    // MARK: - Helpers

    private var functionKeysAreStandard: Bool {
        UserDefaults.standard.bool(forKey: "com.apple.keyboard.fnState")
    }

    private func openApp(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return false }
        return NSWorkspace.shared.open(url)
    }

    private func lockScreen() {
        typealias LockFn = @convention(c) () -> Void
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            unsafeBitCast(symbol, to: LockFn.self)()
            return
        }
        pressHotkey(keyCode: 0x0C, modifiers: [.maskCommand, .maskControl])
    }

    private func wakeDisplay() {
        typealias IOPMAssertionDeclareUserActivity = @convention(c) (
            CFString, UInt32, UnsafeMutablePointer<UInt32>
        ) -> Int32
        if let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
           let symbol = dlsym(handle, "IOPMAssertionDeclareUserActivity") {
            let fn = unsafeBitCast(symbol, to: IOPMAssertionDeclareUserActivity.self)
            var assertionID: UInt32 = 0
            let reason = "LightStar remote wake" as CFString
            let result = fn(reason, 0, &assertionID)
            if result == 0 {
                inputLog.info("wakeDisplay: IOPMAssertionDeclareUserActivity succeeded")
                return
            }
            inputLog.error("wakeDisplay: IOPMAssertionDeclareUserActivity failed with \(result)")
        }
        if let event = CGEvent(source: nil) {
            event.type = .mouseMoved
            event.post(tap: .cghidEventTap)
            inputLog.info("wakeDisplay: posted synthetic mouse event")
        }
    }

    private func appleScriptTransport(_ action: String) {
        let apps = NSWorkspace.shared.runningApplications
        if apps.contains(where: { $0.bundleIdentifier == "com.spotify.client" }) {
            _ = runAppleScript("tell application \"Spotify\" to \(action)")
        }
        if apps.contains(where: { $0.bundleIdentifier == "com.apple.Music" }) {
            _ = runAppleScript("tell application \"Music\" to \(action)")
        }
    }

    private func mediaRemoteCommand(_ command: UInt32) -> Bool {
        typealias Send = @convention(c) (UInt32, CFDictionary?) -> DarwinBoolean
        guard let send: Send = loadPrivateSymbol(
            "MRMediaRemoteSendCommand",
            from: "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        ) else {
            inputLog.error("MediaRemote MRMediaRemoteSendCommand unavailable")
            return false
        }
        let ok = send(command, nil).boolValue
        inputLog.info("MediaRemote command \(command) ok=\(ok)")
        return ok
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        )
        return status == noErr ? device : nil
    }

    private func adjustVolume(by delta: Float32) {
        // CoreAudio virtual-master often returns noErr without changing the
        // user-facing output (HDMI, aggregate, spatial). Standard Additions
        // writes the same slider the menu-bar volume HUD uses.
        let step = Int((delta * 100).rounded())
        let script =
            """
            set current to output volume of (get volume settings)
            set nextVolume to current + \(step)
            if nextVolume > 100 then set nextVolume to 100
            if nextVolume < 0 then set nextVolume to 0
            set volume output volume nextVolume
            """
        if runAppleScript(script) { return }
        if let device = defaultOutputDevice() {
            var volume: Float32 = 0
            if getVolume(device, &volume) {
                _ = setVolume(device, min(1, max(0, volume + delta)))
            }
        }
    }

    private func toggleMute() {
        let script =
            """
            if output muted of (get volume settings) then
                set volume without output muted
            else
                set volume with output muted
            end if
            """
        if runAppleScript(script) { return }
        if let device = defaultOutputDevice() {
            var mute: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var didRead = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &mute) == noErr
            if !didRead {
                address.mElement = 1
                didRead = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &mute) == noErr
            }
            if didRead {
                mute = mute == 0 ? 1 : 0
                if AudioObjectSetPropertyData(device, &address, 0, nil, size, &mute) == noErr {
                    return
                }
                address.mElement = 1
                _ = AudioObjectSetPropertyData(device, &address, 0, nil, size, &mute)
                address.mElement = 2
                _ = AudioObjectSetPropertyData(device, &address, 0, nil, size, &mute)
            }
        }
    }

    @discardableResult
    private func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        guard NSAppleScript(source: source)?.executeAndReturnError(&error) != nil, error == nil else {
            inputLog.error("AppleScript failed: \(String(describing: error), privacy: .public)")
            return false
        }
        return true
    }

    private func getVolume(_ device: AudioDeviceID, _ volume: inout Float32) -> Bool {
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kVirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr {
            return true
        }
        address.mSelector = kAudioDevicePropertyVolumeScalar
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr {
            return true
        }
        address.mElement = 1
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr
    }

    private func setVolume(_ device: AudioDeviceID, _ volume: Float32) -> Bool {
        var value = volume
        var address = AudioObjectPropertyAddress(
            mSelector: kVirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr {
            return true
        }
        address.mSelector = kAudioDevicePropertyVolumeScalar
        if AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr {
            return true
        }
        var ok = false
        for element: UInt32 in [1, 2] {
            address.mElement = element
            if AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr {
                ok = true
            }
        }
        return ok
    }

    private func adjustBrightness(by delta: Float) {
        let display = CGMainDisplayID()
        var current: Float = 0
        typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let get: GetFn = loadPrivateSymbol("DisplayServicesGetBrightness", from: path),
              let set: SetFn = loadPrivateSymbol("DisplayServicesSetBrightness", from: path) else {
            inputLog.error("brightness: DisplayServices unavailable")
            return
        }
        guard get(display, &current) == 0 else {
            inputLog.error("brightness: get failed")
            return
        }
        _ = set(display, min(1, max(0, current + delta)))
    }

    private func loadPrivateSymbol<T>(_ name: String, from path: String) -> T? {
        if let handle = dlopen(path, RTLD_LAZY), let symbol = dlsym(handle, name) {
            return unsafeBitCast(symbol, to: T.self)
        }
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, URL(fileURLWithPath: path) as CFURL),
              let pointer = CFBundleGetFunctionPointerForName(bundle, name as CFString) else {
            return nil
        }
        return unsafeBitCast(pointer, to: T.self)
    }
}

private enum MediaRemoteCommand {
    static let togglePlayPause: UInt32 = 2
    static let nextTrack: UInt32 = 4
    static let previousTrack: UInt32 = 5
}

private enum NXKey {
    static let soundUp = 0
    static let soundDown = 1
    static let brightnessUp = 2
    static let brightnessDown = 3
    static let mute = 7
    static let play = 16
    static let next = 17
    static let previous = 18
}

private nonisolated func requestAccessibilityPermissionPrompt() {
    let promptKey = "AXTrustedCheckOptionPrompt" as CFString
    let options = [promptKey: true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
}

private let kVirtualMainVolume = AudioObjectPropertySelector(0x766D7663) // 'vmvc'

public enum KeyCode: UInt16 {
    case returnKey = 0x24
    case tab = 0x30
    case space = 0x31
    case delete = 0x33
    case escape = 0x35
    case command = 0x37
    case shift = 0x38
    case capsLock = 0x39
    case option = 0x3A
    case control = 0x3B
    case rightShift = 0x3C
    case rightOption = 0x3D
    case rightControl = 0x3E
    case function = 0x3F
    case f1 = 0x7A
    case f2 = 0x78
    case f3 = 0x63
    case f4 = 0x76
    case f5 = 0x60
    case f6 = 0x61
    case f7 = 0x62
    case f8 = 0x64
    case f9 = 0x65
    case f10 = 0x6D
    case f11 = 0x67
    case f12 = 0x6F
    case home = 0x73
    case pageUp = 0x74
    case forwardDelete = 0x75
    case end = 0x77
    case pageDown = 0x79
    case leftArrow = 0x7B
    case rightArrow = 0x7C
    case downArrow = 0x7D
    case upArrow = 0x7E
}

#endif
