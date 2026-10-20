import SwiftUI

@available(iOS 16.2, *)
struct MeetingActivityMicrophone: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let state: MeetingActivityState
    let stale: Bool
    var showsLabel = true
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.microphoneSymbol(stale: stale))
            if showsLabel {
                Text(typeSize.isAccessibilitySize && (stale || state.microphone == .unknown)
                    ? L("Unknown") : state.microphoneLabel(stale: stale)).lineLimit(1)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(!stale && state.microphone == .on ? Color.orange : Color.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.microphoneLabel(stale: stale))
    }
}

@available(iOS 16.2, *)
struct MeetingActivityDetails: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let state: MeetingActivityState
    let stale: Bool
    let openURL: URL
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if typeSize.isAccessibilitySize {
                Text(stale || state.connection != .connected ? state.connectionLabel(stale: stale)
                     : state.title ?? L("Meeting in progress"))
                    .font(.caption.weight(.medium)).lineLimit(1)
                    .privacySensitive(!stale && state.connection == .connected && state.title != nil)
                MeetingActivityMicrophone(state: state, stale: stale)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("Rock’n’Roll").font(.caption.weight(.medium)).foregroundStyle(.orange)
                    Spacer(minLength: 8)
                    MeetingActivityMicrophone(state: state, stale: stale)
                }
                Text(state.title ?? L("Meeting in progress"))
                    .font(.headline).lineLimit(1).privacySensitive(state.title != nil)
                HStack(spacing: 6) {
                    Text(state.connectionLabel(stale: stale))
                    if !stale, let route = state.route { Text("· " + route).lineLimit(1) }
                }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    Link(destination: openURL) {
                        Label(L("Open meeting"), systemImage: "arrow.up.right")
                            .font(.subheadline.weight(.medium)).frame(minHeight: 32)
                    }.tint(.orange)
                    Spacer(minLength: 12)
                    Text(state.startedAt, style: .timer).monospacedDigit()
                        .font(.caption).multilineTextAlignment(.trailing)
                        .frame(maxWidth: 85, alignment: .trailing)
                }
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
            .accessibilityHint(L("Open meeting"))
    }
}
