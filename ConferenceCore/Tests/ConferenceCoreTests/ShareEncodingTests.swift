import XCTest
@testable import ConferenceCore

final class ShareEncodingTests: XCTestCase {
    func testPreferenceIsLocalOptInAndInvalidValueFallsBack() {
        let name = "ShareEncodingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(ShareEncodingPreference.saved(in: defaults), .efficient)
        ShareEncodingPreference.textDetail.save(in: defaults)
        let captured = ShareEncodingPreference.saved(in: defaults)
        ShareEncodingPreference.efficient.save(in: defaults)
        XCTAssertEqual(captured.codec, "vp9")
        XCTAssertEqual(ShareEncodingPreference.saved(in: defaults).codec, "h264")
        defaults.set("unsupported", forKey: ShareEncodingPreference.defaultsKey)
        XCTAssertEqual(ShareEncodingPreference.saved(in: defaults), .efficient)
    }
    func testCodecDoesNotImplyHardware() {
        XCTAssertEqual(ShareEncodingReport(codec: "H264").implementation, .unknown)
        XCTAssertEqual(ShareEncodingReport(codec: "VP9").codec, "vp9")
        XCTAssertEqual(ShareEncodingReport.measured(codec: "h264", powerEfficient: false).implementation, .unknown)
        XCTAssertEqual(ShareEncodingReport.measured(codec: "vp9", powerEfficient: false, encoder: "libvpx").implementation, .software)
    }
}
