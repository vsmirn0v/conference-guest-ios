import XCTest

enum MeetingMoreDestination: String {
    case cameraSound, sharePresenter, view, invite, meeting
}

extension XCUIApplication {
    /// Uses the same optional hold shortcut exposed to users; individual
    /// navigation tests separately prove the visible Reactions → More route.
    func openMeetingMore(_ destination: MeetingMoreDestination,
                         file: StaticString = #filePath, line: UInt = #line) {
        let reactions = buttons["call.reactions"]
        XCTAssertTrue(reactions.waitForExistence(timeout: 8), file: file, line: line)
        reactions.press(forDuration: 0.65)
        func visible(_ elements: [XCUIElement]) -> XCUIElement? {
            elements.first { $0.exists && $0.frame.width > 1 && $0.frame.height > 1 && $0.isHittable }
        }
        func list() -> XCUIElement? {
            // SwiftUI can retain an offscreen navigation List with the same
            // identifier. Never swipe the first zero-frame AX match.
            let collections = collectionViews.matching(identifier: "meeting.actions.list").allElementsBoundByIndex
            if let current = visible(collections) { return current }
            return visible(scrollViews.matching(identifier: "meeting.actions.list").allElementsBoundByIndex)
        }
        func group() -> XCUIElement? {
            visible(descendants(matching: .any).matching(identifier: "meeting.menu.call.group.\(destination.rawValue)").allElementsBoundByIndex)
        }
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in list() != nil }, object: nil)
        guard XCTWaiter.wait(for: [shown], timeout: 5) == .completed else {
            XCTFail("More has no visible scrollable list.\n\(debugDescription)", file: file, line: line)
            return
        }
        // Compact popovers virtualize rows below their viewport. Scroll the
        // presented list itself before requiring the bottom destination to exist.
        for _ in 0..<6 {
            if group() != nil { break }
            guard let current = list() else { break }
            current.swipeUp()
        }
        guard let destinationRow = group() else {
            XCTFail("More destination \(destination.rawValue) is unreachable.\n\(debugDescription)", file: file, line: line)
            return
        }
        destinationRow.tap()
    }
}
