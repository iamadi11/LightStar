#if os(macOS)
import Foundation
import CoreGraphics
@testable import LightStarCore

/// Mock input controller for testing remote input commands.
/// Records all input events without actually injecting them.
public final class MockInputController: RemoteInputController, @unchecked Sendable {
    
    // MARK: - Recorded Events
    
    public private(set) var eventHistory: [RecordedInputEvent] = []
    private let lock = NSLock()
    
    // MARK: - Current State (for verification)
    
    public private(set) var currentMouseX: Double = 0
    public private(set) var currentMouseY: Double = 0
    public private(set) var isLeftMouseDown: Bool = false
    public private(set) var isRightMouseDown: Bool = false
    public private(set) var pressedKeys: Set<UInt16> = []
    public private(set) var typedText: String = ""
    
    public init() {}
    
    // MARK: - RemoteInputController
    
    public func moveMouse(deltaX: Double, deltaY: Double) {
        lock.lock()
        defer { lock.unlock() }
        
        currentMouseX += deltaX
        currentMouseY += deltaY
        
        eventHistory.append(RecordedInputEvent(
            type: .mouseMove,
            parameters: [
                "deltaX": String(deltaX),
                "deltaY": String(deltaY),
                "newX": String(currentMouseX),
                "newY": String(currentMouseY)
            ]
        ))
    }
    
    public func mouseDown(button: Int) {
        lock.lock()
        defer { lock.unlock() }
        
        if button == 0 {
            isLeftMouseDown = true
        } else if button == 1 {
            isRightMouseDown = true
        }
        
        eventHistory.append(RecordedInputEvent(
            type: .mouseDown,
            parameters: ["button": String(button)]
        ))
    }
    
    public func mouseUp(button: Int) {
        lock.lock()
        defer { lock.unlock() }
        
        if button == 0 {
            isLeftMouseDown = false
        } else if button == 1 {
            isRightMouseDown = false
        }
        
        eventHistory.append(RecordedInputEvent(
            type: .mouseUp,
            parameters: ["button": String(button)]
        ))
    }
    
    public func rightClick() {
        lock.lock()
        defer { lock.unlock() }
        
        eventHistory.append(RecordedInputEvent(type: .rightClick))
    }
    
    public func scroll(deltaX: Double, deltaY: Double) {
        lock.lock()
        defer { lock.unlock() }
        
        eventHistory.append(RecordedInputEvent(
            type: .scroll,
            parameters: [
                "deltaX": String(deltaX),
                "deltaY": String(deltaY)
            ]
        ))
    }
    
    public func keyDown(keyCode: UInt16, modifiers: CGEventFlags) {
        lock.lock()
        defer { lock.unlock() }
        
        pressedKeys.insert(keyCode)
        
        eventHistory.append(RecordedInputEvent(
            type: .keyDown,
            parameters: [
                "keyCode": String(keyCode),
                "modifiers": String(modifiers.rawValue)
            ]
        ))
    }
    
    public func keyUp(keyCode: UInt16, modifiers: CGEventFlags) {
        lock.lock()
        defer { lock.unlock() }
        
        pressedKeys.remove(keyCode)
        
        eventHistory.append(RecordedInputEvent(
            type: .keyUp,
            parameters: [
                "keyCode": String(keyCode),
                "modifiers": String(modifiers.rawValue)
            ]
        ))
    }
    
    public func typeText(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        
        typedText += text
        
        eventHistory.append(RecordedInputEvent(
            type: .textInput,
            parameters: ["text": text]
        ))
    }
    
    // MARK: - Test Helpers
    
    /// Reset all state.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        
        eventHistory.removeAll()
        currentMouseX = 0
        currentMouseY = 0
        isLeftMouseDown = false
        isRightMouseDown = false
        pressedKeys.removeAll()
        typedText = ""
    }
    
    /// Get events of a specific type.
    public func events(ofType type: RecordedInputEvent.EventType) -> [RecordedInputEvent] {
        lock.lock()
        defer { lock.unlock() }
        return eventHistory.filter { $0.type == type }
    }
    
    /// Get the last event.
    public var lastEvent: RecordedInputEvent? {
        lock.lock()
        defer { lock.unlock() }
        return eventHistory.last
    }
    
    /// Get total event count.
    public var eventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return eventHistory.count
    }
}

#endif
