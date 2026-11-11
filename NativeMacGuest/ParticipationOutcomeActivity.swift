import SwiftUI

/// Receipt history is separate from the meeting outcome and never contains private notes.
struct ParticipationOutcomeActivity: View {
    let sessionID: UUID
    let root: URL
    @State private var receipts: [ParticipationReceipt] = []
    @State private var unavailable = false
    @State private var expanded = false

    var body: some View {
        Group {
            if unavailable {
                Text(L("Assistant activity unavailable"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if !receipts.isEmpty {
                DisclosureGroup(L("Assistant activity"), isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(receipts) { receipt in
                            HStack(alignment: .firstTextBaseline) {
                                Text(receipt.state.title)
                                Spacer()
                                Text(receipt.createdAt.formatted(date: .omitted, time: .shortened))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .accessibilityElement(children: .combine)
                        }
                    }.padding(.top, 8)
                }
                .padding(20)
                .accessibilityIdentifier("assistant.participation.activity")
            }
        }
        .task(id: sessionID) {
            do {
                receipts = try ParticipationReceiptStore(root: root).receipts(for: sessionID)
                unavailable = false
            } catch {
                receipts = []
                unavailable = true
            }
        }
    }
}
