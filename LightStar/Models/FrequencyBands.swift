// Moved from BLE/MicSyncManager.swift so the type is accessible
// without importing the BLE layer (used by SystemAudioSampler, LightBLEManager).
struct FrequencyBands: Sendable {
    var bass: Double    // 20–200 Hz  — normalised 0–1 against rolling max
    var mid:  Double    // 200–2000 Hz
    var high: Double    // 2000–8000 Hz
    var rms:  Double    // overall loudness
    var isBeat: Bool    // spectral flux onset (threshold 0.60)
    var flux: Double    // normalised spectral flux 0–1 (raw onset strength)
}
