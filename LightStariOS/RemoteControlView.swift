import SwiftUI
import LightStarCore

/// Main view for iPhone remote control of Mac LightStar.
struct RemoteControlView: View {
    @ObservedObject var client: RemoteControlClient
    @StateObject private var inputSettings = RemoteInputSettings()
    @State private var pairingCode = ""
    @State private var showPairing = false
    @State private var selectedTab = 0
    
    var body: some View {
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
                    .onChange(of: client.currentState) { _, state in
                        if let prefs = state?.trackpad {
                            inputSettings.applyMacPrefs(prefs)
                        }
                    }
                    .onAppear {
                        if let prefs = client.currentState?.trackpad {
                            inputSettings.applyMacPrefs(prefs)
                        }
                    }
            case .error(let message):
                errorView(message)
            }
        }
        .onChange(of: client.state) { _, newState in
            if RemotePairingFieldPolicy.shouldClearLocalCode(for: newState) {
                pairingCode = ""
            }
        }
        .task {
            switch client.state {
            case .disconnected, .error:
                client.startDiscovery()
            default:
                break
            }
        }
    }
    
    // MARK: - State Views
    
    private var disconnectedView: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
                
                Text("Not Connected")
                    .font(.title2)
                
                Text("Connect to your Mac running LightStar. The laptop’s Bluetooth controls the light strip.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                Button("Search for Mac") {
                    client.startDiscovery()
                }
                .buttonStyle(.borderedProminent)
                
                Text("Make sure LightStar is running on your Mac. If the Mac is asleep or locked, wake it first.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding()
            .navigationTitle("LightStar")
        }
    }
    
    private var discoveringView: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if client.discoveredServers.isEmpty {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Searching for your Mac…")
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
            .navigationTitle("LightStar")
        }
    }
    
    private func connectingView(_ name: String) -> some View {
        NavigationStack {
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
            .navigationTitle("LightStar")
        }
    }
    
    private var authenticatingView: some View {
        NavigationStack {
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Authenticating...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("LightStar")
        }
    }
    
    private var pairingView: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)
                
                Text("Pairing Required")
                    .font(.title2)
                
                Text("Enter the 6-character code shown on your Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                TextField("Code", text: $pairingCode)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.center)
                    .frame(width: 160)
                    .onChange(of: pairingCode) { _, newValue in
                        let filtered = newValue.uppercased().filter { $0.isLetter || $0.isNumber }
                        if filtered != newValue {
                            pairingCode = String(filtered.prefix(kLightStarPairingCodeLength))
                        } else if newValue.count > kLightStarPairingCodeLength {
                            pairingCode = String(newValue.prefix(kLightStarPairingCodeLength))
                        }
                    }
                
                Button("Pair") {
                    client.sendPairingCode(pairingCode)
                }
                .buttonStyle(.borderedProminent)
                .disabled(pairingCode.count != kLightStarPairingCodeLength)
                
                Button("Cancel") {
                    pairingCode = ""
                    client.disconnect()
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .navigationTitle("LightStar")
        }
    }
    
    private func connectedView(_ macName: String) -> some View {
        TabView(selection: $selectedTab) {
            TrackpadView(
                client: client,
                settings: inputSettings,
                macName: macName,
                isActiveTab: selectedTab == 0
            )
            .tabItem { Label("Remote", systemImage: "hand.draw") }
            .tag(0)

            RemoteLightControlView(client: client)
                .tabItem { Label("Lights", systemImage: "lightbulb.fill") }
                .tag(1)
        }
        .safeAreaInset(edge: .top) {
            if let notice = client.notice {
                VStack(alignment: .leading, spacing: 8) {
                    Text(notice)
                        .font(.footnote)
                    Button("Dismiss") { client.notice = nil }
                        .font(.footnote.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.yellow.opacity(0.2))
            }
        }
    }
    
    private func errorView(_ message: String) -> some View {
        NavigationStack {
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
                
                Text("Make sure LightStar is running on your Mac and both devices are on the same Wi-Fi network.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding()
            .navigationTitle("LightStar")
        }
    }
}

// MARK: - Light Control View

struct RemoteLightControlView: View {
    @ObservedObject var client: RemoteControlClient
    @State private var hue: Double = 0
    @State private var saturation: Double = 1
    @State private var brightness: Double = 1
    @State private var lampCode = ""
    
    var body: some View {
        NavigationStack {
            List {
                if let state = client.currentState {
                    lightsSection(state)
                    powerSection(state)
                    let target = RemoteLightControls.target(from: state.outputTarget)
                    let live = RemoteLightControls.canAdjust(
                        target: target,
                        stripConnected: state.isConnected,
                        isOn: state.isOn
                    )
                    if !live {
                        Section {
                            Text(liveHint(state))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Group {
                        brightnessSection
                        colorSection(state)
                        syncSection(state)
                        displaySection(state)
                    }
                    .stripOutputEnabled(live)
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
            .onAppear { client.requestState() }
        }
        .onChange(of: client.currentState) { _, newState in
            guard let state = newState else { return }
            if abs(hue - state.colorHue) > 0.002 { hue = state.colorHue }
            if abs(saturation - state.colorSaturation) > 0.002 { saturation = state.colorSaturation }
            if abs(brightness - state.brightness) > 0.002 { brightness = state.brightness }
        }
    }
    
    @ViewBuilder
    private func lightsSection(_ state: LightStarState) -> some View {
        let target = RemoteLightControls.target(from: state.outputTarget)
        Section {
            Picker("Which lights", selection: Binding(
                get: { target },
                set: { next in
                    RemoteHaptics.select()
                    client.setOutputTarget(next)
                }
            )) {
                ForEach(LightOutputTarget.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            Text("The Mac drives the LED strip, the Mi lamp, or both.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        if target.sendsToStrip {
            Section("LED strip") {
                HStack(spacing: 8) {
                    Image(systemName: "lightstrip.2")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(stripStatus(state))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                }
                .accessibilityElement(children: .combine)
                Button(stripActionTitle(state)) {
                    RemoteHaptics.select()
                    let phase = stripPhase(state)
                    if phase == "scanning" || phase == "connecting" || phase == "connected" {
                        client.disconnectStrip()
                    } else {
                        client.connectStrip()
                    }
                }
            }
        }

        if target.sendsToLamp {
            Section("Mi lamp") {
                HStack(spacing: 8) {
                    Image(systemName: "lamp.desk")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(RemoteLightControls.lampStatus(phase: state.lampPhase, detail: state.lampDetail))
                        .foregroundStyle(state.lampPhase == "failed" ? .red : .secondary)
                }
                .accessibilityElement(children: .combine)
                if state.lampPhase == "needsCode" || state.lampPhase == "failed" {
                    TextField("Code on the lamp base", text: $lampCode)
                        .keyboardType(.numberPad)
                        .monospacedDigit()
                        .textContentType(.oneTimeCode)
                    Button("Connect lamp") {
                        RemoteHaptics.select()
                        client.setLampCode(lampCode)
                    }
                    .disabled(lampCode.filter(\.isNumber).count != 8)
                }
            }
        }
    }

    @ViewBuilder
    private func powerSection(_ state: LightStarState) -> some View {
        let target = RemoteLightControls.target(from: state.outputTarget)
        let enabled = RemoteLightControls.canPower(target: target, stripConnected: state.isConnected)
        Section {
            Toggle(target.title, isOn: Binding(
                get: { state.isOn },
                set: {
                    RemoteHaptics.select()
                    client.setPower($0)
                }
            ))
            .disabled(!enabled)
            Text(RemoteLightControls.powerDetail(target: target))
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Power")
        }
    }

    private func stripPhase(_ state: LightStarState) -> String {
        if let phase = state.stripPhase { return phase }
        return state.isConnected ? "connected" : "disconnected"
    }

    private func stripStatus(_ state: LightStarState) -> String {
        switch stripPhase(state) {
        case "connected": return "Connected"
        case "scanning": return "Looking for the LED strip…"
        case "connecting": return "Connecting to the LED strip…"
        default: return "Not connected"
        }
    }

    private func stripActionTitle(_ state: LightStarState) -> String {
        switch stripPhase(state) {
        case "connected": return "Disconnect"
        case "scanning", "connecting": return "Cancel"
        default: return "Connect"
        }
    }

    private func liveHint(_ state: LightStarState) -> String {
        let target = RemoteLightControls.target(from: state.outputTarget)
        if !RemoteLightControls.canPower(target: target, stripConnected: state.isConnected) {
            return "Connect the LED strip to turn it on."
        }
        return "Turn the lights on to change brightness, color, and sync."
    }

    private var brightnessSection: some View {
        Section("Brightness") {
            VStack(alignment: .leading) {
                Text("Brightness \(Int(brightness * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $brightness, in: 0...1)
                    .onChange(of: brightness) { _, newValue in
                        guard abs(newValue - (client.currentState?.brightness ?? newValue)) > 0.002 else { return }
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
                    .onChange(of: hue) { _, newValue in
                        guard abs(newValue - (client.currentState?.colorHue ?? newValue)) > 0.002 else { return }
                        client.setColor(hue: hue, saturation: saturation)
                    }
            }
            
            VStack(alignment: .leading) {
                Text("Saturation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $saturation, in: 0...1)
                    .onChange(of: saturation) { _, newValue in
                        guard abs(newValue - (client.currentState?.colorSaturation ?? newValue)) > 0.002 else { return }
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
        Section("Display") {
            if state.availableDisplays.isEmpty {
                Text("Waiting for this Mac’s displays…")
                    .foregroundStyle(.secondary)
            } else {
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
    @ObservedObject var settings: RemoteInputSettings
    let macName: String

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Connected to", value: macName)

                Button("Disconnect", role: .destructive) {
                    client.disconnect()
                }
            }

            Section("Trackpad") {
                if settings.mirroredFromMac {
                    Text("Gestures match this MacBook’s Trackpad settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Pointer speed", value: String(format: "%.1f", settings.pointerSpeed))
                Toggle("Pointer acceleration", isOn: $settings.accelerationEnabled)
                Text("Tracking speed and acceleration match this MacBook. Slow moves stay precise; faster flicks cover more of the screen — same for the trackpad and Air pointer.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                LabeledContent("Natural scrolling", value: settings.naturalScrolling ? "On" : "Off")
                LabeledContent("Two-finger secondary click", value: settings.twoFingerSecondaryClick ? "On" : "Off")
                LabeledContent("Three-finger drag", value: settings.threeFingerDrag ? "On" : "Off")
                LabeledContent("Three-finger swipe", value: (settings.threeFingerHorizSwipe || settings.threeFingerVertSwipe) ? "On" : "Off")
                Toggle("Haptic feedback", isOn: $settings.hapticClicks)
                Toggle("Scroll wheel", isOn: $settings.showScrollWheel)
                Text("Shows a notched wheel on the trackpad. Each notch scrolls the Mac and clicks when haptics are on. The iPhone 16 Camera Control only talks to apps that are using the camera, so it can’t scroll from here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Air pointer") {
                Text("Tilt the iPhone to move the Mac cursor. Slow tilts stay precise; a quicker flick covers more of a large display. The trackpad stays available for taps and scrolling.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Slider(value: $settings.gyroSensitivity, in: 0.5...2.0, step: 0.1) {
                    Text("Sensitivity")
                } minimumValueLabel: {
                    Text("0.5×")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("2×")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityValue(Text(String(format: "%.1f×", settings.gyroSensitivity)))
                LabeledContent("Sensitivity", value: String(format: "%.1f×", settings.gyroSensitivity))
            }

            Section("Mac") {
                Text("Trackpad and keyboard need LightStar enabled in System Settings → Privacy & Security → Accessibility on the Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    RemoteControlView(client: RemoteControlClient())
}
