import SwiftUI

/// Which LightStar surfaces may run while the strip is disconnected or powered off.
///
/// Independent of strip power: Mac↔iPhone remote (trackpad/keyboard), app settings,
/// schedules (they *turn the light on* later).
/// Requires Bluetooth connected: power toggle, schedule editing.
/// Requires connected **and** on: live strip output (color, brightness, presets,
/// sync, effects, animations).
public enum StripCommandPolicy: Sendable {
    public static func canTogglePower(isConnected: Bool) -> Bool {
        isConnected
    }

    public static func canSendStripCommands(isConnected: Bool, isOn: Bool) -> Bool {
        isConnected && isOn
    }

    public static func canEditSchedules(isConnected: Bool) -> Bool {
        isConnected
    }

    public static func canUseMacRemote(macLinked: Bool) -> Bool {
        macLinked
    }
}

/// BC/55 firmware treats hue (0x04) / brightness (0x05) / streaming (0x09)
/// after a power-off frame as a wake-up. While `isOn` is false, only 0x01
/// (power on/off) may enter the coalescer.
public enum StripPowerWritePolicy: Sendable {
    public static func shouldEnqueue(isOn: Bool, commandByte: UInt8) -> Bool {
        isOn || commandByte == 0x01
    }

    public static func isPowerOffFrame(_ bytes: [UInt8]) -> Bool {
        bytes == Cmd.powerOff
    }
}

extension View {
    /// Dim and ignore input for live LED output controls.
    public func stripOutputEnabled(_ enabled: Bool) -> some View {
        self
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.42)
            .saturation(enabled ? 1 : 0.2)
    }
}
