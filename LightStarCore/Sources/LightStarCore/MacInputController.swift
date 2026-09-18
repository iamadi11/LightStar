#if os(macOS)
import Foundation
import CoreGraphics
import AppKit

/// Controller for handling remote input from iPhone (trackpad, keyboard, etc).
/// Requires Accessibility permission for CGEvent posting.
@MainActor
public final class MacInputController: ObservableObject {
    
    @Published public private(set) var accessibilityEnabled = false
    @Published public var mouseSensitivity: Double = 1.0
    @Published public var scrollSensitivity: Double = 1.0
    @Published public var naturalScrolling: Bool = true
    
    private var currentMouseLocation: CGPoint = .zero
    
    public init() {
        checkAccessibility()
        updateMouseLocation()
    }
    
    /// Check if Accessibility permission is granted.
    public func checkAccessibility() {
        accessibilityEnabled = AXIsProcessTrusted()
    }
    
    /// Request Accessibility permission (opens System Settings).
    public func requestAccessibility() {
        // Safe because the Accessibility prompt key is effectively a constant
        requestAccessibilityPermissionPrompt()
    }
    
    // MARK: - Mouse Control
    
    /// Move the mouse by a relative delta.
    public func moveMouse(deltaX: Double, deltaY: Double) {
        guard accessibilityEnabled else { return }
        
        let scaledDeltaX = deltaX * mouseSensitivity
        let scaledDeltaY = deltaY * mouseSensitivity
        
        updateMouseLocation()
        let newX = currentMouseLocation.x + CGFloat(scaledDeltaX)
        let newY = currentMouseLocation.y + CGFloat(scaledDeltaY)
        
        // Clamp to screen bounds
        let screens = NSScreen.screens
        var maxX: CGFloat = 0, maxY: CGFloat = 0
        for screen in screens {
            maxX = max(maxX, screen.frame.maxX)
            maxY = max(maxY, screen.frame.maxY)
        }
        
        let clampedX = max(0, min(maxX, newX))
        let clampedY = max(0, min(maxY, newY))
        currentMouseLocation = CGPoint(x: clampedX, y: clampedY)
        
        if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                mouseCursorPosition: currentMouseLocation, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }
    
    /// Move the mouse to an absolute position.
    public func setMousePosition(x: Double, y: Double) {
        guard accessibilityEnabled else { return }
        currentMouseLocation = CGPoint(x: x, y: y)
        
        if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                mouseCursorPosition: currentMouseLocation, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }
    
    /// Perform a left mouse click.
    public func leftClick() {
        guard accessibilityEnabled else { return }
        updateMouseLocation()
        
        if let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                              mouseCursorPosition: currentMouseLocation, mouseButton: .left) {
            down.post(tap: .cghidEventTap)
        }
        
        if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                            mouseCursorPosition: currentMouseLocation, mouseButton: .left) {
            up.post(tap: .cghidEventTap)
        }
    }
    
    /// Perform a right mouse click.
    public func rightClick() {
        guard accessibilityEnabled else { return }
        updateMouseLocation()
        
        if let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown,
                              mouseCursorPosition: currentMouseLocation, mouseButton: .right) {
            down.post(tap: .cghidEventTap)
        }
        
        if let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp,
                            mouseCursorPosition: currentMouseLocation, mouseButton: .right) {
            up.post(tap: .cghidEventTap)
        }
    }
    
    /// Perform a double click.
    public func doubleClick() {
        guard accessibilityEnabled else { return }
        updateMouseLocation()
        
        if let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                              mouseCursorPosition: currentMouseLocation, mouseButton: .left) {
            down.setIntegerValueField(.mouseEventClickState, value: 2)
            down.post(tap: .cghidEventTap)
        }
        
        if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                            mouseCursorPosition: currentMouseLocation, mouseButton: .left) {
            up.setIntegerValueField(.mouseEventClickState, value: 2)
            up.post(tap: .cghidEventTap)
        }
    }
    
    /// Mouse button down.
    public func mouseDown(button: Int = 0) {
        guard accessibilityEnabled else { return }
        updateMouseLocation()
        
        let mouseType: CGEventType = button == 0 ? .leftMouseDown : .rightMouseDown
        let mouseButton: CGMouseButton = button == 0 ? .left : .right
        
        if let event = CGEvent(mouseEventSource: nil, mouseType: mouseType,
                               mouseCursorPosition: currentMouseLocation, mouseButton: mouseButton) {
            event.post(tap: .cghidEventTap)
        }
    }
    
    /// Mouse button up.
    public func mouseUp(button: Int = 0) {
        guard accessibilityEnabled else { return }
        updateMouseLocation()
        
        let mouseType: CGEventType = button == 0 ? .leftMouseUp : .rightMouseUp
        let mouseButton: CGMouseButton = button == 0 ? .left : .right
        
        if let event = CGEvent(mouseEventSource: nil, mouseType: mouseType,
                               mouseCursorPosition: currentMouseLocation, mouseButton: mouseButton) {
            event.post(tap: .cghidEventTap)
        }
    }
    
    /// Start a mouse drag.
    public func startDrag() {
        mouseDown(button: 0)
    }
    
    /// End a mouse drag.
    public func endDrag() {
        mouseUp(button: 0)
    }
    
    /// Drag the mouse (move while button is down).
    public func drag(deltaX: Double, deltaY: Double) {
        guard accessibilityEnabled else { return }
        
        let scaledDeltaX = deltaX * mouseSensitivity
        let scaledDeltaY = deltaY * mouseSensitivity
        
        currentMouseLocation.x += CGFloat(scaledDeltaX)
        currentMouseLocation.y += CGFloat(scaledDeltaY)
        
        if let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                               mouseCursorPosition: currentMouseLocation, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }
    
    // MARK: - Scroll
    
    /// Perform a scroll.
    public func scroll(deltaX: Double, deltaY: Double) {
        guard accessibilityEnabled else { return }
        
        var scaledDeltaX = Int32(deltaX * scrollSensitivity)
        var scaledDeltaY = Int32(deltaY * scrollSensitivity)
        
        if naturalScrolling {
            scaledDeltaX = -scaledDeltaX
            scaledDeltaY = -scaledDeltaY
        }
        
        if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                               wheelCount: 2, wheel1: scaledDeltaY, wheel2: scaledDeltaX, wheel3: 0) {
            event.post(tap: .cghidEventTap)
        }
    }
    
    // MARK: - Keyboard
    
    /// Press and release a key.
    public func pressKey(keyCode: UInt16, modifiers: CGEventFlags = []) {
        guard accessibilityEnabled else { return }
        
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
            down.flags = modifiers
            down.post(tap: .cghidEventTap)
        }
        
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
            up.flags = modifiers
            up.post(tap: .cghidEventTap)
        }
    }
    
    /// Key down event.
    public func keyDown(keyCode: UInt16, modifiers: CGEventFlags = []) {
        guard accessibilityEnabled else { return }
        
        if let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
            event.flags = modifiers
            event.post(tap: .cghidEventTap)
        }
    }
    
    /// Key up event.
    public func keyUp(keyCode: UInt16, modifiers: CGEventFlags = []) {
        guard accessibilityEnabled else { return }
        
        if let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
            event.flags = modifiers
            event.post(tap: .cghidEventTap)
        }
    }
    
    /// Type a string of text.
    public func typeText(_ text: String) {
        guard accessibilityEnabled else { return }
        
        for char in text {
            if let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                var unichar = [UniChar](String(char).utf16)
                event.keyboardSetUnicodeString(stringLength: unichar.count, unicodeString: &unichar)
                event.post(tap: .cghidEventTap)
            }
            
            if let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                up.post(tap: .cghidEventTap)
            }
        }
    }
    
    /// Send a media key press.
    public func sendMediaKey(_ key: MediaKeyMessage.MediaKey) {
        guard accessibilityEnabled else { return }
        
        let keyCode: Int32
        switch key {
        case .playPause: keyCode = NX_KEYTYPE_PLAY
        case .nextTrack: keyCode = NX_KEYTYPE_NEXT
        case .previousTrack: keyCode = NX_KEYTYPE_PREVIOUS
        case .volumeUp: keyCode = NX_KEYTYPE_SOUND_UP
        case .volumeDown: keyCode = NX_KEYTYPE_SOUND_DOWN
        case .mute: keyCode = NX_KEYTYPE_MUTE
        case .brightnessUp: keyCode = NX_KEYTYPE_BRIGHTNESS_UP
        case .brightnessDown: keyCode = NX_KEYTYPE_BRIGHTNESS_DOWN
        }
        
        postMediaKeyEvent(keyCode: keyCode, keyDown: true)
        postMediaKeyEvent(keyCode: keyCode, keyDown: false)
    }
    
    private func postMediaKeyEvent(keyCode: Int32, keyDown: Bool) {
        let flags: Int32 = keyDown ? 0xa00 : 0xb00
        let data1 = Int((keyCode << 16) | (flags << 8))
        
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        )
        
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
    
    // MARK: - Helpers
    
    private func updateMouseLocation() {
        currentMouseLocation = NSEvent.mouseLocation
        // Convert from bottom-left to top-left coordinate system
        if let screen = NSScreen.main {
            currentMouseLocation.y = screen.frame.height - currentMouseLocation.y
        }
    }
}

// MARK: - Accessibility Helper

// Use the string key directly to avoid Swift strict concurrency issues with the global variable.
// The key "AXTrustedCheckOptionPrompt" is the documented value of kAXTrustedCheckOptionPrompt.
private nonisolated func requestAccessibilityPermissionPrompt() {
    let promptKey = "AXTrustedCheckOptionPrompt" as CFString
    let options = [promptKey: true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
}

// MARK: - Media Key Constants

private let NX_KEYTYPE_PLAY: Int32 = 16
private let NX_KEYTYPE_NEXT: Int32 = 17
private let NX_KEYTYPE_PREVIOUS: Int32 = 18
private let NX_KEYTYPE_SOUND_UP: Int32 = 0
private let NX_KEYTYPE_SOUND_DOWN: Int32 = 1
private let NX_KEYTYPE_MUTE: Int32 = 7
private let NX_KEYTYPE_BRIGHTNESS_UP: Int32 = 21
private let NX_KEYTYPE_BRIGHTNESS_DOWN: Int32 = 22

// MARK: - Common Key Codes

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
