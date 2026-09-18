import WidgetKit
import SwiftUI
import LightStarCore

struct LightStarEntry: TimelineEntry {
    let date: Date
    let state: WidgetState
}

struct LightStarProvider: TimelineProvider {
    func placeholder(in context: Context) -> LightStarEntry {
        LightStarEntry(date: .now, state: WidgetState(connected: true, isOn: true, hue: 0.6, saturation: 1))
    }
    func getSnapshot(in context: Context, completion: @escaping (LightStarEntry) -> Void) {
        completion(LightStarEntry(date: .now, state: WidgetState.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LightStarEntry>) -> Void) {
        let entry = LightStarEntry(date: .now, state: WidgetState.load())
        let next = Calendar.current.date(byAdding: .minute, value: 5, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct LightStarWidgetView: View {
    let entry: LightStarEntry

    var lightColor: Color {
        entry.state.isOn && entry.state.connected
            ? Color(hue: entry.state.hue, saturation: entry.state.saturation, brightness: 1)
            : Color.secondary.opacity(0.3)
    }

    var body: some View {
        VStack(spacing: 6) {
            Circle()
                .fill(lightColor)
                .frame(width: 30, height: 30)
                .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 1))
                .shadow(color: lightColor.opacity(0.6), radius: 6)

            Text(entry.state.connected
                 ? (entry.state.isOn ? "On" : "Off")
                 : "Offline")
                .font(.caption2.bold())
                .foregroundStyle(entry.state.connected ? .primary : .secondary)

            Text("LightStar")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(URL(string: "lightstar://")!)
    }
}

@main
struct LightStarWidget: Widget {
    let kind = "LightStarWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LightStarProvider()) { entry in
            LightStarWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("LightStar")
        .description("Status and quick control for your LED bar.")
        .supportedFamilies([.systemSmall])
    }
}
