import SwiftUI

struct MenuBarView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("LightStar")
                .font(.headline)
                .padding(.top, 8)

            // Placeholder — replaced in Phase 3/4 with real BLE controls
            Text("BLE controls coming in Phase 3")
                .foregroundStyle(.secondary)
                .font(.caption)

            Spacer()

            Text("Phase 0 scaffold ✓")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
        .frame(width: 280, height: 360)
        .padding(.horizontal, 12)
    }
}
