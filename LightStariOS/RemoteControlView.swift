import SwiftUI
import LightStarCore

/// Main view for iPhone remote control of Mac LightStar.
struct RemoteControlView: View {
    @StateObject private var client = RemoteControlClient()
    @State private var pairingCode = ""
    @State private var showPairing = false
    
    var body: some View {
        NavigationStack {
            Group {
                switch client.state {
                case .disconnected:
                    disconnectedView
                case .discovering:
                    discoveringView
                case .connecting(let name):
                    connectingView(name)
                case .authenticating:
                    if client.requiresPairing {
                        pairingView
                    } else {
                        authenticatingView
                    }
                case .connected(let name):
                    connectedView(name)
                case .error(let message):
                    errorView(message)
                }
            }
            .navigationTitle("Remote")
        }
        .onAppear {
            if case .disconnected = client.state {
                client.startDiscovery()
            }
        }
    }
    
    // MARK: - State Views
    
    private var disconnectedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            
            Text("Not Connected")
                .font(.title2)
            
            Text("Connect to your Mac running LightStar to use remote control.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button("Search for Mac") {
                client.startDiscovery()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
    
    private var discoveringView: some View {
        VStack(spacing: 20) {
            if client.discoveredServers.isEmpty {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Searching for LightStar on your network...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                List(client.discoveredServers) { server in
                    Button {
                        client.connect(to: server)
                    } label: {
                        HStack {
                            Image(systemName: "desktopcomputer")
                            Text(server.name)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            
            Button("Stop Searching") {
                client.stopDiscovery()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
    
    private func connectingView(_ name: String) -> some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Connecting to \(name)...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Button("Cancel") {
                client.disconnect()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
    
    private var authenticatingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Authenticating...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
    
    private var pairingView: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 60))
                .foregroundStyle(.blue)
            
            Text("Pairing Required")
                .font(.title2)
            
            Text("Enter the code shown on your Mac.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            TextField("Code", text: $pairingCode)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .frame(width: 120)
            
            Button("Pair") {
                client.sendPairingCode(pairingCode)
            }
            .buttonStyle(.borderedProminent)
            .disabled(pairingCode.count != 4)
            
            Button("Cancel") {
                client.disconnect()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
    
    private func connectedView(_ macName: String) -> some View {
        TabView {
            RemoteLightControlView(client: client)
                .tabItem { Label("Lights", systemImage: "lightbulb.fill") }
            
            TrackpadView(client: client)
                .tabItem { Label("Trackpad", systemImage: "hand.draw") }
            
            RemoteKeyboardView(client: client)
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
            
            RemoteSettingsView(client: client, macName: macName)
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundStyle(.red)
            
            Text("Connection Error")
                .font(.title2)
            
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button("Try Again") {
                client.startDiscovery()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

// MARK: - Light Control View

struct RemoteLightControlView: View {
    @ObservedObject var client: RemoteControlClient
    @State private var hue: Double = 0
    @State private var saturation: Double = 1
    @State private var brightness: Double = 1
    @State private var syncedFromState = false
    
    var body: some View {
        NavigationStack {
            List {
                if let state = client.currentState {
                    connectionSection(state)
                    if state.isConnected {
                        powerSection(state)
                        colorSection(state)
                        syncSection(state)
                        displaySection(state)
                    }
                } else {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Loading state...")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Lights")
            .refreshable {
                client.requestState()
            }
        }
        .onChange(of: client.currentState) { _, newState in
            if let state = newState, !syncedFromState {
                hue = state.colorHue
                saturation = state.colorSaturation
                brightness = state.brightness
                syncedFromState = true
            }
        }
    }
    
    @ViewBuilder
    private func connectionSection(_ state: LightStarState) -> some View {
        Section("LED Strip") {
            HStack {
                Image(systemName: state.isConnected ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(state.isConnected ? .green : .red)
                Text(state.isConnected ? "Connected" : "Not Connected")
            }
        }
    }
    
    @ViewBuilder
    private func powerSection(_ state: LightStarState) -> some View {
        Section("Power") {
            Toggle("Light", isOn: Binding(
                get: { state.isOn },
                set: { client.setPower($0) }
            ))
            
            VStack(alignment: .leading) {
                Text("Brightness \(Int(brightness * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $brightness, in: 0...1)
                    .onChange(of: brightness) { _, newValue in
                        client.setBrightness(newValue)
                    }
            }
        }
    }
    
    @ViewBuilder
    private func colorSection(_ state: LightStarState) -> some View {
        Section("Color") {
            VStack(alignment: .leading) {
                Text("Hue")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $hue, in: 0...1)
                    .tint(Color(hue: hue, saturation: 1, brightness: 1))
                    .onChange(of: hue) { _, _ in
                        client.setColor(hue: hue, saturation: saturation)
                    }
            }
            
            VStack(alignment: .leading) {
                Text("Saturation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $saturation, in: 0...1)
                    .onChange(of: saturation) { _, _ in
                        client.setColor(hue: hue, saturation: saturation)
                    }
            }
            
            HStack {
                Circle()
                    .fill(Color(hue: hue, saturation: saturation, brightness: 1))
                    .frame(width: 40, height: 40)
                Text("Current Color")
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    @ViewBuilder
    private func syncSection(_ state: LightStarState) -> some View {
        Section("Sync Mode") {
            ForEach(["Off", "Video", "Audio", "Video+Audio"], id: \.self) { mode in
                Button {
                    client.setSyncMode(mode)
                } label: {
                    HStack {
                        Text(mode)
                        Spacer()
                        if state.syncMode == mode {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            
            if state.protectedContentDetected {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Protected content detected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    @ViewBuilder
    private func displaySection(_ state: LightStarState) -> some View {
        if !state.availableDisplays.isEmpty {
            Section("Display") {
                ForEach(state.availableDisplays) { display in
                    Button {
                        client.selectDisplay(display.id)
                    } label: {
                        HStack {
                            Text(display.name)
                            Spacer()
                            if state.selectedDisplayID == display.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
    }
}

// MARK: - Settings View

struct RemoteSettingsView: View {
    @ObservedObject var client: RemoteControlClient
    let macName: String
    
    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    LabeledContent("Connected to", value: macName)
                    
                    Button("Disconnect", role: .destructive) {
                        client.disconnect()
                    }
                }
                
                Section("About") {
                    LabeledContent("Protocol Version", value: "\(kLightStarProtocolVersion)")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    RemoteControlView()
}
