import SwiftUI

struct ConnectionStatusView: View {
    let connectionState: LightBLEManager.ConnectionState
    let onConnect: (() -> Void)?

    init(connectionState: LightBLEManager.ConnectionState, onConnect: (() -> Void)? = nil) {
        self.connectionState = connectionState
        self.onConnect = onConnect
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(label)
                .foregroundStyle(.secondary)
                .font(.subheadline)
            if connectionState == .disconnected, let onConnect {
                Button("Connect", action: onConnect)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var icon: String {
        switch connectionState {
        case .disconnected: return "wifi.slash"
        case .scanning:     return "antenna.radiowaves.left.and.right"
        case .connecting:   return "arrow.triangle.2.circlepath"
        case .connected:    return "checkmark.circle"
        }
    }

    private var label: String {
        switch connectionState {
        case .disconnected: return "Not connected"
        case .scanning:     return "Scanning…"
        case .connecting:   return "Connecting…"
        case .connected:    return "Connected"
        }
    }
}
