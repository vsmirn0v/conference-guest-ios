import Foundation

/// A drag is a presentation draft. Persist only a valid drop, reconciled with
/// current membership so a concurrent deletion or unstar cannot be undone.
public struct FavoriteReorderSession: Equatable, Sendable {
    public let sourceID: String
    public let originalIDs: [String]
    public private(set) var orderedIDs: [String]

    public init?(ids: [String], sourceID: String) {
        guard ids.count > 1, Set(ids).count == ids.count, ids.contains(sourceID) else { return nil }
        self.sourceID = sourceID; originalIDs = ids; orderedIDs = ids
    }

    @discardableResult public mutating func move(relativeTo targetID: String, before: Bool) -> Bool {
        guard targetID != sourceID, orderedIDs.contains(targetID) else { return false }
        var updated = orderedIDs.filter { $0 != sourceID }
        guard let target = updated.firstIndex(of: targetID) else { return false }
        updated.insert(sourceID, at: target + (before ? 0 : 1))
        guard updated != orderedIDs else { return false }
        orderedIDs = updated
        return true
    }

    public func orderForDrop(currentIDs: [String]) -> [String]? {
        guard currentIDs.contains(sourceID), orderedIDs != originalIDs else { return nil }
        let reconciled = orderedRoomIDs(orderedIDs, current: currentIDs)
        return reconciled == currentIDs ? nil : reconciled
    }
}
