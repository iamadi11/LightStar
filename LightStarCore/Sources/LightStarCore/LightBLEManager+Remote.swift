#if os(macOS)
import SwiftUI
import CoreGraphics

/// Extension for integrating RemoteControlServer with LightBLEManager.
public extension LightBLEManager {
    
    /// Create a LightStarState snapshot for remote clients.
    func createStateSnapshot() -> LightStarState {
        let (h, s, _) = color.hsvComponents
        var syncColorInfo: ColorInfo? = nil
        if let sc = syncColor {
            let (sh, ss, sv) = sc.hsvComponents
            syncColorInfo = ColorInfo(hue: sh, saturation: ss, brightness: sv)
        }
        
        return LightStarState(
            isConnected: connectionState == .connected,
            isOn: isOn,
            brightness: brightness,
            colorHue: h,
            colorSaturation: s,
            colorTemperature: colorTemperature,
            syncMode: syncMode.rawValue,
            effectID: effectModeActive ? effectID : nil,
            effectSpeed: effectSpeed,
            effectForward: effectForward,
            selectedDisplayID: selectedDisplayID,
            availableDisplays: availableDisplays.map { DisplayInfo(id: $0.id, name: $0.name) },
            syncColor: syncColorInfo,
            protectedContentDetected: screenSampler.protectedContentDetected
        )
    }
    
    /// Handle a remote control command and return optional response.
    func handleRemoteCommand(_ message: RemoteMessage) -> RemoteMessage? {
        switch message.type {
        case .setPower:
            if let cmd = try? message.decode(SetPowerMessage.self) {
                setPower(on: cmd.on)
            }
        case .setBrightness:
            if let cmd = try? message.decode(SetBrightnessMessage.self) {
                setBrightness(cmd.brightness)
            }
        case .setColor:
            if let cmd = try? message.decode(SetColorMessage.self) {
                setHue(cmd.hue, saturation: cmd.saturation)
            }
        case .setColorTemperature:
            if let cmd = try? message.decode(SetColorTemperatureMessage.self) {
                setColorTemperature(cmd.temperature)
            }
        case .setEffect:
            if let cmd = try? message.decode(SetEffectMessage.self) {
                setEffect(id: cmd.effectID)
            }
        case .setEffectSpeed:
            if let cmd = try? message.decode(SetEffectSpeedMessage.self) {
                setEffectSpeed(cmd.speed)
            }
        case .setEffectDirection:
            if let cmd = try? message.decode(SetEffectDirectionMessage.self) {
                setEffectDirection(forward: cmd.forward)
            }
        case .setSyncMode:
            if let cmd = try? message.decode(SetSyncModeMessage.self) {
                if let mode = SyncMode(rawValue: cmd.mode) {
                    setSyncMode(mode)
                }
            }
        case .selectDisplay:
            if let cmd = try? message.decode(SelectDisplayMessage.self) {
                selectedDisplayID = cmd.displayID
            }
        default:
            break
        }
        
        return try? RemoteMessage(type: .stateUpdate, content: createStateSnapshot())
    }
}

/// Coordinator that connects RemoteControlServer, LightBLEManager, and MacInputController.
@MainActor
public final class RemoteControlCoordinator: ObservableObject {
    public let server: RemoteControlServer
    public let inputController: MacInputController
    
    private weak var ble: LightBLEManager?
    private var stateObservationTask: Task<Void, Never>?
    
    public init(ble: LightBLEManager) {
        self.ble = ble
        self.server = RemoteControlServer()
        self.inputController = MacInputController()
        
        setupServer()
    }
    
    private func setupServer() {
        server.getState = { [weak self] in
            self?.ble?.createStateSnapshot() ?? LightStarState(
                isConnected: false, isOn: false, brightness: 0,
                colorHue: 0, colorSaturation: 0, colorTemperature: 0.5, syncMode: "Off"
            )
        }
        
        server.onCommand = { [weak self] message, respond in
            guard let self = self else { return }
            
            Task { @MainActor in
                let response = self.handleCommand(message)
                respond(response)
            }
        }
    }
    
    private func handleCommand(_ message: RemoteMessage) -> RemoteMessage? {
        switch message.type {
        // Input commands
        case .mouseMove:
            if let cmd = try? message.decode(MouseMoveMessage.self) {
                inputController.moveMouse(deltaX: cmd.deltaX, deltaY: cmd.deltaY)
            }
            return nil
        case .mouseDown:
            if let cmd = try? message.decode(MouseButtonMessage.self) {
                inputController.mouseDown(button: cmd.button)
            }
            return nil
        case .mouseUp:
            if let cmd = try? message.decode(MouseButtonMessage.self) {
                inputController.mouseUp(button: cmd.button)
            }
            return nil
        case .rightClick:
            inputController.rightClick()
            return nil
        case .scroll:
            if let cmd = try? message.decode(ScrollMessage.self) {
                inputController.scroll(deltaX: cmd.deltaX, deltaY: cmd.deltaY)
            }
            return nil
        case .keyDown:
            if let cmd = try? message.decode(KeyMessage.self) {
                inputController.keyDown(keyCode: cmd.keyCode, modifiers: CGEventFlags(rawValue: UInt64(cmd.modifiers)))
            }
            return nil
        case .keyUp:
            if let cmd = try? message.decode(KeyMessage.self) {
                inputController.keyUp(keyCode: cmd.keyCode, modifiers: CGEventFlags(rawValue: UInt64(cmd.modifiers)))
            }
            return nil
        case .textInput:
            if let cmd = try? message.decode(TextInputMessage.self) {
                inputController.typeText(cmd.text)
            }
            return nil
        case .mediaKey:
            if let cmd = try? message.decode(MediaKeyMessage.self) {
                inputController.sendMediaKey(cmd.key)
            }
            return nil
            
        // Light commands - delegate to BLE manager
        default:
            return ble?.handleRemoteCommand(message)
        }
    }
    
    /// Start the remote control server and begin observing BLE state.
    public func start() {
        server.start()
        startStateObservation()
    }
    
    /// Stop the server.
    public func stop() {
        stateObservationTask?.cancel()
        server.stop()
    }
    
    private func startStateObservation() {
        stateObservationTask?.cancel()
        stateObservationTask = Task { @MainActor in
            guard let ble = self.ble else { return }
            
            // Observe BLE state changes and broadcast to clients
            withObservationTracking {
                _ = ble.isOn
                _ = ble.brightness
                _ = ble.color
                _ = ble.syncMode
                _ = ble.syncColor
                _ = ble.connectionState
                _ = ble.effectModeActive
                _ = ble.effectID
                
                let state = ble.createStateSnapshot()
                self.server.broadcastStateUpdate(state)
            } onChange: {
                Task { @MainActor in
                    guard !Task.isCancelled else { return }
                    self.startStateObservation()
                }
            }
        }
    }
}

#endif
