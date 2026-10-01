import Foundation

/// Shared mapping for iPhone air-pointer samples. Unit-tested; no CoreMotion types.
public enum GyroPointerMath {
    public static let deadzoneRadians = 1.5 * Double.pi / 180
    public static let maxOffsetRadians = 35.0 * Double.pi / 180
    public static let pixelsPerRadian = 1000.0
    public static let maxPixelsPerSample = 220.0
    public static let parkPitchRadians = 20.0 * Double.pi / 180
    public static let parkRateThreshold = 0.15

    public static func shortestAngle(_ a: Double, _ b: Double) -> Double {
        var delta = a - b
        let turn = Double.pi * 2
        delta = delta.truncatingRemainder(dividingBy: turn)
        if delta > .pi { delta -= turn }
        if delta < -.pi { delta += turn }
        return delta
    }

    /// Laser-pointer: pose offset from the engage/recenter origin → screen offset.
    /// Decreasing yaw (turn right) moves +X; decreasing pitch (aim higher) moves +Y with the live mapping.
    public static func targetOffset(
        yaw: Double,
        pitch: Double,
        originYaw: Double,
        originPitch: Double,
        sensitivity: Double
    ) -> (x: Double, y: Double) {
        var offYaw = shortestAngle(yaw, originYaw)
        var offPitch = shortestAngle(pitch, originPitch)
        offYaw = min(maxOffsetRadians, max(-maxOffsetRadians, offYaw))
        offPitch = min(maxOffsetRadians, max(-maxOffsetRadians, offPitch))
        let magnitude = hypot(offYaw, offPitch)
        if magnitude < deadzoneRadians {
            return (0, 0)
        }
        let shrink = (magnitude - deadzoneRadians) / magnitude
        offYaw *= shrink
        offPitch *= shrink
        let gain = pixelsPerRadian * max(0.15, sensitivity)
        return (-offYaw * gain, -offPitch * gain)
    }

    public static func sampleDelta(
        targetX: Double,
        targetY: Double,
        lastX: Double,
        lastY: Double
    ) -> (dx: Double, dy: Double) {
        let dx = min(maxPixelsPerSample, max(-maxPixelsPerSample, targetX - lastX))
        let dy = min(maxPixelsPerSample, max(-maxPixelsPerSample, targetY - lastY))
        return (dx, dy)
    }

    /// Relative mouse: yaw/pitch *change* since the last sample, any hold pose.
    /// +yaw (turn left in CoreMotion) maps to cursor left after the X flip.
    public static func incrementalDelta(
        yaw: Double,
        pitch: Double,
        lastYaw: Double,
        lastPitch: Double,
        sensitivity: Double,
        dt: Double = 1.0 / 120.0,
        accelerationEnabled: Bool = true,
        roll: Double = 0,
        lastRoll: Double = 0,
        orientation: RemotePointerOrientation = .portrait
    ) -> (dx: Double, dy: Double, yaw: Double, pitch: Double, roll: Double) {
        let dYaw = shortestAngle(yaw, lastYaw)
        let dPitch = shortestAngle(pitch, lastPitch)
        let dRoll = shortestAngle(roll, lastRoll)
        let aimed = orientation.aimingDelta(dYaw: dYaw, dPitch: dPitch, dRoll: dRoll)
        if hypot(aimed.0, aimed.1) < 0.00035 {
            return (0, 0, lastYaw, lastPitch, lastRoll)
        }
        let angularSpeed = hypot(aimed.0, aimed.1) / max(0.004, dt)
        let accel = RemotePointerAcceleration.gyroFactor(
            radiansPerSecond: angularSpeed,
            enabled: accelerationEnabled
        )
        let gain = pixelsPerRadian * max(0.15, sensitivity) * accel
        return (
            clampSample(aimed.0 * gain),
            clampSample(aimed.1 * gain),
            yaw,
            pitch,
            roll
        )
    }

    /// Fallback when attitude is unavailable or gimbal-locked. Device axes:
    /// z ≈ yaw, x ≈ pitch. Roll (y) is ignored so wrist twist does not drift X.
    public static func rateDelta(
        rateX: Double,
        rateY: Double,
        rateZ: Double,
        dt: Double,
        sensitivity: Double,
        accelerationEnabled: Bool = true,
        orientation: RemotePointerOrientation = .portrait
    ) -> (dx: Double, dy: Double) {
        let aimed = orientation.mapRates(rateX: rateX, rateY: rateY, rateZ: rateZ)
        let speed = hypot(aimed.0, aimed.1)
        if speed < parkRateThreshold { return (0, 0) }
        let accel = RemotePointerAcceleration.gyroFactor(
            radiansPerSecond: speed,
            enabled: accelerationEnabled
        )
        let gain = pixelsPerRadian * max(0.15, sensitivity) * max(0.004, dt) * accel
        return (clampSample(aimed.0 * gain), clampSample(aimed.1 * gain))
    }

    public static func isParked(pitch: Double, rotationRate: Double) -> Bool {
        abs(pitch) < parkPitchRadians && rotationRate < parkRateThreshold
    }

    private static func clampSample(_ value: Double) -> Double {
        min(maxPixelsPerSample, max(-maxPixelsPerSample, value))
    }
}

/// Device-frame aiming → Mac pointer. Yaw is world heading in every hold pose, so left/right
/// must stay on X when the phone rotates. Landscape vertical uses roll (the new screen-top axis).
public enum RemotePointerOrientation: Equatable, Sendable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight

    /// Finger travel already lives in the rotated view; this only rotates portrait-space vectors.
    public func mapPointer(dx: Double, dy: Double) -> (Double, Double) {
        switch self {
        case .portrait:
            return (dx, dy)
        case .portraitUpsideDown:
            return (-dx, -dy)
        case .landscapeLeft:
            return (dy, -dx)
        case .landscapeRight:
            return (-dy, dx)
        }
    }

    /// Attitude change in device Euler angles → cursor delta before pixel gain.
    public func aimingDelta(dYaw: Double, dPitch: Double, dRoll: Double) -> (Double, Double) {
        switch self {
        case .portrait:
            return (-dYaw, -dPitch)
        case .portraitUpsideDown:
            return (dYaw, dPitch)
        case .landscapeRight:
            return (-dYaw, -dRoll)
        case .landscapeLeft:
            return (-dYaw, dRoll)
        }
    }

    /// `CMRotationRate` in device axes (X pitch, Y roll, Z yaw).
    public func mapRates(rateX: Double, rateY: Double, rateZ: Double) -> (Double, Double) {
        aimingDelta(dYaw: rateZ, dPitch: rateX, dRoll: rateY)
    }
}

/// Three-finger swipe direction from averaged finger travel in UIKit space.
public enum RemoteTrackpadSwipe: Equatable, Sendable {
    case left, right, up, down

    public var macAction: MacSystemAction {
        switch self {
        case .left: return .spaceRight
        case .right: return .spaceLeft
        case .up: return .missionControl
        case .down: return .applicationWindows
        }
    }

    public static func from(dx: Double, dy: Double, threshold: Double = 70) -> RemoteTrackpadSwipe? {
        let ax = abs(dx)
        let ay = abs(dy)
        guard max(ax, ay) >= threshold else { return nil }
        if ax > ay {
            return dx < 0 ? .left : .right
        }
        return dy < 0 ? .up : .down
    }
}

/// Notched wheel: drag accumulates until it crosses one notch, then that
/// notch is a single scroll tick. Remainder stays so the wheel doesn't jump.
public enum ScrollWheelDetent {
    public static let spacing: Double = 22
    public static let scrollPerNotch: Double = 40

    public static func consume(accumulated: Double, delta: Double, spacing: Double = ScrollWheelDetent.spacing) -> (notches: Int, remainder: Double) {
        guard spacing > 0, delta.isFinite, accumulated.isFinite else {
            return (0, accumulated.isFinite ? accumulated : 0)
        }
        let total = accumulated + delta
        let notches = Int((total / spacing).rounded(.towardZero))
        return (notches, total - Double(notches) * spacing)
    }
}

/// Finger deltas from UIKit (swipe up → negative dy) to CGEvent wheel units.
/// Natural ON matches the physical Mac trackpad: do not invert. Natural OFF inverts once.
public enum RemoteScrollMapping {
    public static func eventDeltas(
        fingerDeltaX: Double,
        fingerDeltaY: Double,
        naturalScrolling: Bool
    ) -> (x: Double, y: Double) {
        if naturalScrolling {
            return (fingerDeltaX, fingerDeltaY)
        }
        return (-fingerDeltaX, -fingerDeltaY)
    }
}

/// Pointer acceleration shared by the remote trackpad and Air pointer.
/// Curve shape follows Apple HID tracking speed (`com.apple.trackpad.scaling` 0...3).
public enum RemotePointerAcceleration {
    /// Cursor pixels per finger point. Slow travel stays near 1:1; flicks go ballistic.
    public static func factor(
        pixelsPerSecond: Double,
        enabled: Bool,
        scaling: Double = 1.0
    ) -> Double {
        let s = min(3.0, max(0.0, scaling))
        let base = 0.40 + s * 0.32
        guard enabled else { return base }
        let v = max(0.0, pixelsPerSecond)
        let extra: Double
        switch v {
        case ..<80:
            extra = 0
        case ..<200:
            extra = (v - 80) / 120 * (0.25 + 0.15 * s)
        case ..<450:
            extra = (0.25 + 0.15 * s) + (v - 200) / 250 * (0.70 + 0.45 * s)
        case ..<900:
            extra = (0.95 + 0.60 * s) + (v - 450) / 450 * (1.20 + 0.80 * s)
        default:
            extra = (2.15 + 1.40 * s) + min(1.0, (v - 900) / 800) * (1.10 + 0.70 * s)
        }
        return base + extra
    }

    /// Wrist angular speed. Slow tilts stay precise; flicks cover a large display.
    public static func gyroFactor(radiansPerSecond: Double, enabled: Bool) -> Double {
        guard enabled else { return 1.0 }
        return factor(pixelsPerSecond: radiansPerSecond * 520, enabled: true, scaling: 2.0)
    }
}

/// Accumulates fractional pixels so slow trackpad travel is not rounded away.
public enum RemotePixelQueue {
    public static func takeInteger(from accumulated: inout Double, adding delta: Double) -> Int64 {
        accumulated += delta
        let step = accumulated.rounded(.towardZero)
        accumulated -= step
        return Int64(step)
    }
}

/// Quartz display geometry used to put the Air pointer back in the middle of the current screen.
public enum RemoteDisplayGeometry {
    public static func bounds(
        containing point: CGPoint,
        among displays: [CGRect]
    ) -> CGRect? {
        if let hit = displays.first(where: { $0.insetBy(dx: -1, dy: -1).contains(point) }) {
            return hit
        }
        return displays.min { a, b in
            hypot(a.midX - point.x, a.midY - point.y) < hypot(b.midX - point.x, b.midY - point.y)
        }
    }

    public static func center(of bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

/// Hidden iPhone TextField → Mac keystrokes. A local buffer reset (hiding the
/// keyboard) must not be turned into deletes; those characters were already sent.
public enum RemoteTypingDelta: Equatable, Sendable {
    case none
    case insert(String)
    case delete(Int)
    case replace(delete: Int, insert: String)

    public static func from(oldValue: String, newValue: String) -> RemoteTypingDelta {
        if newValue == oldValue { return .none }
        if newValue.count > oldValue.count, newValue.hasPrefix(oldValue) {
            return .insert(String(newValue.dropFirst(oldValue.count)))
        }
        if newValue.count < oldValue.count, oldValue.hasPrefix(newValue) {
            return .delete(oldValue.count - newValue.count)
        }
        return .replace(delete: oldValue.count, insert: newValue)
    }

    public static func shouldEmit(forLocalBufferReset: Bool) -> Bool {
        !forLocalBufferReset
    }
}

/// One typed character is a HID key-down that carries Unicode, then a key-up
/// that does not. The session tap is downstream of the HID tap, so posting
/// there as well inserts the character a second time. Unicode on key-up does too.
public enum RemoteTextInjection: Equatable, Sendable {
    case keyDown
    case keyUp

    public static let strokes: [RemoteTextInjection] = [.keyDown, .keyUp]

    public static func carriesCharacter(_ stroke: RemoteTextInjection) -> Bool {
        stroke == .keyDown
    }
}

/// Volume and brightness step the live system level. A local counter that
/// starts at half scale stays wrong until it clamps at empty or full.
public enum SystemLevelStep {
    public static let notch = 1.0 / 16.0

    public static func clamped(_ level: Double) -> Double {
        guard level.isFinite else { return 0 }
        return min(1, max(0, level))
    }

    public static func next(current: Double, delta: Double) -> Double {
        clamped(current + delta)
    }
}

/// Once a click-drag (long-press or three-finger drag) owns the mouse button,
/// extra fingers must not switch the gesture to scroll.
public enum RemoteTrackpadMoveKind: Equatable, Sendable {
    case pointer
    case scroll
    case threeFinger

    public static func kind(fingerCount: Int, isClickDrag: Bool) -> RemoteTrackpadMoveKind {
        if isClickDrag { return .pointer }
        switch fingerCount {
        case 1: return .pointer
        case 2: return .scroll
        default: return .threeFinger
        }
    }
}

/// Disconnect cleanup must release every button that is still down, not only left.
public enum PointerButtonCleanup: Sendable {
    public static func buttonsToRelease(left: Bool, right: Bool, other: Bool) -> [Int] {
        var buttons: [Int] = []
        if left { buttons.append(0) }
        if right { buttons.append(1) }
        if other { buttons.append(2) }
        return buttons
    }
}

/// Launch-at-login toggle must follow SMAppService, not the failed request.
public enum LaunchAtLoginSync: Sendable {
    public static func displayedEnabled(requested: Bool, succeeded: Bool, currentlyEnabled: Bool) -> Bool {
        succeeded ? requested : currentlyEnabled
    }
}
