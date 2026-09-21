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

/// How `buildSync` reacts when a sampler `start()` throws.
/// A newer `setSyncMode` cancels the transition and owns `syncMode`. Display-sleep
/// `pauseScreenSync` does not — combined must still start audio, and video must stay on.
public enum CaptureStartDisposition: Equatable, Sendable {
    case continueWithoutSampler
    case abortQuietTeardown
    case surfaceFailure
}

/// Concurrent `stop()` during `start()` fails the start (`CancellationError`).
/// That is not a permission error, and it is not a reason to kill a paused session.
public enum CaptureSessionPolicy: Sendable {
    public static func isSuperseded<G: Equatable>(startGeneration: G, currentGeneration: G) -> Bool {
        startGeneration != currentGeneration
    }

    public static func shouldSurfaceStartError(_ error: Error) -> Bool {
        !(error is CancellationError)
    }

    /// Sleep/wake `resumeScreenSync` must not `stopSyncInline()` on a superseded start.
    public static func shouldStopSyncAfterResumeError(_ error: Error) -> Bool {
        shouldSurfaceStartError(error)
    }

    public static func disposition(
        forStartError error: Error,
        transitionCancelled: Bool
    ) -> CaptureStartDisposition {
        if transitionCancelled { return .abortQuietTeardown }
        if error is CancellationError { return .continueWithoutSampler }
        return .surfaceFailure
    }

    /// A superseded start still counts as "this sampler belongs to the mode" so
    /// combined does not degrade to audio-only (which would skip wake resume).
    public static func samplerAvailable(callbackInstalled: Bool, startWasSuperseded: Bool) -> Bool {
        callbackInstalled || startWasSuperseded
    }
}
