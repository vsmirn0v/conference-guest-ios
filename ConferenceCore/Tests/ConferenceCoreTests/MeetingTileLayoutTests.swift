import CoreGraphics
import XCTest
@testable import ConferenceCore

final class MeetingTileLayoutTests: XCTestCase {
    func testPortraitPairIsVisibleTogether() {
        let frames = MeetingTileLayout.frames(count: 2, size: CGSize(width: 390, height: 620), mode: .grid)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].width, 390)
        XCTAssertEqual(frames[1].maxY, 620)
        XCTAssertFalse(frames[0].intersects(frames[1]))
    }
    func testLandscapePairIsSideBySide() {
        let frames = MeetingTileLayout.frames(count: 2, size: CGSize(width: 700, height: 280), mode: .grid)
        XCTAssertEqual(frames[0].minY, frames[1].minY)
        XCTAssertEqual(frames[1].maxX, 700)
    }
    func testLargeRosterScrollsWithoutOverlappingOrEscapingWidth() {
        for count in 1...30 {
            for mode in MeetingLayoutMode.allCases {
                let frames = MeetingTileLayout.frames(count: count, size: CGSize(width: 390, height: 500), mode: mode)
                XCTAssertEqual(frames.count, count)
                for (index, frame) in frames.enumerated() {
                    XCTAssertGreaterThan(frame.width, 0); XCTAssertGreaterThan(frame.height, 0)
                    XCTAssertGreaterThanOrEqual(frame.minX, 0); XCTAssertLessThanOrEqual(frame.maxX, 390.001)
                    for next in frames.dropFirst(index + 1) { XCTAssertFalse(frame.intersects(next)) }
                }
            }
        }
    }
    func testSpeakerLeavesVisibleThumbnailStrip() {
        let frames = MeetingTileLayout.frames(count: 5, size: CGSize(width: 900, height: 600), mode: .speaker)
        XCTAssertGreaterThan(frames[0].height, frames[1].height)
        XCTAssertEqual(frames.last?.maxY, 600)
    }
}
