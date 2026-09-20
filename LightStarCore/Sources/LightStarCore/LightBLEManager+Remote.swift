#if os(macOS)
import SwiftUI
import CoreGraphics
import AppKit

/// Extension for integrating RemoteControlServer with LightBLEManager.
public extension LightBLEManager {
    
    /// Create a LightStarState snapshot for remote clients.
    func createStateSnapshot() -> LightStarState {
        var syncColorInfo: ColorInfo? = nil
        if let sc = syncColor {
            let (sh, ss, sv) = sc.hsvComponents
            syncColorInfo = ColorInfo(hue: sh, saturation: ss, brightness: sv)
        }
        let displays = attachedDisplays()
        
        return LightStarState(
            isConnected: connectionState == .connected,
            isOn: isOn,
            brightness: brightness,
            colorHue: colorHue,
            colorSaturation: colorSat,
            colorTemperature: colorTemperature,
            syncMode: syncMode.rawValue,
            effectID: effectModeActive ? effectID : nil,
            effectSpeed: effectSpeed,
            effectForward: effectForward,
            selectedDisplayID: selectedDisplayID ?? displays.first?.id,
            availableDisplays: displays.map { DisplayInfo(id: $0.id, name: $0.name) },
            syncColor: syncColorInfo,
            protectedContentDetected: screenSampler.protectedContentDetected,
            trackpad: MacTrackpadPreferences.current()
        )
    }

    /// NSScreen list — does not need Screen Recording or the menu-bar popover.
    func attachedDisplays() -> [(id: CGDirectDisplayID, name: String)] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return nil
            }
            return (id, screen.localizedName)
        }
    }

    func refreshAttachedDisplays() {
        let next = attachedDisplays()
        if next.map(\.id) != availableDisplays.map(\.id) {
            availableDisplays = next
        }
        if selectedDisplayID == nil {
            selectedDisplayID = next.first?.id
        }
    }
    
    /// Handle a remote control command and return optional response.
    func handleRemoteCommand(_ message: RemoteMessage) -> RemoteMessage? {
        switch message.type {
        case .setPower:
            if let cmd = try? message.decode(SetPowerMessage.self) {
                setPower(on: cmd.on)
            }
        case .setBrightness:
            if let cmd = try? message.decode(SetBrightnessMessage.self),
               cmd.brightness.isFinite, (0.0...1.0).contains(cmd.brightness) {
                setBrightness(cmd.brightness)
            }
        case .setColor:
            if let cmd = try? message.decode(SetColorMessage.self),
               cmd.hue.isFinite, (0.0...1.0).contains(cmd.hue),
               cmd.saturation.isFinite, (0.0...1.0).contains(cmd.saturation) {
                setHue(cmd.hue, saturation: cmd.saturation)
            }
        case .setColorTemperature:
            if let cmd = try? message.decode(SetColorTemperatureMessage.self),
               cmd.temperature.isFinite, (0.0...1.0).contains(cmd.temperature) {
                setColorTemperature(cmd.temperature)
            }
        case .setEffect:
            if let cmd = try? message.decode(SetEffectMessage.self) {
                setEffect(id: cmd.effectID)
            }
        case .setEffectSpeed:
            if let cmd = try? message.decode(SetEffectSpeedMessage.self),
               cmd.speed.isFinite, (0.0...1.0).contains(cmd.speed) {
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
        case .connectStrip:
            if connectionState != .connected {
                disconnect()
                connect()
            }
        case .disconnectStrip:
            if connectionState != .disconnected {
                disconnect()
            }
        case .writeFrame:
            if let cmd = try? message.decode(WriteFrameMessage.self), cmd.bytes.count <= 512 {
                write(Array(cmd.bytes))
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
    private var shouldObserveState = false
    
    public init(ble: LightBLEManager) {
        self.ble = ble
        self.server = RemoteControlServer()
        self.inputController = MacInputController()
        self.server.pointerInjector = inputController.pointerInjector
        
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
            guard let self else { return }
            let response = self.handleCommand(message)
            respond(response)
        }
        server.onClientsChanged = { [weak self] clients in
            guard let self else { return }
            self.ble?.refreshAttachedDisplays()
            guard !clients.isEmpty else { return }
            self.inputController.ensureAccessibility()
            if let state = self.ble?.createStateSnapshot() {
                self.server.broadcastStateUpdate(state)
            }
        }
    }
    
    private func accessibilityDeniedMessage() -> RemoteMessage? {
        try? RemoteMessage(
            type: .error,
            content: ErrorMessage(
                code: 1,
                message: "On the Mac, enable LightStar in System Settings → Privacy & Security → Accessibility, then quit and reopen LightStar."
            )
        )
    }

    private func handleCommand(_ message: RemoteMessage) -> RemoteMessage? {
        switch message.type {
        case .mouseMove, .mouseDown, .mouseUp, .rightClick, .scroll, .keyDown, .keyUp, .textInput:
            if !inputController.ensureAccessibility() {
                return accessibilityDeniedMessage()
            }
        default:
            break
        }

        switch message.type {
        case .mouseMove:
            if let cmd = try? message.decode(MouseMoveMessage.self) {
                inputController.moveMouse(deltaX: cmd.deltaX, deltaY: cmd.deltaY)
            }
            return nil
        case .mouseDown:
            if let cmd = try? message.decode(MouseButtonMessage.self) {
                inputController.mouseDown(button: cmd.button, clickCount: cmd.clickCount ?? 1)
            }
            return nil
        case .mouseUp:
            if let cmd = try? message.decode(MouseButtonMessage.self) {
                inputController.mouseUp(button: cmd.button, clickCount: cmd.clickCount ?? 1)
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
                inputController.typeText(String(cmd.text.prefix(1024)))
            }
            return nil
        case .mediaKey:
            if let cmd = try? message.decode(MediaKeyMessage.self) {
                inputController.sendMediaKey(cmd.key)
            }
            return nil
        case .macAction:
            if let cmd = try? message.decode(MacActionMessage.self) {
                switch cmd.action {
                case .missionControl, .launchpad, .lockScreen, .wakeDisplay:
                    break
                default:
                    if !inputController.ensureAccessibility() {
                        return accessibilityDeniedMessage()
                    }
                }
                inputController.perform(cmd.action)
            }
            return nil
            
        // Light commands - delegate to BLE manager
        default:
            return ble?.handleRemoteCommand(message)
        }
    }
    
    /// Start the remote control server and begin observing BLE state.
    public func start() {
        ble?.refreshAttachedDisplays()
        server.start()
        shouldObserveState = true
        startStateObservation()
    }
    
    /// Stop the server.
    public func stop() {
        shouldObserveState = false
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
                _ = ble.colorHue
                _ = ble.colorSat
                _ = ble.colorTemperature
                _ = ble.syncMode
                _ = ble.syncColor
                _ = ble.connectionState
                _ = ble.effectModeActive
                _ = ble.effectID
                
                let state = ble.createStateSnapshot()
                self.server.broadcastStateUpdate(state)
            } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self, self.shouldObserveState else { return }
                    self.startStateObservation()
                }
            }
        }
    }
}

#endif
