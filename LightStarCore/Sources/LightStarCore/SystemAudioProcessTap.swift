#if os(macOS)
import AVFoundation
import CoreAudio
import Foundation
import os

private let captureLog = Logger(subsystem: "com.adityaraj.LightStar", category: "capture")

/// Mixes every process's output without capturing a display.
@available(macOS 14.2, *)
final class SystemAudioProcessTap: @unchecked Sendable {
    static let deniedError = NSError(
        domain: "SystemAudio",
        code: -5002,
        userInfo: [NSLocalizedDescriptionKey: "System audio recording access required"]
    )

    var onBands: (@Sendable (FrequencyBands) -> Void)?

    private let engine = AudioFFTEngine()
    private let queue = DispatchQueue(label: "audio.system.tap", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private var running = false

    func start() throws {
        guard !running else { return }
        engine.prepare()

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "LightStar system audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.uuid = UUID()

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr else {
            captureLog.error("AudioHardwareCreateProcessTap failed: \(tapStatus, privacy: .public)")
            throw Self.deniedError
        }
        tapID = newTapID

        do {
            format = try tapStreamFormat()
            try createAggregateDevice(tapUUID: description.uuid)
            try installIOProc()
        } catch {
            cleanup()
            throw error
        }
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
        }
        cleanup()
        onBands = nil
    }

    private func tapStreamFormat() throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            captureLog.error("kAudioTapPropertyFormat failed: \(status, privacy: .public)")
            throw Self.deniedError
        }
        return format
    }

    private func createAggregateDevice(tapUUID: UUID) throws {
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LightStar-tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &newAggregateID)
        guard status == noErr else {
            captureLog.error("AudioHardwareCreateAggregateDevice failed: \(status, privacy: .public)")
            throw Self.deniedError
        }
        aggregateID = newAggregateID
    }

    private func installIOProc() throws {
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, inInputData, _, _, _ in
            guard let self, let format = self.format else { return }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: inInputData,
                deallocator: nil
            ) else { return }
            self.engine.ingest(buffer) { bands in
                self.onBands?(bands)
            }
        }
        guard status == noErr, procID != nil else { throw Self.deniedError }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            captureLog.error("AudioDeviceStart failed: \(status, privacy: .public)")
            throw Self.deniedError
        }
    }

    private func cleanup() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        format = nil
        engine.reset()
    }
}
#endif
