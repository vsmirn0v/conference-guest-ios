import SwiftUI

/// Local activity, never a fabricated provider chat or transcript delivery.
/// It remains readable while meeting sound is off and after speech is stopped.
struct ParticipationVoiceTranscriptRow: View {
    let reply: ParticipationVoiceReply

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Label(L("Assistant reply"), systemImage: "waveform")
                    .font(.caption.weight(.semibold)).foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(reply.createdAt, style: .time).font(.caption2).foregroundStyle(.secondary)
            }
            Text(reply.text).textSelection(.enabled)
            Text(reply.status.title).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("participation.voice.transcript.\(reply.id)")
    }
}
