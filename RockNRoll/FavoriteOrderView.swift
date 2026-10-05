import ConferenceCore
import SwiftUI

struct FavoriteOrderView: View {
    @ObservedObject var history: RoomHistoryStore
    @Environment(\.dismiss) private var dismiss
    private var favorites: [RecentRoom] { history.rooms.filter(\.isStarred) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(favorites) { room in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(room.displayTitle).font(.body.weight(.semibold))
                            Text("\(room.identifier) · \(room.invitationURL.host() ?? "")")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("favorite.order.\(room.id)")
                        .contextMenu {
                            Button { move(room, by: -1) } label: { Label(L("Move up"), systemImage: "arrow.up") }
                                .disabled(favorites.first?.id == room.id)
                            Button { move(room, by: 1) } label: { Label(L("Move down"), systemImage: "arrow.down") }
                                .disabled(favorites.last?.id == room.id)
                        }
                    }
                    .onMove { source, destination in history.moveFavorites(from: source, to: destination) }
                } footer: {
                    Text(L("Drag the handles to change the order. Changes are saved automatically."))
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(L("Reorder favorites"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }.accessibilityIdentifier("favorites.reorder.done")
                }
            }
        }
    }

    private func move(_ room: RecentRoom, by offset: Int) {
        guard let index = favorites.firstIndex(where: { $0.id == room.id }),
              favorites.indices.contains(index + offset) else { return }
        history.moveFavorites(from: IndexSet(integer: index), to: offset < 0 ? index - 1 : index + 2)
    }
}
