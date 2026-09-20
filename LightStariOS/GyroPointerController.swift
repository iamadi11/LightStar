import Foundation
import CoreMotion
import UIKit
import os
import LightStarCore

private let gyroLog = Logger(subsystem: "com.adityaraj.LightStar", category: "gyro")

@MainActor
final class GyroPointerController: ObservableObject {
    @Published private(set) var isEngaged = false
    @Published private(set) var isAvailable = false

    var onMove: (@Sendable (Double, Double) -> Void)?

    private let pump = MotionPump()

    init() {
        isAvailable = pump.isAvailable
    }

    func engage(sensitivity: Double, accelerationEnabled: Bool = true) {
        guard pump.isAvailable else {
            gyroLog.error("Air pointer engage ignored — device motion unavailable")
            return
        }
        guard let move = onMove else {
            gyroLog.error("Air pointer engage ignored — onMove is nil")
            return
        }
        pump.start(sensitivity: sensitivity, accelerationEnabled: accelerationEnabled, onDelta: move)
        UIApplication.shared.isIdleTimerDisabled = true
        isEngaged = true
        gyroLog.info("Air pointer engaged")
    }

    func disengage() {
        pump.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        isEngaged = false
        gyroLog.info("Air pointer stopped")
    }

    func recenter() {
        pump.recenter()
    }

    func setInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
        let mapped: RemotePointerOrientation
        switch orientation {
        case .landscapeLeft: mapped = .landscapeLeft
        case .landscapeRight: mapped = .landscapeRight
        case .portraitUpsideDown: mapped = .portraitUpsideDown
        default: mapped = .portrait
        }
        pump.setOrientation(mapped)
    }
}

/// All CMMotionManager access stays on `queue`. `start()` must not clear `onDelta`.
private final class MotionPump: @unchecked Sendable {
    private static let sharedProbe = CMMotionManager()
    
    var isAvailable: Bool {
        Self.sharedProbe.isDeviceMotionAvailable || Self.sharedProbe.isGyroAvailable
    }

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.adityaraj.LightStar.gyro"
        queue.qualityOfService = .userInteractive
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var motion: CMMotionManager?
    private var onDelta: (@Sendable (Double, Double) -> Void)?
    private var lastYaw = 0.0
    private var lastPitch = 0.0
    private var lastRoll = 0.0
    private var hasPose = false
    private var lastSampleAt: TimeInterval = 0
    private var sensitivity = 1.0
    private var accelerationEnabled = true
    private var orientation = RemotePointerOrientation.portrait
    private var session = 0

    func start(
        sensitivity: Double,
        accelerationEnabled: Bool,
        onDelta: @escaping @Sendable (Double, Double) -> Void
    ) {
        queue.addOperation { [weak self] in
            guard let self else { return }
            self.session += 1
            let session = self.session
            self.onDelta = onDelta
            self.sensitivity = max(0.15, sensitivity)
            self.accelerationEnabled = accelerationEnabled
            self.hasPose = false
            self.lastSampleAt = 0
            self.stopHardware()
            self.startHardware(session: session)
        }
    }

    func stop() {
        queue.addOperation { [weak self] in
            guard let self else { return }
            self.session += 1
            self.stopHardware()
            self.onDelta = nil
        }
    }

    func recenter() {
        queue.addOperation { [weak self] in
            self?.hasPose = false
        }
    }

    func setOrientation(_ orientation: RemotePointerOrientation) {
        queue.addOperation { [weak self] in
            guard let self else { return }
            if self.orientation != orientation {
                self.orientation = orientation
                self.hasPose = false
            }
        }
    }

    private func manager() -> CMMotionManager {
        if let motion { return motion }
        let created = CMMotionManager()
        motion = created
        return created
    }

    private func startHardware(session: Int) {
        let motion = manager()
        motion.deviceMotionUpdateInterval = 1.0 / 200.0
        motion.gyroUpdateInterval = 1.0 / 200.0
        let handler: CMDeviceMotionHandler = { [weak self] data, _ in
            guard let self, self.session == session, let data else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let dt = self.lastSampleAt == 0 ? 1.0 / 200.0 : max(0.003, now - self.lastSampleAt)
            self.lastSampleAt = now
                self.handleAttitude(
                    yaw: data.attitude.yaw,
                    pitch: data.attitude.pitch,
                    roll: data.attitude.roll,
                    rateX: data.rotationRate.x,
                    rateY: data.rotationRate.y,
                    rateZ: data.rotationRate.z,
                    dt: dt
                )
        }
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        if motion.isDeviceMotionAvailable {
            if frames.contains(.xArbitraryZVertical) {
                motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue, withHandler: handler)
            } else if frames.contains(.xArbitraryCorrectedZVertical) {
                motion.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: queue, withHandler: handler)
            } else {
                motion.startDeviceMotionUpdates(to: queue, withHandler: handler)
            }
        } else if motion.isGyroAvailable {
            motion.startGyroUpdates(to: queue) { [weak self] data, _ in
                guard let self, self.session == session, let data else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let dt = self.lastSampleAt == 0 ? 1.0 / 200.0 : max(0.003, now - self.lastSampleAt)
                self.lastSampleAt = now
                self.handleRates(
                    rateX: data.rotationRate.x,
                    rateY: data.rotationRate.y,
                    rateZ: data.rotationRate.z,
                    dt: dt
                )
            }
        }
        gyroLog.info("Air pointer hardware motion=\(motion.isDeviceMotionAvailable, privacy: .public) gyro=\(motion.isGyroAvailable, privacy: .public)")
    }

    private func stopHardware() {
        motion?.stopDeviceMotionUpdates()
        motion?.stopGyroUpdates()
    }

    private func handleAttitude(
        yaw: Double,
        pitch: Double,
        roll: Double,
        rateX: Double,
        rateY: Double,
        rateZ: Double,
        dt: TimeInterval
    ) {
        if !hasPose {
            lastYaw = yaw
            lastPitch = pitch
            lastRoll = roll
            hasPose = true
            return
        }
        let step = GyroPointerMath.incrementalDelta(
            yaw: yaw,
            pitch: pitch,
            lastYaw: lastYaw,
            lastPitch: lastPitch,
            sensitivity: sensitivity,
            dt: dt,
            accelerationEnabled: accelerationEnabled,
            roll: roll,
            lastRoll: lastRoll,
            orientation: orientation
        )
        lastYaw = step.yaw
        lastPitch = step.pitch
        lastRoll = step.roll
        if abs(step.dx) < 0.2, abs(step.dy) < 0.2 {
            handleRates(rateX: rateX, rateY: rateY, rateZ: rateZ, dt: dt)
            return
        }
        emit(step.dx, step.dy)
    }

    private func handleRates(rateX: Double, rateY: Double, rateZ: Double, dt: TimeInterval) {
        let step = GyroPointerMath.rateDelta(
            rateX: rateX,
            rateY: rateY,
            rateZ: rateZ,
            dt: dt,
            sensitivity: sensitivity,
            accelerationEnabled: accelerationEnabled,
            orientation: orientation
        )
        if abs(step.dx) >= 0.2 || abs(step.dy) >= 0.2 {
            emit(step.dx, step.dy)
        }
    }

    private func emit(_ dx: Double, _ dy: Double) {
        guard let callback = onDelta else { return }
        DispatchQueue.main.async {
            callback(dx, dy)
        }
    }
}
