import Foundation
@testable import LightStarCore

/// Mock lighting controller for testing.
/// Records all commands without sending to hardware.
public final class MockLightingController: LightingController, @unchecked Sendable {
    
    // MARK: - Recorded State
    
    public private(set) var isOn: Bool = false
    public private(set) var brightness: Double = 1.0
    public private(set) var hue: Double = 0
    public private(set) var saturation: Double = 0
    public private(set) var colorTemperature: Double = 0.5
    public private(set) var effectID: UInt8 = 0
    public private(set) var effectSpeed: Double = 0.5
    public private(set) var effectForward: Bool = true
    
    // MARK: - Command History
    
    public private(set) var commandHistory: [RecordedLightingCommand] = []
    private let lock = NSLock()
    
    public init() {}
    
    // MARK: - LightingController
    
    public func setPower(on: Bool) {
        lock.lock()
        defer { lock.unlock() }
        isOn = on
        commandHistory.append(RecordedLightingCommand(
            type: .power,
            parameters: ["on": String(on)]
        ))
    }
    
    public func setBrightness(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        brightness = max(0, min(1, value))
        commandHistory.append(RecordedLightingCommand(
            type: .brightness,
            parameters: ["value": String(brightness)]
        ))
    }
    
    public func setColor(hue: Double, saturation: Double) {
        lock.lock()
        defer { lock.unlock() }
        self.hue = max(0, min(1, hue))
        self.saturation = max(0, min(1, saturation))
        commandHistory.append(RecordedLightingCommand(
            type: .color,
            parameters: ["hue": String(self.hue), "saturation": String(self.saturation)]
        ))
    }
    
    public func setColorTemperature(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        colorTemperature = max(0, min(1, value))
        commandHistory.append(RecordedLightingCommand(
            type: .colorTemperature,
            parameters: ["value": String(colorTemperature)]
        ))
    }
    
    public func setEffect(id: UInt8) {
        lock.lock()
        defer { lock.unlock() }
        effectID = id
        commandHistory.append(RecordedLightingCommand(
            type: .effect,
            parameters: ["id": String(id)]
        ))
    }
    
    public func setEffectSpeed(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        effectSpeed = max(0, min(1, value))
        commandHistory.append(RecordedLightingCommand(
            type: .effectSpeed,
            parameters: ["value": String(effectSpeed)]
        ))
    }
    
    public func setEffectDirection(forward: Bool) {
        lock.lock()
        defer { lock.unlock() }
        effectForward = forward
        commandHistory.append(RecordedLightingCommand(
            type: .effectDirection,
            parameters: ["forward": String(forward)]
        ))
    }
    
    // MARK: - Test Helpers
    
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        isOn = false
        brightness = 1.0
        hue = 0
        saturation = 0
        colorTemperature = 0.5
        effectID = 0
        effectSpeed = 0.5
        effectForward = true
        commandHistory.removeAll()
    }
    
    public func lastCommand(ofType type: RecordedLightingCommand.CommandType) -> RecordedLightingCommand? {
        lock.lock()
        defer { lock.unlock() }
        return commandHistory.last { $0.type == type }
    }
    
    public func commandCount(ofType type: RecordedLightingCommand.CommandType) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return commandHistory.filter { $0.type == type }.count
    }
}
