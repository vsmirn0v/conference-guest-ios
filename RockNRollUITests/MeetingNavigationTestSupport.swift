import XCTest

enum MeetingMoreDestination: String {
    case cameraSound, sharePresenter, view, invite, meeting
}

extension XCUIApplication {
    /// Retained regressions use the discoverable visible route. Dedicated tests
    /// independently verify the optional held-press shortcut and release handling.
    func openMeetingMore(_ destination: MeetingMoreDestination, waitForAutoHide: Bool = false,
                         file: StaticString = #filePath, line: UInt = #line) {
        guard waitForMeetingToolsToClose(file: file, line: line) else { return }
        let reactions = buttons["call.reactions"]
        if waitForAutoHide {
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !reactions.exists }, object: nil)
            guard XCTWaiter.wait(for: [hidden], timeout: 10) == .completed else {
                XCTFail("Meeting controls did not auto-hide before restoring them.", file: file, line: line)
                return
            }
        }
        if !reactions.exists || !reactions.isHittable {
            // Auto-hide can expire while the previous panel's dismissal settles.
            // Restore through the same media tap a participant uses.
            let canvases = [scrollViews["Shared screen viewport"], scrollViews["Meeting content"],
                            otherElements["Meeting stage"]]
            guard let canvas = canvases.first(where: { $0.exists && $0.isHittable }) else {
                XCTFail("Meeting controls are hidden and no tappable media canvas is available.\n\(debugDescription)", file: file, line: line)
                return
            }
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            guard reactions.waitForExistence(timeout: 3) else {
                XCTFail("Tapping meeting content did not restore Reactions.\n\(debugDescription)", file: file, line: line)
                return
            }
            // Use the restored button's verified frame before another sequence of
            // AX hit-point queries can consume the fresh five-second hide window.
            let window = windows.firstMatch, bounds = window.frame, frame = reactions.frame
            guard frame.width >= 44, frame.height >= 44, bounds.contains(frame) else {
                XCTFail("Restored Reactions is outside the meeting window: \(frame)", file: file, line: line)
                return
            }
            window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX - bounds.minX, dy: frame.midY - bounds.minY)).tap()
        } else {
            reactions.tap()
        }
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.meetingActionsList != nil }, object: nil)
        guard XCTWaiter.wait(for: [shown], timeout: 5) == .completed else {
            XCTFail("Reactions has no visible scrollable list.\n\(debugDescription)", file: file, line: line)
            return
        }
        meetingActionButton("call.more", file: file, line: line).tap()
        guard buttons["meeting.more.reactions"].waitForExistence(timeout: 5) else {
            XCTFail("The visible More action did not open its destinations.\n\(debugDescription)", file: file, line: line)
            return
        }
        let identifier = "meeting.menu.call.group.\(destination.rawValue)"
        guard let row = scrollMeetingActions(to: {
            self.visibleMeetingElement(self.descendants(matching: .any).matching(identifier: identifier).allElementsBoundByIndex)
        }) else {
            XCTFail("More destination \(destination.rawValue) is unreachable.\n\(debugDescription)", file: file, line: line)
            return
        }
        row.tap()
    }

    @discardableResult
    func waitForMeetingToolsToClose(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !self.descendants(matching: .any).matching(identifier: "meeting.actions.list").firstMatch.exists
        }, object: nil)
        guard XCTWaiter.wait(for: [closed], timeout: 8) == .completed else {
            XCTFail("The action panel did not finish dismissing.\n\(debugDescription)", file: file, line: line)
            return false
        }
        return true
    }

    /// Reveals a leaf within the already-open destination. This avoids UIKit's
    /// automatic element scrolling through a zero-size SwiftUI popover ancestor.
    func meetingActionButton(_ label: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let query = buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label))
        if let row = scrollMeetingActions(to: { self.visibleMeetingElement(query.allElementsBoundByIndex) }) { return row }
        XCTFail("Meeting action \(label) is unreachable.\n\(debugDescription)", file: file, line: line)
        return query.firstMatch
    }

    private func visibleMeetingElement(_ elements: [XCUIElement]) -> XCUIElement? {
        let bounds = windows.firstMatch.frame
        return elements.first {
            guard $0.exists else { return false }
            let frame = $0.frame
            return frame.width > 1 && frame.height > 1 && bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) && $0.isHittable
        }
    }

    private var meetingActionsList: XCUIElement? {
        // SwiftUI may retain offscreen navigation Lists with the same identifier.
        let collections = collectionViews.matching(identifier: "meeting.actions.list").allElementsBoundByIndex
        if let current = visibleMeetingElement(collections) { return current }
        return visibleMeetingElement(scrollViews.matching(identifier: "meeting.actions.list").allElementsBoundByIndex)
    }

    private func scrollMeetingActions(to target: () -> XCUIElement?) -> XCUIElement? {
        for _ in 0..<8 {
            if let row = target() { return row }
            guard let list = meetingActionsList else { return nil }
            let window = windows.firstMatch
            let windowFrame = window.frame
            let viewport = list.frame.intersection(windowFrame)
            let rows = list.buttons.allElementsBoundByIndex.filter {
                $0.exists && $0.isHittable && $0.frame.width > 1 && $0.frame.height > 1 &&
                viewport.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
            }.sorted { $0.frame.midY < $1.frame.midY }
            guard let first = rows.first, let last = rows.last, viewport.height > 60 else { return nil }
            // The AX export shows a zero-size SwiftUI ancestor even though the
            // collection and its visible rows have valid frames. Container.swipeUp
            // rejects it, so drag between verified row centers in window space.
            let start = CGPoint(x: last.frame.midX, y: last.frame.midY)
            let end = CGPoint(x: start.x, y: max(viewport.minY + 12, first.frame.midY))
            guard start.y - end.y > 40, viewport.contains(start), viewport.contains(end) else { return nil }
            let hierarchy = XCTAttachment(string: debugDescription)
            hierarchy.name = "More scroll hierarchy"; hierarchy.lifetime = .deleteOnSuccess
            XCTContext.runActivity(named: "Scroll visible More rows") { $0.add(hierarchy) }
            print("MEETING_MORE_SCROLL window=\(windowFrame) list=\(list.frame) start=\(start) end=\(end)")
            let origin = window.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: start.x - windowFrame.minX, dy: start.y - windowFrame.minY))
                .press(forDuration: 0.02, thenDragTo: origin.withOffset(CGVector(dx: end.x - windowFrame.minX, dy: end.y - windowFrame.minY)))
        }
        return target()
    }
}
