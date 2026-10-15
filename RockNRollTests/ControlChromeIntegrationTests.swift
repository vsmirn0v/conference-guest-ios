import UIKit
import SwiftUI
import XCTest
@testable import RockNRoll

@MainActor
final class ControlChromeIntegrationTests: XCTestCase {
    func testSwiftUIUpdatesRetainOneBackgroundAndItsNativeBacking() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let state = ChromeUpdateState()
        var renderedCount = -1
        let host = UIHostingController(rootView: UpdatingChrome(state: state) { renderedCount = $0 })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await waitForUpdate { renderedCount == 0 }
        let surface = try XCTUnwrap(descendants(MeetingChromeSurface.self, in: host.view).first)
        let backing = surface.subviews.first
        for count in 1...30 {
            state.count = count
            try await waitForUpdate { renderedCount == count }
            host.view.layoutIfNeeded()
            let retained = descendants(MeetingChromeSurface.self, in: host.view)
            XCTAssertEqual(retained.count, 1)
            XCTAssertTrue(retained.first === surface)
            XCTAssertTrue(surface.subviews.first === backing)
        }
    }

    private func waitForUpdate(_ rendered: () -> Bool) async throws {
        for _ in 0..<100 {
            if rendered() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The mounted SwiftUI content did not render its new state")
    }

    func testConversationBackgroundsPreserveComposerAndActionHitTargetsAfterResize() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let chat = ChatStore()
        chat.canSend = true
        chat.draft = "Keep the arrangement"
        let controls = CallWorkspaceControls()
        var toggles = 0
        controls.toggleMicrophone = { toggles += 1 }
        let panel = ConversationPanelViewController(catchUp: CatchUpStore(), chat: chat, call: controls)
        window.rootViewController = panel
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }

        for size in [CGSize(width: 320, height: 568), CGSize(width: 568, height: 320),
                     CGSize(width: 1024, height: 768), CGSize(width: 390, height: 844)] {
            panel.view.frame = CGRect(origin: .zero, size: size)
            panel.view.setNeedsLayout()
            panel.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
            let backgrounds = descendants(MeetingChromeSurface.self, in: panel.view)
            XCTAssertEqual(backgrounds.count, 2, "Resizing must retain the header and call-strip backgrounds")
            XCTAssertTrue(backgrounds.allSatisfy { !$0.isUserInteractionEnabled && $0.accessibilityElementsHidden })
            let title = try XCTUnwrap(descendants(UILabel.self, in: panel.view).first {
                $0.accessibilityIdentifier == "conversation.title"
            })
            let header = try XCTUnwrap(title.superview)
            XCTAssertGreaterThanOrEqual(title.frame.minX, 16, "Header text needs an inset inside its rounded chrome")
            XCTAssertTrue(header.bounds.contains(title.frame), "The title must stay inside the header after rotation")
            XCTAssertEqual(title.frame.midY, header.bounds.midY, accuracy: 1)
            XCTAssertEqual(header.bounds.height, max(44, ceil(title.intrinsicContentSize.height + 8)), accuracy: 1,
                           "Unused reading space must not stretch the header")
            let composer = try XCTUnwrap(descendants(UITextView.self, in: panel.view).first { $0.isEditable })
            XCTAssertEqual(composer.text, "Keep the arrangement")
            XCTAssertFalse(backgrounds.contains { $0.isDescendant(of: composer) })
            let microphone = try XCTUnwrap(descendants(UIButton.self, in: panel.view).first {
                $0.accessibilityLabel == L("Unmute microphone")
            })
            XCTAssertGreaterThanOrEqual(microphone.bounds.width, 44)
            XCTAssertGreaterThanOrEqual(microphone.bounds.height, 44)
            let hit = microphone.hitTest(CGPoint(x: microphone.bounds.midX, y: microphone.bounds.midY), with: nil)
            XCTAssertTrue(hit === microphone || hit?.isDescendant(of: microphone) == true)
            microphone.sendActions(for: .touchUpInside)
        }
        XCTAssertEqual(toggles, 4)
        XCTAssertEqual(chat.draft, "Keep the arrangement")
    }

    func testReadingSurfacesRemainOpaqueAndOutsideGlassAfterTranscriptSwitch() throws {
        let store = CatchUpStore()
        let panel = ConversationPanelViewController(catchUp: store, chat: ChatStore())
        panel.loadViewIfNeeded()
        let modes = try XCTUnwrap(descendants(UISegmentedControl.self, in: panel.view).first)
        let reading = descendants(UITextView.self, in: panel.view).filter {
            $0.accessibilityLabel == L("Jam transcript") || $0.accessibilityLabel == L("Chat message")
        }
        XCTAssertEqual(reading.count, 2)
        for index in 0..<modes.numberOfSegments {
            modes.selectedSegmentIndex = index
            modes.sendActions(for: .valueChanged)
            for text in reading {
                XCTAssertTrue(descendants(MeetingChromeSurface.self, in: text).isEmpty,
                              "Glass must not blur reading or editing content")
                XCTAssertEqual(text.backgroundColor?.resolvedColor(with: panel.traitCollection).cgColor.alpha, 1)
            }
        }
    }

    private func descendants<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
    }
}

@MainActor
private final class ChromeUpdateState: ObservableObject {
    @Published var count = 0
}

private struct UpdatingChrome: View {
    @ObservedObject var state: ChromeUpdateState
    var rendered: (Int) -> Void
    var body: some View {
        Text("Joining in \(state.count)")
            .padding(12)
            .background(ControlChromeBackground(cornerRadius: 20))
            .background(ChromeUpdateProbe(count: state.count, rendered: rendered))
    }
}

private struct ChromeUpdateProbe: UIViewRepresentable {
    var count: Int
    var rendered: (Int) -> Void
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) { rendered(count) }
}
