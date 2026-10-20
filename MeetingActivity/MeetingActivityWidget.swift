import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MeetingActivityBundle: WidgetBundle {
    var body: some Widget { MeetingActivityWidget() }
}

struct MeetingActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MeetingActivityAttributes.self) { context in
            MeetingActivityDetails(state: context.state, stale: context.isStale, openURL: openURL(context.attributes))
                .widgetURL(openURL(context.attributes))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    MeetingActivityDetails(state: context.state, stale: context.isStale, openURL: openURL(context.attributes))
                        .environment(\.colorScheme, .dark)
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Text("R").font(.caption.weight(.bold)).foregroundStyle(.orange)
                    MeetingActivityMicrophone(state: context.state, stale: context.isStale, showsLabel: false)
                }.environment(\.colorScheme, .dark)
            } compactTrailing: {
                ViewThatFits(in: .horizontal) {
                    Text(context.state.startedAt, style: .timer).monospacedDigit().fixedSize()
                    Image(systemName: context.state.microphoneSymbol(stale: context.isStale))
                }.font(.caption).foregroundStyle(.white)
            } minimal: {
                MeetingActivityMicrophone(state: context.state, stale: context.isStale, showsLabel: false)
                    .environment(\.colorScheme, .dark)
            }
            .widgetURL(openURL(context.attributes)).keylineTint(.orange)
        }
    }
    private func openURL(_ attributes: MeetingActivityAttributes) -> URL {
        URL(string: "conferenceguest://active-meeting/" + attributes.sessionID.uuidString)!
    }
}
