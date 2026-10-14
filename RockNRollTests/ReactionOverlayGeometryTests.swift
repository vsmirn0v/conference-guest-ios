import XCTest
@testable import RockNRoll

final class ReactionOverlayGeometryTests: XCTestCase {
    func testOverlayStartsInsideFinalTilesAndNeverCoversHeader() {
        for stage in [CGRect(x: 0, y: 172, width: 375, height: 350),
                      CGRect(x: 8, y: 0, width: 620, height: 330),
                      CGRect(x: 0, y: 180, width: 800, height: 620)] {
            let header = CGRect(x: 8, y: 0, width: stage.width - 16, height: 70)
            let rect = ReactionOverlayGeometry.contentRect(stage: stage, header: header, headerVisible: true)
            XCTAssertGreaterThanOrEqual(rect.minY, stage.minY + 8)
            XCTAssertGreaterThanOrEqual(rect.minY, header.maxY + 8)
            XCTAssertTrue(stage.contains(rect))
            XCTAssertFalse(rect.intersects(header))
        }
    }
    func testHiddenHeaderDoesNotReserveSpaceAndEmptyStageHasNoOverlay() {
        let stage = CGRect(x: 0, y: 0, width: 320, height: 180)
        XCTAssertEqual(ReactionOverlayGeometry.contentRect(stage: stage, header: stage, headerVisible: false),
                       stage.insetBy(dx: 8, dy: 8))
        XCTAssertEqual(ReactionOverlayGeometry.contentRect(stage: .zero, header: stage, headerVisible: true), .zero)
    }
}
