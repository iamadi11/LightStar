import SwiftUI
import AppKit
import LightStarCore

struct LightStarVisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .menu

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Quiet section padding — no fill, no shadow, no gradient.
struct GlassCard<Content: View>: View {
    var tint: Color = .clear
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum LightStarMotion {
    static func spring(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.08)
    }

    static func snappy(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy(duration: 0.22)
    }
}

extension LightBLEManager {
    var stripAccent: Color {
        guard connectionState == .connected, isOn else {
            return Color.primary.opacity(0.35)
        }
        return syncColor ?? color
    }
}
