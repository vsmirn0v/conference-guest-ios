import ConferenceCore
import SwiftUI

struct MeetingContinuationView: View {
    @ObservedObject var continuation: MeetingContinuationCoordinator
    let busy: Bool
    let onJoinHere: (ActiveJam) -> Void
    var body: some View {
        if !continuation.candidates.isEmpty || continuation.status != nil {
            Section(L("Continue a jam")) {
                ForEach(continuation.candidates) { jam in
                    VStack(alignment: .leading, spacing: 10) {
                        Label(L("Jam on %@", jam.deviceLabel), systemImage: "laptopcomputer.and.iphone")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(jam.title).font(.headline)
                        if jam.audioPaused == true {
                            Label(L("Second device · audio off"), systemImage: "speaker.slash")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(jam.updatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                        if jam.isRecent(at: Date()) {
                            Button(jam.isSharingScreen ? L("Move here and stop sharing") : L("Continue on this device")) {
                                continuation.begin(jam)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy || continuation.moving)
                            Text(L("Audio pauses on the other device while this one connects. Microphone and camera start off."))
                                .font(.footnote).foregroundStyle(.secondary)
                            if jam.supportsCompanion {
                                Button(L("Join as a second device")) { continuation.begin(jam, companion: true) }
                                    .buttonStyle(.borderless)
                                    .disabled(busy || continuation.moving)
                            }
                        } else {
                            Text(L("Recently active. Its current connection is unconfirmed.")).font(.footnote).foregroundStyle(.secondary)
                            Button(L("Join here")) { onJoinHere(jam) }.buttonStyle(.borderless)
                                .disabled(busy || continuation.moving)
                        }
                    }.padding(.vertical, 5)
                }
                if let status = continuation.status {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
                if continuation.moving { Button(continuation.moveActionTitle) { continuation.cancel() } }
                Button(L("Refresh active jams")) { Task { await continuation.refresh() } }.disabled(continuation.moving)
            }
            .tint(Color(red: 1, green: 0.60, blue: 0.33))
        }
    }
}
