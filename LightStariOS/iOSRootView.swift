import SwiftUI
import LightStarCore
import WidgetKit

struct iOSRootView: View {
    @Environment(LightBLEManager.self) private var ble

    var body: some View {
        RemoteControlView(client: ble.remoteClient)
            .onChange(of: ble.isOn) { _, _ in writeWidget() }
            .onChange(of: ble.connectionState) { _, _ in writeWidget() }
            .onChange(of: ble.color) { _, _ in writeWidget() }
    }

    private func writeWidget() {
        let (h, s, _) = ble.color.hsvComponents
        WidgetState(
            connected: ble.connectionState == .connected,
            isOn: ble.isOn,
            hue: h,
            saturation: s
        ).save()
        WidgetCenter.shared.reloadTimelines(ofKind: "LightStarWidget")
    }
}
