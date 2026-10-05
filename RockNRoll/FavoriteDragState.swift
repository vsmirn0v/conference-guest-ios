import ConferenceCore
import SwiftUI
import UIKit

@MainActor
final class FavoriteDragState: ObservableObject {
    @Published private(set) var session: FavoriteReorderSession?
    private var snapshot: [String: RecentRoom] = [:]
    private(set) var token: UUID?
    let autoScroll = FavoriteDragAutoScroll()

    func displayedRooms(_ current: [RecentRoom]) -> [RecentRoom] {
        session?.orderedIDs.compactMap { snapshot[$0] } ?? current
    }

    func begin(sourceID: String, rooms: [RecentRoom], token: UUID = UUID()) -> UUID? {
        guard session == nil, let draft = FavoriteReorderSession(ids: rooms.map(\.id), sourceID: sourceID) else { return nil }
        snapshot = Dictionary(uniqueKeysWithValues: rooms.map { ($0.id, $0) })
        self.token = token; session = draft
        return self.token
    }

    func move(relativeTo target: String, before: Bool) {
        guard var draft = session, draft.move(relativeTo: target, before: before) else { return }
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.16)) { session = draft }
        if !ProcessInfo.processInfo.isiOSAppOnMac { UISelectionFeedbackGenerator().selectionChanged() }
    }

    func drop(token: UUID, history: RoomHistoryStore) {
        guard token == self.token else { return }
        if let order = session?.orderForDrop(currentIDs: history.rooms.filter(\.isStarred).map(\.id)) {
            history.setFavoriteOrder(order)
        }
        cancel()
    }

    func cancel(token: UUID? = nil) {
        guard token == nil || token == self.token else { return }
        autoScroll.stop(); session = nil; self.token = nil; snapshot = [:]
    }

    func move(_ roomID: String, by offset: Int, history: RoomHistoryStore) -> Bool {
        guard session == nil else { return false }
        let ids = history.rooms.filter(\.isStarred).map(\.id)
        guard let index = ids.firstIndex(of: roomID), ids.indices.contains(index + offset) else { return false }
        history.moveFavorites(from: IndexSet(integer: index), to: offset < 0 ? index - 1 : index + 2)
        return true
    }
}

/// Scroll the containing Form while a native drag approaches its visible edges.
@MainActor
final class FavoriteDragAutoScroll: NSObject {
    private weak var scrollView: UIScrollView?
    private var velocity: CGFloat = 0
    private var displayLink: CADisplayLink?

    func update(session: UIDropSession, in view: UIView) {
        var ancestor: UIView? = view.superview
        while let current = ancestor, !(current is UIScrollView) { ancestor = current.superview }
        guard let scroll = ancestor as? UIScrollView else { stop(); return }
        let visible = scroll.bounds.inset(by: scroll.adjustedContentInset)
        let y = session.location(in: scroll).y
        let edge = min(60, visible.height / 4)
        guard edge > 0 else { stop(); return }
        velocity = y < visible.minY + edge ? -420 * min(1, (visible.minY + edge - y) / edge) :
            (y > visible.maxY - edge ? 420 * min(1, (y - visible.maxY + edge) / edge) : 0)
        guard velocity != 0 else { stop(); return }
        scrollView = scroll
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common); displayLink = link
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let scroll = scrollView else { stop(); return }
        let minimum = -scroll.adjustedContentInset.top
        let maximum = max(minimum, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let y = min(maximum, max(minimum, scroll.contentOffset.y + velocity * CGFloat(link.targetTimestamp - link.timestamp)))
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: false)
    }

    func stop() { displayLink?.invalidate(); displayLink = nil; scrollView = nil; velocity = 0 }
}
