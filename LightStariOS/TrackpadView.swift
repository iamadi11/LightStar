import SwiftUI
import UIKit
import QuartzCore
import LightStarCore

/// Full-bleed Mac trackpad. Keyboard uses the iPhone system keyboard, not a fake key grid.
struct TrackpadView: View {
    @ObservedObject var client: RemoteControlClient
    @ObservedObject var settings: RemoteInputSettings
    var macName: String = ""
    @FocusState private var keyboardOpen: Bool
    @State private var typeBuffer = ""
    @State private var commandHeld = false
    @State private var optionHeld = false
    @State private var controlHeld = false
    @State private var shiftHeld = false
    @State private var showActions = false
    @State private var showSettings = false
    @StateObject private var gyro = GyroPointerController()
    @StateObject private var mediaHUD = RemoteLevelHUDModel()
    @Environment(\.scenePhase) private var scenePhase
    var isActiveTab = true
    @State private var isLandscape = false

    var body: some View {
        NavigationStack {
            Group {
                if isLandscape {
                    HStack(spacing: 0) {
                        trackpadCanvas
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if !keyboardOpen {
                            landscapeSideBar
                        }
                    }
                    .padding(.leading, 8)
                    .padding(.vertical, 8)
                } else {
                    VStack(spacing: 0) {
                        trackpadCanvas
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                        if !keyboardOpen {
                            playbackBar
                                .padding(.horizontal, 16)
                                .padding(.top, 4)
                            HStack(spacing: 8) {
                                if gyro.isAvailable {
                                    airPointerButton
                                }
                                keyboardToggleButton
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 12)
                        }
                    }
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if keyboardOpen {
                    MacKeyboardAccessory(
                        commandHeld: $commandHeld,
                        optionHeld: $optionHeld,
                        controlHeld: $controlHeld,
                        shiftHeld: $shiftHeld,
                        hapticsEnabled: settings.hapticClicks,
                        onDismiss: dismissKeyboard
                    )
                }
            }
            .background {
                TextField("", text: $typeBuffer)
                    .focused($keyboardOpen)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.default)
                    .submitLabel(.return)
                    .onChange(of: typeBuffer) { oldValue, newValue in
                        sendTypingDelta(from: oldValue, to: newValue)
                    }
                    .onSubmit {
                        client.sendHotkey(keyCode: 0x24, modifiers: currentModifiers)
                        resetStickyModifiers()
                        RemoteHaptics.click(enabled: settings.hapticClicks)
                    }
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .accessibilityHidden(true)
            }
            .navigationTitle("Remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showActions = true
                    } label: {
                        Image(systemName: "macbook")
                    }
                    .accessibilityLabel("Mac actions")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showActions) {
                MacControlsView(client: client, settings: settings)
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    RemoteSettingsView(client: client, settings: settings, macName: macName)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showSettings = false }
                            }
                        }
                }
            }
        }
        .toolbar(keyboardOpen ? .hidden : .visible, for: .tabBar)
        .onAppear {
            bindGyroPointer()
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            syncInterfaceOrientation()
        }
        .onDisappear {
            gyro.disengage()
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        .onChange(of: keyboardOpen) { _, open in
            if open {
                gyro.disengage()
                RemoteHaptics.soft(enabled: settings.hapticClicks)
            } else {
                typeBuffer = ""
                resetStickyModifiers()
            }
        }
        .onChange(of: showActions) { _, open in
            if open { gyro.disengage() }
        }
        .onChange(of: showSettings) { _, open in
            if open { gyro.disengage() }
        }
        .onChange(of: isActiveTab) { _, active in
            if !active { gyro.disengage() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { gyro.disengage() }
            if phase == .active { syncInterfaceOrientation() }
        }
        .onChange(of: client.state) { _, newState in
            if case .connected = newState {
                mediaHUD.reset()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            syncInterfaceOrientation()
        }
    }

    private var trackpadCanvas: some View {
        MacTrackpadSurface(client: client, settings: settings)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, isLandscape ? 4 : 0)
            .overlay(alignment: .top) {
                if gyro.isEngaged {
                    gyroStatusBar
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }
            }
            .overlay {
                if mediaHUD.visible {
                    RemoteLevelHUD(icon: mediaHUD.icon, title: mediaHUD.title, level: mediaHUD.level)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.easeOut(duration: 0.12), value: mediaHUD.visible)
    }

    private var landscapeSideBar: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                landscapeIconButton("backward.fill", "Previous") { sendMedia(.previousTrack) }
                landscapeIconButton("playpause.fill", "Play/Pause") { sendMedia(.playPause) }
                landscapeIconButton("forward.fill", "Next") { sendMedia(.nextTrack) }
                landscapeIconButton("speaker.minus.fill", "Volume Down") { sendMedia(.volumeDown) }
                landscapeIconButton("speaker.plus.fill", "Volume Up") { sendMedia(.volumeUp) }
                landscapeIconButton("sun.min.fill", "Brightness Down") { sendMedia(.brightnessDown) }
                landscapeIconButton("sun.max.fill", "Brightness Up") { sendMedia(.brightnessUp) }
                if gyro.isAvailable {
                    landscapeIconButton(
                        "dot.scope",
                        gyro.isEngaged ? "Stop Air pointer" : "Air pointer",
                        selected: gyro.isEngaged
                    ) {
                        toggleAirPointer()
                    }
                }
                landscapeIconButton("keyboard", "Keyboard") { keyboardOpen = true }
            }
            .padding(.vertical, 4)
        }
        .padding(.trailing, 8)
        .frame(width: 64)
        .safeAreaPadding(.bottom, 4)
    }

    private func landscapeIconButton(
        _ icon: String,
        _ label: String,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            RemoteHaptics.select(enabled: settings.hapticClicks)
            action()
        } label: {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .frame(width: 48, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.28) : Color(uiColor: .secondarySystemFill))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1)
                }
        }
        .buttonStyle(RemotePressButtonStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func syncInterfaceOrientation() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let orientation = scene?.interfaceOrientation ?? .portrait
        isLandscape = orientation.isLandscape
        gyro.setInterfaceOrientation(orientation)
    }

    private var keyboardToggleButton: some View {
        Button {
            keyboardOpen = true
        } label: {
            Label("Keyboard", systemImage: "keyboard")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 48)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemFill))
                )
        }
        .buttonStyle(RemotePressButtonStyle())
        .accessibilityHint("Opens the iPhone keyboard to type on the Mac")
    }

    private func bindGyroPointer() {
        gyro.onMove = { dx, dy in
            client.addMouseDelta(deltaX: dx, deltaY: dy)
        }
    }

    private var airPointerButton: some View {
        Button {
            RemoteHaptics.select(enabled: settings.hapticClicks)
            toggleAirPointer()
        } label: {
            Label(gyro.isEngaged ? "Stop Air pointer" : "Air pointer", systemImage: "dot.scope")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 48)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(gyro.isEngaged ? Color.accentColor.opacity(0.28) : Color(uiColor: .secondarySystemFill))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(gyro.isEngaged ? Color.accentColor : Color.clear, lineWidth: 1)
                }
        }
        .buttonStyle(RemotePressButtonStyle())
        .accessibilityAddTraits(gyro.isEngaged ? .isSelected : [])
        .accessibilityHint("Tilt the iPhone to move the Mac pointer. Trackpad stays available.")
    }

    private func toggleAirPointer() {
        if gyro.isEngaged {
            gyro.disengage()
        } else {
            bindGyroPointer()
            gyro.engage(
                sensitivity: settings.gyroSensitivity * (0.5 + settings.pointerSpeed * 0.25),
                accelerationEnabled: settings.accelerationEnabled
            )
        }
    }

    private var gyroStatusBar: some View {
        HStack(spacing: 8) {
            Text("Tilt to move pointer")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            Button("Recenter") {
                gyro.recenter()
                client.sendMacAction(.centerPointer)
                RemoteHaptics.select(enabled: settings.hapticClicks)
            }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 44)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemFill))
            )
            .buttonStyle(RemotePressButtonStyle())
            .accessibilityHint("Moves the Mac pointer to the center of the current display and zeros tilt")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .systemBackground).opacity(0.92))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Air pointer aiming")
    }

    private var playbackBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                playbackButton("backward.fill", "Previous") { sendMedia(.previousTrack) }
                playbackButton("playpause.fill", "Play/Pause") { sendMedia(.playPause) }
                playbackButton("forward.fill", "Next") { sendMedia(.nextTrack) }
            }
            HStack(spacing: 8) {
                playbackButton("speaker.minus.fill", "Volume Down") { sendMedia(.volumeDown) }
                playbackButton("speaker.plus.fill", "Volume Up") { sendMedia(.volumeUp) }
                playbackButton("sun.min.fill", "Brightness Down") { sendMedia(.brightnessDown) }
                playbackButton("sun.max.fill", "Brightness Up") { sendMedia(.brightnessUp) }
            }
        }
    }

    private func sendMedia(_ key: MediaKeyMessage.MediaKey) {
        mediaHUD.handle(key)
        client.sendMediaKey(key)
    }

    private func playbackButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button {
            RemoteHaptics.select(enabled: settings.hapticClicks)
            action()
        } label: {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemFill))
                )
        }
        .buttonStyle(RemotePressButtonStyle())
        .accessibilityLabel(label)
    }

    private func dismissKeyboard() {
        RemoteHaptics.soft(enabled: settings.hapticClicks)
        keyboardOpen = false
        typeBuffer = ""
    }

    private var currentModifiers: UInt32 {
        var modifiers: UInt32 = 0
        if commandHeld { modifiers |= RemoteModifier.command }
        if optionHeld { modifiers |= RemoteModifier.option }
        if controlHeld { modifiers |= RemoteModifier.control }
        if shiftHeld { modifiers |= RemoteModifier.shift }
        return modifiers
    }

    private var modifiersHeld: Bool {
        commandHeld || optionHeld || controlHeld || shiftHeld
    }

    private func sendSpecialKey(_ keyCode: UInt16) {
        client.sendHotkey(keyCode: keyCode, modifiers: currentModifiers)
        resetStickyModifiers()
        RemoteHaptics.click(enabled: settings.hapticClicks)
    }

    private func resetStickyModifiers() {
        commandHeld = false
        optionHeld = false
        controlHeld = false
        shiftHeld = false
    }

    private func sendTypingDelta(from oldValue: String, to newValue: String) {
        if modifiersHeld, newValue.count == oldValue.count + 1, newValue.hasPrefix(oldValue),
           let scalar = newValue.last {
            if let keyCode = MacHIDKeyCode.from(scalar) {
                sendSpecialKey(keyCode)
            } else {
                client.sendTextInput(String(scalar))
                resetStickyModifiers()
            }
            return
        }

        if newValue.count > oldValue.count, newValue.hasPrefix(oldValue) {
            client.sendTextInput(String(newValue.dropFirst(oldValue.count)))
            return
        }
        if newValue.count < oldValue.count, oldValue.hasPrefix(newValue) {
            for _ in 0..<(oldValue.count - newValue.count) {
                client.sendHotkey(keyCode: 0x33)
            }
            return
        }
        for _ in 0..<oldValue.count {
            client.sendHotkey(keyCode: 0x33)
        }
        if !newValue.isEmpty {
            client.sendTextInput(newValue)
        }
    }
}

// MARK: - UIKit trackpad

struct MacTrackpadSurface: UIViewRepresentable {
    var client: RemoteControlClient
    @ObservedObject var settings: RemoteInputSettings

    func makeUIView(context: Context) -> MacTrackpadUIView {
        let view = MacTrackpadUIView()
        view.client = client
        view.settings = settings
        return view
    }

    func updateUIView(_ uiView: MacTrackpadUIView, context: Context) {
        uiView.client = client
        uiView.settings = settings
    }
}

@MainActor
final class MacTrackpadUIView: UIView {
    var client: RemoteControlClient?
    var settings: RemoteInputSettings?

    private var lastLocation: [ObjectIdentifier: CGPoint] = [:]
    private var startLocation: [ObjectIdentifier: CGPoint] = [:]
    private var activeIDs: Set<ObjectIdentifier> = []
    private var touchBeganAt: TimeInterval = 0
    private var lastMoveAt: TimeInterval = 0
    private var potentialTap = true
    private var twoFingerTapCandidate = false
    private var peakFingerCount = 0
    private var maxTravel: CGFloat = 0
    private var threeFingerTravel = CGSize.zero
    private var isClickDrag = false
    private var longPressTask: Task<Void, Never>?
    private var momentumTask: Task<Void, Never>?
    private var lastTapAt: TimeInterval = 0
    private var lastScrollVX: CGFloat = 0
    private var lastScrollVY: CGFloat = 0
    private var velocityEMA = 0.0
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private let tapSlop: CGFloat = 10
    private var lastAspectLandscape: Bool?
    private var fingerDots: [ObjectIdentifier: CALayer] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = true
        isOpaque = false
        backgroundColor = UIColor.secondarySystemGroupedBackground
        layer.cornerRadius = 20
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.08
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)
        haptic.prepare()
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 20).cgPath
        let landscape = bounds.width > bounds.height + 8
        if lastAspectLandscape != landscape {
            if lastAspectLandscape != nil {
                cancelMomentum()
                resetGestureState()
            }
            lastAspectLandscape = landscape
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelMomentum()
        let now = ProcessInfo.processInfo.systemUptime
        if activeIDs.isEmpty {
            touchBeganAt = now
            potentialTap = true
            twoFingerTapCandidate = false
            peakFingerCount = 0
            maxTravel = 0
            threeFingerTravel = .zero
            lastMoveAt = now
            lastScrollVX = 0
            lastScrollVY = 0
            velocityEMA = 0
        }
        for touch in touches {
            let id = ObjectIdentifier(touch)
            let loc = touch.location(in: self)
            lastLocation[id] = loc
            startLocation[id] = loc
            activeIDs.insert(id)
            showFingerDot(id, at: loc)
        }
        peakFingerCount = max(peakFingerCount, activeIDs.count)
        if activeIDs.count == 1 {
            scheduleLongPress()
        } else {
            cancelLongPress()
            if activeIDs.count == 2 {
                twoFingerTapCandidate = potentialTap && maxTravel < tapSlop
            }
            if activeIDs.count >= 3, settings?.threeFingerDrag == true, !isClickDrag {
                isClickDrag = true
                potentialTap = false
                twoFingerTapCandidate = false
                client?.sendMouseDown()
                clickHaptic()
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        var fingers = 0
        for touch in touches {
            let id = ObjectIdentifier(touch)
            guard let prev = lastLocation[id] else { continue }
            let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
            var loc = prev
            for sample in coalesced {
                let next = sample.location(in: self)
                sumX += next.x - loc.x
                sumY += next.y - loc.y
                loc = next
            }
            lastLocation[id] = loc
            moveFingerDot(id, to: loc)
            fingers += 1
        }
        guard fingers > 0 else { return }

        let dx = sumX / CGFloat(fingers)
        let dy = sumY / CGFloat(fingers)
        let now = ProcessInfo.processInfo.systemUptime
        let dt = max(0.004, now - lastMoveAt)
        lastMoveAt = now

        for id in activeIDs {
            if let start = startLocation[id], let current = lastLocation[id] {
                maxTravel = max(maxTravel, hypot(current.x - start.x, current.y - start.y))
            }
        }
        if maxTravel > tapSlop {
            potentialTap = false
            twoFingerTapCandidate = false
            if activeIDs.count == 1 { cancelLongPress() }
        }

        switch activeIDs.count {
        case 1:
            sendPointer(dx: dx, dy: dy, dt: dt)
        case 2:
            lastScrollVX = dx / CGFloat(dt)
            lastScrollVY = dy / CGFloat(dt)
            sendScroll(dx: dx, dy: dy)
        case 3...:
            handleThreeFingerMove(dx: dx, dy: dy, dt: dt)
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishTouches(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishTouches(touches, cancelled: true)
    }

    private func handleThreeFingerMove(dx: CGFloat, dy: CGFloat, dt: TimeInterval) {
        if settings?.threeFingerDrag == true {
            if !isClickDrag {
                isClickDrag = true
                client?.sendMouseDown()
                clickHaptic()
            }
            sendPointer(dx: dx, dy: dy, dt: dt)
            return
        }
        threeFingerTravel.width += dx
        threeFingerTravel.height += dy
    }

    private func finishTouches(_ touches: Set<UITouch>, cancelled: Bool) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            activeIDs.remove(id)
            lastLocation.removeValue(forKey: id)
            startLocation.removeValue(forKey: id)
            removeFingerDot(id)
        }
        if activeIDs.isEmpty {
            let duration = ProcessInfo.processInfo.systemUptime - touchBeganAt
            if !cancelled {
                finishGesture(duration: duration)
            } else if isClickDrag {
                client?.sendMouseUp()
            }
            resetGestureState()
        }
    }

    private func finishGesture(duration: TimeInterval) {
        if isClickDrag {
            client?.sendMouseUp()
            return
        }

        if twoFingerTapCandidate,
           peakFingerCount >= 2,
           duration < 0.45,
           maxTravel < tapSlop,
           settings?.twoFingerSecondaryClick != false {
            client?.sendRightClick()
            clickHaptic()
            return
        }

        if peakFingerCount >= 3, maxTravel >= 70 {
            let swipe = RemoteTrackpadSwipe.from(
                dx: Double(threeFingerTravel.width),
                dy: Double(threeFingerTravel.height)
            )
            if let swipe {
                let allowHoriz = settings?.threeFingerHorizSwipe != false
                let allowVert = settings?.threeFingerVertSwipe != false
                let allowed: Bool
                switch swipe {
                case .left, .right: allowed = allowHoriz
                case .up, .down: allowed = allowVert
                }
                if allowed {
                    client?.sendMacAction(swipe.macAction)
                    clickHaptic()
                    return
                }
            }
        }

        if peakFingerCount <= 1,
           potentialTap,
           duration < 0.35,
           settings?.tapToClick != false {
            let now = ProcessInfo.processInfo.systemUptime
            let doubleWindow = settings?.doubleClickThreshold ?? 0.5
            if now - lastTapAt < doubleWindow {
                client?.sendMouseDown(clickCount: 2)
                client?.sendMouseUp(clickCount: 2)
                lastTapAt = now - doubleWindow - 1
            } else {
                client?.sendMouseDown(clickCount: 1)
                client?.sendMouseUp(clickCount: 1)
                lastTapAt = now
            }
            clickHaptic()
            return
        }

        if peakFingerCount == 2, hypot(lastScrollVX, lastScrollVY) > 380 {
            startScrollMomentum()
        }
    }

    private func resetGestureState() {
        cancelLongPress()
        if isClickDrag {
            client?.sendMouseUp()
        }
        potentialTap = true
        twoFingerTapCandidate = false
        peakFingerCount = 0
        maxTravel = 0
        threeFingerTravel = .zero
        isClickDrag = false
        lastLocation.removeAll()
        startLocation.removeAll()
        activeIDs.removeAll()
        clearFingerDots()
    }

    private func scheduleLongPress() {
        cancelLongPress()
        longPressTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 220_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, self.activeIDs.count == 1, self.potentialTap, !self.isClickDrag else { return }
            self.potentialTap = false
            self.isClickDrag = true
            self.client?.sendMouseDown()
            self.clickHaptic()
        }
    }

    private func cancelLongPress() {
        longPressTask?.cancel()
        longPressTask = nil
    }

    private func startScrollMomentum() {
        cancelMomentum()
        var vx = lastScrollVX
        var vy = lastScrollVY
        momentumTask = Task { @MainActor in
            for _ in 0..<14 {
                do {
                    try await Task.sleep(nanoseconds: 16_000_000)
                } catch {
                    return
                }
                vx *= 0.86
                vy *= 0.86
                if hypot(vx, vy) < 45 { return }
                self.sendScroll(dx: vx * 0.016, dy: vy * 0.016)
            }
        }
    }

    private func cancelMomentum() {
        momentumTask?.cancel()
        momentumTask = nil
    }

    private func sendPointer(dx: CGFloat, dy: CGFloat, dt: TimeInterval) {
        let scaling = settings?.pointerSpeed ?? 1
        let instant = dt > 0 ? Double(hypot(dx, dy)) / dt : 0
        velocityEMA = velocityEMA * 0.72 + instant * 0.28
        let accel = RemotePointerAcceleration.factor(
            pixelsPerSecond: velocityEMA,
            enabled: settings?.accelerationEnabled != false,
            scaling: scaling
        )
        client?.sendMouseMove(deltaX: Double(dx) * accel, deltaY: Double(dy) * accel)
    }

    private func sendScroll(dx: CGFloat, dy: CGFloat) {
        client?.sendScroll(deltaX: Double(dx) * 1.85, deltaY: Double(dy) * 1.85)
    }

    private func showFingerDot(_ id: ObjectIdentifier, at point: CGPoint) {
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
        dot.cornerRadius = 22
        dot.backgroundColor = UIColor.white.withAlphaComponent(0.22).cgColor
        dot.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        dot.borderWidth = 1
        dot.position = point
        layer.addSublayer(dot)
        fingerDots[id] = dot
    }

    private func moveFingerDot(_ id: ObjectIdentifier, to point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fingerDots[id]?.position = point
        CATransaction.commit()
    }

    private func removeFingerDot(_ id: ObjectIdentifier) {
        fingerDots[id]?.removeFromSuperlayer()
        fingerDots.removeValue(forKey: id)
    }

    private func clearFingerDots() {
        fingerDots.values.forEach { $0.removeFromSuperlayer() }
        fingerDots.removeAll()
    }

    private func clickHaptic() {
        guard settings?.hapticClicks != false else { return }
        haptic.impactOccurred()
        haptic.prepare()
    }
}

#Preview {
    TrackpadView(client: RemoteControlClient(), settings: RemoteInputSettings())
}
