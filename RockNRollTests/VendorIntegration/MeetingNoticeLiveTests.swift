import ConferenceCore
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class MeetingNoticeLiveTests: XCTestCase {
    func testHeaderInRequestedFavorite() async throws {
        guard let requested = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_NOTICE_FAVORITE"] else {
            throw XCTSkip("Opt-in live favorite meeting check.")
        }
        let favorite = try XCTUnwrap(RoomHistoryStore().rooms.first {
            $0.isStarred && $0.displayTitle.caseInsensitiveCompare(requested) == .orderedSame
        }, "Requested favorite must already exist")
        let target = try JoinTarget.parse(favorite.joinURL.absoluteString)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = try XCTUnwrap(scene.windows.first)
        let original = window.rootViewController
        let container = UIViewController()
        container.view.backgroundColor = .black
        window.rootViewController = container; window.makeKeyAndVisible()
        let engine = NativeConferenceEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore())
        defer { engine.leave(); window.rootViewController = original }
        let endpoint = try await VendorEndpointResolver.make().resolve(for: target)
        let name = UserDefaults.standard.string(forKey: "savedDisplayName") ?? "Notice QA"
        try engine.configure(container: container, networkURL: endpoint, displayName: name)
        try engine.join(target: target, displayName: name)
        var header: UIView?
        for _ in 0..<60 {
            header = descendants(window).first { $0.accessibilityIdentifier == "Meeting status" }
            if header?.accessibilityValue?.isEmpty == false { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let identity = try XCTUnwrap(header, "Real meeting header must appear")
        XCTAssertFalse(try XCTUnwrap(identity.accessibilityValue).isEmpty, "Real provider privacy state must be present")
        XCTAssertFalse(descendants(window).contains { $0.accessibilityIdentifier == "Top meeting notices" })
        let viewport = descendants(window).first { $0.accessibilityIdentifier == "Shared screen viewport" }
        if let viewport {
            XCTAssertFalse(identity.convert(identity.bounds, to: window).intersects(viewport.convert(viewport.bounds, to: window)))
        }
        attach(window, name: "Live favorite inline privacy header")
        try await Task.sleep(nanoseconds: 4_500_000_000)
        XCTAssertFalse(try XCTUnwrap(identity.accessibilityValue).isEmpty)
        let more = try XCTUnwrap(descendants(window).compactMap { $0 as? UIButton }.first {
            $0.menu?.children.contains(where: { $0.title == L("Meeting details") }) == true
        })
        let action = try XCTUnwrap(more.menu?.children.first { $0.title == L("Meeting details") } as? UIAction)
        // The real menu invokes this same header tap target. Do not alter the room.
        XCTAssertEqual(action.title, L("Meeting details"))
        attach(window, name: "Live favorite privacy after notice expiry")
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func attach(_ window: UIWindow, name: String) {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            window.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
