#if os(macOS)
import ApplicationServices
import CoreGraphics
import Foundation

/// HID pointer injection that is safe to call from the Network.framework queue.
/// Keeps cursor state off the MainActor so trackpad / Air pointer frames are not
/// queued behind SwiftUI.
public final class MacPointerInjector: @unchecked Sendable {
    public var mouseSensitivity = 1.0
    public var scrollSensitivity = 1.0

    private let lock = NSLock()
    private let cacheLock = NSLock()
    private let eventSource = CGEventSource(stateID: .hidSystemState)!
    private var location: CGPoint
    private var posted = CGPoint.zero
    private var leftDown = false
    private var haveCursor = false
    private var lastInjectedAt: CFTimeInterval = 0
    private var fracX = 0.0
    private var fracY = 0.0
    private var scrollFracX = 0.0
    private var scrollFracY = 0.0
    private var lastPrefsRead: CFTimeInterval = -100
    private var cachedNaturalScrolling = true
    private var cachedTrusted = false
    private var lastTrustRead: CFTimeInterval = -100

    public init() {
        eventSource.localEventsSuppressionInterval = 0
        location = Self.systemCursor()
        posted = location
        haveCursor = true
        lastInjectedAt = ProcessInfo.processInfo.systemUptime
    }

    /// Injects pointer messages. Returns false when the caller should fall back
    /// to the MainActor path (not a pointer command, or Accessibility is off).
    public func handle(_ message: RemoteMessage) -> Bool {
        switch message.type {
        case .mouseMove, .mouseDown, .mouseUp, .rightClick, .scroll:
            break
        default:
            return false
        }
        guard isTrusted() else { return false }

        switch message.type {
        case .mouseMove:
            if let cmd = try? message.decode(MouseMoveMessage.self) {
                move(deltaX: cmd.deltaX, deltaY: cmd.deltaY)
            }
        case .mouseDown:
            if let cmd = try? message.decode(MouseButtonMessage.self) {
                mouseDown(button: cmd.button, clickCount: cmd.clickCount ?? 1)
            }
        case .mouseUp:
            if let cmd = try? message.decode(MouseButtonMessage.self) {
                mouseUp(button: cmd.button, clickCount: cmd.clickCount ?? 1)
            }
        case .rightClick:
            mouseDown(button: 1, clickCount: 1)
            mouseUp(button: 1, clickCount: 1)
        case .scroll:
            if let cmd = try? message.decode(ScrollMessage.self) {
                scroll(deltaX: cmd.deltaX, deltaY: cmd.deltaY)
            }
        default:
            return false
        }
        return true
    }

    public func applyPointer(deltaX: Double, deltaY: Double, isScroll: Bool) -> Bool {
        guard isTrusted() else { return false }
        if isScroll {
            scroll(deltaX: deltaX, deltaY: deltaY)
        } else {
            move(deltaX: deltaX, deltaY: deltaY)
        }
        return true
    }

    public func move(deltaX: Double, deltaY: Double) {
        lock.lock()
        defer { lock.unlock() }
        let dx = deltaX * mouseSensitivity
        let dy = deltaY * mouseSensitivity
        refreshCursorIfNeededLocked()
        location.x += CGFloat(dx)
        location.y += CGFloat(dy)
        location = Self.clampToDisplays(location)
        let stepX = RemotePixelQueue.takeInteger(from: &fracX, adding: dx)
        let stepY = RemotePixelQueue.takeInteger(from: &fracY, adding: dy)
        guard stepX != 0 || stepY != 0 else { return }
        posted = CGPoint(x: posted.x + CGFloat(stepX), y: posted.y + CGFloat(stepY))
        posted = Self.clampToDisplays(posted)
        let type: CGEventType = leftDown ? .leftMouseDragged : .mouseMoved
        postLocked(type: type, button: .left, deltaX: Double(stepX), deltaY: Double(stepY), clickState: 1)
    }

    public func setPosition(x: Double, y: Double) {
        lock.lock()
        defer { lock.unlock() }
        location = Self.clampToDisplays(CGPoint(x: x, y: y))
        posted = location
        fracX = 0
        fracY = 0
        haveCursor = true
        lastInjectedAt = ProcessInfo.processInfo.systemUptime
        postLocked(type: .mouseMoved, button: .left, deltaX: 0, deltaY: 0, clickState: 1)
        CGWarpMouseCursorPosition(posted)
    }

    public func centerOnCurrentDisplay() {
        lock.lock()
        defer { lock.unlock() }
        refreshCursorIfNeededLocked()
        let displays = Self.activeDisplayBounds()
        guard let bounds = RemoteDisplayGeometry.bounds(containing: location, among: displays) else { return }
        location = RemoteDisplayGeometry.center(of: bounds)
        posted = location
        fracX = 0
        fracY = 0
        haveCursor = true
        lastInjectedAt = ProcessInfo.processInfo.systemUptime
        postLocked(type: .mouseMoved, button: .left, deltaX: 0, deltaY: 0, clickState: 1)
        CGWarpMouseCursorPosition(posted)
    }

    public func mouseDown(button: Int, clickCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        refreshCursorIfNeededLocked()
        if button == 0 { leftDown = true }
        let type: CGEventType = button == 0 ? .leftMouseDown : .rightMouseDown
        let mouseButton: CGMouseButton = button == 0 ? .left : .right
        postLocked(type: type, button: mouseButton, clickState: Int64(max(1, clickCount)))
    }

    public func mouseUp(button: Int, clickCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        refreshCursorIfNeededLocked()
        if button == 0 { leftDown = false }
        let type: CGEventType = button == 0 ? .leftMouseUp : .rightMouseUp
        let mouseButton: CGMouseButton = button == 0 ? .left : .right
        postLocked(type: type, button: mouseButton, clickState: Int64(max(1, clickCount)))
    }

    public func beginDrag() {
        mouseDown(button: 0, clickCount: 1)
    }

    public func endDrag() {
        mouseUp(button: 0, clickCount: 1)
    }

    public func drag(deltaX: Double, deltaY: Double) {
        lock.lock()
        leftDown = true
        lock.unlock()
        move(deltaX: deltaX, deltaY: deltaY)
    }

    public func scroll(deltaX: Double, deltaY: Double) {
        lock.lock()
        let mapped = RemoteScrollMapping.eventDeltas(
            fingerDeltaX: deltaX * scrollSensitivity,
            fingerDeltaY: deltaY * scrollSensitivity,
            naturalScrolling: naturalScrolling()
        )
        let stepY = RemotePixelQueue.takeInteger(from: &scrollFracY, adding: mapped.y)
        let stepX = RemotePixelQueue.takeInteger(from: &scrollFracX, adding: mapped.x)
        lock.unlock()
        guard stepY != 0 || stepX != 0 else { return }
        guard let event = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(stepY),
            wheel2: Int32(stepX),
            wheel3: 0
        ) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
    }

    public func doubleClick() {
        lock.lock()
        defer { lock.unlock() }
        location = Self.systemCursor()
        posted = location
        haveCursor = true
        lastInjectedAt = ProcessInfo.processInfo.systemUptime
        postLocked(type: .leftMouseDown, button: .left, clickState: 2)
        postLocked(type: .leftMouseUp, button: .left, clickState: 2)
    }

    private func isTrusted() -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        let ttl: CFTimeInterval = cachedTrusted ? 2.0 : 0.05
        if now - lastTrustRead > ttl {
            cachedTrusted = AXIsProcessTrusted()
            lastTrustRead = now
        }
        return cachedTrusted
    }

    private func naturalScrolling() -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPrefsRead > 2 {
            cachedNaturalScrolling = MacTrackpadPreferences.current().naturalScrolling
            lastPrefsRead = now
        }
        return cachedNaturalScrolling
    }

    private func refreshCursorIfNeededLocked() {
        let now = ProcessInfo.processInfo.systemUptime
        if !haveCursor || now - lastInjectedAt > 0.8 {
            location = Self.systemCursor()
            posted = location
            fracX = 0
            fracY = 0
            haveCursor = true
        }
        lastInjectedAt = now
    }

    private func postLocked(
        type: CGEventType,
        button: CGMouseButton,
        deltaX: Double = 0,
        deltaY: Double = 0,
        clickState: Int64
    ) {
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: type,
            mouseCursorPosition: posted,
            mouseButton: button
        ) else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(deltaX.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(deltaY.rounded()))
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.post(tap: .cghidEventTap)
    }

    private static func systemCursor() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private static func clampToDisplays(_ point: CGPoint) -> CGPoint {
        let displays = activeDisplayBounds()
        guard !displays.isEmpty else { return point }
        let union = displays.reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull else { return point }
        return CGPoint(
            x: min(max(point.x, union.minX), union.maxX - 1),
            y: min(max(point.y, union.minY), union.maxY - 1)
        )
    }

    private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &displays, &count) == .success, count > 0 else {
            return []
        }
        return (0..<Int(count)).map { CGDisplayBounds(displays[$0]) }
    }
}
#endif
