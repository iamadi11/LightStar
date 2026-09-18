import SwiftUI
import LightStarCore

/// High-quality trackpad implementation for controlling Mac cursor from iPhone.
struct TrackpadView: View {
    @ObservedObject var client: RemoteControlClient
    @State private var sensitivity: Double = 1.5
    @State private var isDragging = false
    @State private var lastTapTime: Date?
    @State private var tapCount = 0
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                trackpadArea(size: geometry.size)
                controlBar
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
    
    // MARK: - Trackpad Area
    
    private func trackpadArea(size: CGSize) -> some View {
        let trackpadHeight = size.height - 80
        
        return ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
            
            VStack {
                Image(systemName: "hand.draw")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("Trackpad")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: trackpadHeight)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .gesture(trackpadGesture)
        .simultaneousGesture(tapGesture)
        .simultaneousGesture(doubleTapGesture)
        .simultaneousGesture(twoFingerTapGesture)
        .simultaneousGesture(scrollGesture)
    }
    
    // MARK: - Gestures
    
    private var trackpadGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let deltaX = value.translation.width * sensitivity
                let deltaY = value.translation.height * sensitivity
                
                if isDragging {
                    client.sendMouseMove(deltaX: deltaX, deltaY: deltaY)
                } else {
                    client.sendMouseMove(deltaX: deltaX, deltaY: deltaY)
                }
            }
            .onEnded { _ in
                if isDragging {
                    client.sendMouseUp()
                    isDragging = false
                }
            }
    }
    
    private var tapGesture: some Gesture {
        SpatialTapGesture()
            .onEnded { _ in
                let now = Date()
                if let lastTap = lastTapTime, now.timeIntervalSince(lastTap) < 0.3 {
                    tapCount += 1
                } else {
                    tapCount = 1
                }
                lastTapTime = now
                
                if tapCount == 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if self.tapCount == 1 {
                            self.client.sendMouseDown()
                            self.client.sendMouseUp()
                        }
                        self.tapCount = 0
                    }
                } else if tapCount == 2 {
                    client.sendMouseDown()
                    client.sendMouseUp()
                    client.sendMouseDown()
                    client.sendMouseUp()
                    tapCount = 0
                }
            }
    }
    
    private var doubleTapGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                client.sendMouseDown()
                client.sendMouseUp()
                client.sendMouseDown()
                client.sendMouseUp()
            }
    }
    
    private var twoFingerTapGesture: some Gesture {
        SimultaneousGesture(
            SpatialTapGesture(),
            SpatialTapGesture()
        )
        .onEnded { _ in
            client.sendRightClick()
        }
    }
    
    private var scrollGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .simultaneously(with: DragGesture(minimumDistance: 5))
            .onChanged { value in
                if let first = value.first, let second = value.second {
                    let avgDeltaY = (first.translation.height + second.translation.height) / 2
                    let avgDeltaX = (first.translation.width + second.translation.width) / 2
                    client.sendScroll(deltaX: avgDeltaX * 0.5, deltaY: avgDeltaY * 0.5)
                }
            }
    }
    
    // MARK: - Control Bar
    
    private var controlBar: some View {
        HStack(spacing: 20) {
            Button {
                client.sendMouseDown()
                client.sendMouseUp()
            } label: {
                VStack {
                    Image(systemName: "hand.tap")
                        .font(.title2)
                    Text("Click")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            
            Button {
                client.sendRightClick()
            } label: {
                VStack {
                    Image(systemName: "hand.tap")
                        .font(.title2)
                    Text("Right Click")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            
            Button {
                if isDragging {
                    client.sendMouseUp()
                    isDragging = false
                } else {
                    client.sendMouseDown()
                    isDragging = true
                }
            } label: {
                VStack {
                    Image(systemName: isDragging ? "hand.raised.fill" : "hand.raised")
                        .font(.title2)
                    Text(isDragging ? "Drop" : "Drag")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(isDragging ? .accentColor : .secondary)
            .background(isDragging ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            
            Menu {
                ForEach([0.5, 1.0, 1.5, 2.0, 2.5], id: \.self) { value in
                    Button("\(value, specifier: "%.1f")x") {
                        sensitivity = value
                    }
                }
            } label: {
                VStack {
                    Image(systemName: "gauge.with.needle")
                        .font(.title2)
                    Text("\(sensitivity, specifier: "%.1f")x")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

// MARK: - Advanced Trackpad (for future)

struct AdvancedTrackpadView: View {
    @ObservedObject var client: RemoteControlClient
    @State private var touchPoints: [CGPoint] = []
    @State private var sensitivity: Double = 1.5
    @State private var isDragging = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                
                ForEach(Array(touchPoints.enumerated()), id: \.offset) { _, point in
                    Circle()
                        .fill(Color.blue.opacity(0.3))
                        .frame(width: 60, height: 60)
                        .position(point)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleDrag(value, in: geometry.size)
                    }
                    .onEnded { _ in
                        handleDragEnd()
                    }
            )
        }
    }
    
    private func handleDrag(_ value: DragGesture.Value, in size: CGSize) {
        let translation = value.translation
        client.sendMouseMove(
            deltaX: translation.width * sensitivity,
            deltaY: translation.height * sensitivity
        )
    }
    
    private func handleDragEnd() {
        touchPoints.removeAll()
        if isDragging {
            client.sendMouseUp()
            isDragging = false
        }
    }
}

#Preview {
    TrackpadView(client: RemoteControlClient())
}
