// Moved from BLE/MicSyncManager.swift so the type is accessible
// without importing the BLE layer (used by SystemAudioSampler, LightBLEManager).
public struct FrequencyBands: Sendable {
    public var bass: Double    // 20–200 Hz  — normalised 0–1 against rolling max
    public var mid:  Double    // 200–2000 Hz
    public var high: Double    // 2000–8000 Hz
    public var rms:  Double    // overall loudness
    public var flux: Double    // normalised spectral flux 0–1; callers apply their own threshold via beatSensitivity

    public init(bass: Double, mid: Double, high: Double, rms: Double, flux: Double) {
        self.bass = bass
        self.mid = mid
        self.high = high
        self.rms = rms
        self.flux = flux
    }
}

/// Concurrent stop() during start() must fail the start so sync UI cannot stay "on".
public enum CaptureSessionPolicy: Sendable {
    public static func isSuperseded(startGeneration: UInt64, currentGeneration: UInt64) -> Bool {
        startGeneration != currentGeneration
    }

    public static func shouldSurfaceStartError(_ error: Error) -> Bool {
        !(error is CancellationError)
    }
}
