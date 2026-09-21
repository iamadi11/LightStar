#if os(iOS)
import SwiftUI

extension LightBLEManager {
    func configureRemoteTransport() {
        remoteClient.onStateChange = { [weak self] snapshot in
            self?.applyRemoteSnapshot(snapshot)
        }
        remoteClient.onServersChanged = { [weak self] servers in
            self?.handleDiscoveredServers(servers)
        }
        remoteClient.onClientStateChange = { [weak self] state in
            self?.handleRemoteClientState(state)
        }
    }

    func connectViaMac() {
        wantsMacStripConnection = true
        userInitiatedDisconnect = false
        connectionError = nil
        bleNeedsPermission = false

        switch remoteClient.state {
        case .connected:
            connectionState = .connecting
            remoteClient.connectStrip()
            remoteClient.requestState()
        case .discovering, .connecting, .authenticating:
            connectionState = .scanning
        case .disconnected, .error:
            connectionState = .scanning
            remoteClient.startDiscovery()
        }
    }

    func disconnectViaMac() {
        wantsMacStripConnection = false
        userInitiatedDisconnect = true
        stopSyncInline()
        lastSyncMode = .off
        restoreSyncOnReconnect = false
        UserDefaults.standard.set(SyncMode.off.rawValue, forKey: "lastSyncMode")
        coalescer.flush()
        switch remoteClient.state {
        case .connected:
            remoteClient.disconnectStrip()
        default:
            remoteClient.disconnect()
        }
        connectionState = .disconnected
        connectionError = nil
    }

    func handleDiscoveredServers(_ servers: [RemoteControlClient.DiscoveredServer]) {
        guard wantsMacStripConnection else { return }
        guard case .discovering = remoteClient.state, let server = servers.first else { return }
        connectionState = .connecting
        remoteClient.connect(to: server)
    }

    func handleRemoteClientState(_ state: RemoteControlClient.ConnectionState) {
        switch state {
        case .connected:
            guard wantsMacStripConnection else { return }
            connectionState = .connecting
            remoteClient.connectStrip()
            remoteClient.requestState()
        case .error(let message):
            connectionState = .disconnected
            connectionError = message
        case .disconnected:
            if wantsMacStripConnection, connectionState == .connected || connectionState == .connecting {
                connectionState = .disconnected
                connectionError = "Lost connection to Mac"
            }
        default:
            break
        }
    }

    func applyRemoteSnapshot(_ state: LightStarState) {
        if RemoteStripSnapshotPolicy.shouldApplyConnectionFromSnapshot(
            wantsMacStripConnection: wantsMacStripConnection
        ) {
            if state.isConnected {
                if connectionState != .connected {
                    connectionState = .connected
                    connectionError = nil
                }
            } else if case .connected = remoteClient.state {
                connectionState = .connecting
            }
        }

        isOn = state.isOn
        brightness = state.brightness
        colorHue = state.colorHue
        colorSat = state.colorSaturation
        color = Color(hue: state.colorHue, saturation: state.colorSaturation, brightness: 1)
        colorTemperature = state.colorTemperature
        if let mode = SyncMode(rawValue: state.syncMode) {
            syncMode = mode
        }
        effectSpeed = state.effectSpeed
        effectForward = state.effectForward
        if let id = state.effectID {
            effectID = id
            effectModeActive = true
        } else {
            effectModeActive = false
        }
        if let sc = state.syncColor {
            syncColor = Color(hue: sc.hue, saturation: sc.saturation, brightness: sc.brightness)
        } else if syncMode == .off {
            syncColor = nil
        }
    }
}
#endif
