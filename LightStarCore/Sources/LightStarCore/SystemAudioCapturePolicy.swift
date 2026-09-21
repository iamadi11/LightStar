import Foundation

/// Music Pulse only needs system audio. A display `SCStream` still puts Chrome
/// in the capture set, so Widevine blacks the Netflix/Prime player the user is
/// watching. macOS 14.2+ can tap process output at the HAL instead.
public enum SystemAudioCapturePolicy: Sendable {
    public static func usesProcessTap(majorVersion: Int, minorVersion: Int) -> Bool {
        majorVersion > 14 || (majorVersion == 14 && minorVersion >= 2)
    }

    public static func usesDisplayStream(majorVersion: Int, minorVersion: Int) -> Bool {
        !usesProcessTap(majorVersion: majorVersion, minorVersion: minorVersion)
    }
}
