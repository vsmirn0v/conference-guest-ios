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
        let tools = buttons[destination == .view ? "call.view" : "call.more"]
        if waitForAutoHide {
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !tools.exists }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 10), .completed, file: file, line: line)
        }
        if !tools.exists || !tools.isHittable {
            let canvases = [scrollViews["Shared screen viewport"], scrollViews["Meeting content"], otherElements["Meeting stage"]]
            guard let canvas = canvases.first(where: { $0.exists && $0.isHittable }) else {
                return XCTFail("No visible meeting canvas to restore controls.", file: file, line: line)
            }
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        guard tools.waitForExistence(timeout: 5) else { return XCTFail("Direct meeting tool is missing.", file: file, line: line) }
        tools.tap()
        if destination == .view {
            XCTAssertTrue(descendants(matching: .any).matching(identifier: "meeting.view.list").firstMatch.waitForExistence(timeout: 5), file: file, line: line)
            return
        }
        guard descendants(matching: .any).matching(identifier: "meeting.actions.list").firstMatch.waitForExistence(timeout: 5) else {
            return XCTFail("More did not finish opening.", file: file, line: line)
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
            !self.descendants(matching: .any).matching(identifier: "meeting.actions.list").firstMatch.exists &&
            !self.descendants(matching: .any).matching(identifier: "meeting.view.list").firstMatch.exists
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
        let collections = collectionViews.matching(NSPredicate(format: "identifier IN %@", ["meeting.actions.list", "meeting.view.list"])).allElementsBoundByIndex
        let scrolls = scrollViews.matching(NSPredicate(format: "identifier IN %@", ["meeting.actions.list", "meeting.view.list"])).allElementsBoundByIndex
        let bounds = windows.firstMatch.frame
        // A List covered by its own rows may report non-hittable, although its
        // visible row centers are valid drag targets. Ignore retained hidden Lists.
        return (collections + scrolls).first {
            $0.exists && $0.frame.intersection(bounds).height > 44 &&
            $0.buttons.allElementsBoundByIndex.contains { $0.exists && $0.isHittable }
        }
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
