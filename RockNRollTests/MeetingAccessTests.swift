import ConferenceCore
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class MeetingAccessTests: XCTestCase {
    func testAllLayoutsAndFiltersKeepIndependentPreferenceAndHonestLabels() {
        for layout in MeetingLayoutMode.allCases {
            for display in ConferenceDisplayMode.allCases {
                let state = MeetingViewState(layout: layout, display: display, manualFocus: true)
                XCTAssertEqual(state.layout, layout)
                XCTAssertEqual(state.permitsLayout, display != .audioOnly)
                XCTAssertEqual(state.title, display == .audioOnly ? L("Audio only") : display == .screenShares ? L("Shares only") : layout.title)
            }
        }
    }

    func testAdaptiveDockTargetsFitAndDoNotOverlapInEveryWindowShape() {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 375, height: 667),
                     CGSize(width: 440, height: 956), CGSize(width: 956, height: 440),
                     CGSize(width: 667, height: 375), CGSize(width: 768, height: 1024),
                     CGSize(width: 1200, height: 800)] {
            for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
                let bounds = CGRect(origin: .zero, size: size)
                let traits = UITraitCollection(preferredContentSizeCategory: category)
                let host = UIViewController()
                let child = UIViewController()
                host.addChild(child); host.view.addSubview(child.view)
                host.setOverrideTraitCollection(traits, forChild: child)
                let controls = MeetingAccessControls()
                child.view.addSubview(controls)
                let large = category.isAccessibilityCategory
                let buttons = (0..<6).map { _ in AlignedCallButton() }
                let toolbar = CallToolbar(items: buttons)
                toolbar.arrange(rail: false, largeText: large)
                let base = CallPresentationGeometry(bounds: bounds, insets: .zero, headerHeight: 80,
                    toolbarHeight: toolbar.preferredHeight, hidden: false, largeText: large, floating: true)
                let geometry = MeetingAccessGeometry(base: base, bounds: bounds, insets: .zero,
                    accessSize: controls.fittingSize(availableWidth: base.rail ? base.stage.width : base.toolbar.width), largeText: large)
                controls.frame = geometry.access; controls.layoutIfNeeded()
                toolbar.frame = geometry.toolbar
                toolbar.arrange(rail: base.rail, largeText: large)
                toolbar.separatesLast = geometry.inline
                toolbar.inlineAccessWidth = geometry.inline ? geometry.access.width + 8 : 0
                toolbar.layoutIfNeeded()
                XCTAssertTrue(bounds.contains(geometry.access), "\(size), \(category)")
                XCTAssertFalse(geometry.stage.intersects(geometry.access))
                for button in [controls.viewButton, controls.moreButton] {
                    XCTAssertGreaterThanOrEqual(button.bounds.width, 44)
                    XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
                }
                XCTAssertFalse(controls.viewButton.frame.intersects(controls.moreButton.frame))
                for button in buttons {
                    XCTAssertGreaterThanOrEqual(button.bounds.width, 44, "\(size), \(category)")
                    XCTAssertGreaterThanOrEqual(button.bounds.height, 44, "\(size), \(category)")
                    let rect = button.frame.offsetBy(dx: toolbar.frame.minX, dy: toolbar.frame.minY)
                    XCTAssertFalse(rect.intersects(geometry.access), "Capsule must not cover a primary action")
                }
                let before = controls.moreButton.frame
                for mode in ConferenceDisplayMode.allCases {
                    controls.update(MeetingViewState(layout: .grid, display: mode)); controls.layoutIfNeeded()
                    XCTAssertEqual(controls.moreButton.frame, before)
                    XCTAssertEqual(controls.viewButton.accessibilityValue, L("Layout: %@", L("Gallery")))
                }
            }
        }
    }

    func testRetiredOrUnmountedCallRejectsDeferredActions() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true }
        let anchor = UIButton(); host.view.addSubview(anchor)
        let owner = MeetingPanelOwner(), current = owner.validity(from: anchor)
        XCTAssertTrue(current())
        owner.invalidate()
        XCTAssertFalse(current())
        let next = owner.validity(from: anchor)
        XCTAssertTrue(next())
        anchor.removeFromSuperview()
        XCTAssertFalse(next())
        host.view.addSubview(anchor)
        owner.retire()
        XCTAssertFalse(owner.validity(from: anchor)(), "A retired call cannot start a new panel generation")
    }

    func testPresentedViewRetiresBeforeWindowDetachesAndRejectsItsQueuedChoice() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        let anchor = UIButton(frame: CGRect(x: 16, y: 400, width: 100, height: 48))
        host.view.addSubview(anchor)
        let owner = MeetingPanelOwner()
        defer { owner.invalidate(); window.isHidden = true; previous?.makeKey() }
        var changes = 0
        MeetingActionsController.showView(state: .init(layout: .grid, display: .all), from: anchor, owner: owner,
            chooseLayout: { _ in changes += 1 }, chooseDisplay: { _ in changes += 1 },
            followSpeaker: { changes += 1 }, onVisibilityChanged: { _ in })
        await waitUntil { host.presentedViewController != nil && host.presentedViewController?.isBeingPresented == false }
        let panel = try XCTUnwrap(owner.controller as? MeetingActionsController)
        panel.dismissAndPerform { changes += 1 }
        owner.retire()
        XCTAssertNotNil(anchor.window, "Retirement must work before SDK overlays detach")
        await waitUntil { host.presentedViewController == nil }
        XCTAssertEqual(changes, 0)
        XCTAssertNil(host.presentedViewController)
        MeetingActionsController.showView(state: .init(layout: .grid, display: .all), from: anchor, owner: owner,
            chooseLayout: { _ in changes += 1 }, chooseDisplay: { _ in changes += 1 },
            followSpeaker: { changes += 1 }, onVisibilityChanged: { _ in })
        XCTAssertNil(host.presentedViewController, "Retired calls must not reopen tools while their anchor remains mounted")
    }

    func testDirectToolsOpenWithoutPublishingOrChangingSubscriptions() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let call = RockCallViewController(title: "Access QA", catchUp: CatchUpStore(), chat: ChatStore())
        window.rootViewController = call; window.makeKeyAndVisible()
        defer { call.dismiss(animated: false); window.isHidden = true; call.endFloatingVideo(); previous?.makeKey() }
        window.layoutIfNeeded(); call.view.layoutIfNeeded()
        var changes = 0
        let demand = call.visibleVideoQualities(foreground: true, wantsVideo: true)
        call.onVideoDemandChanged = {
            if call.visibleVideoQualities(foreground: true, wantsVideo: true) != demand { changes += 1 }
        }
        call.onMicrophone = { _ in changes += 1 }
        call.onCamera = { _ in changes += 1 }
        call.onDisplayMode = { _ in changes += 1 }
        let controls = try XCTUnwrap(descendants(call.view).compactMap { $0 as? MeetingAccessControls }.first)
        let scroll = try XCTUnwrap(descendants(call.view).compactMap { $0 as? UIScrollView }.first)
        for button in [controls.moreButton, controls.viewButton] {
            let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: window)
            let hit = try XCTUnwrap(window.hitTest(point, with: nil))
            XCTAssertTrue(hit === button || hit.isDescendant(of: button), "Direct tool is covered in the mounted window")
            button.sendActions(for: .touchUpInside)
            await waitUntil { call.presentedViewController != nil && call.presentedViewController?.isBeingPresented == false }
            XCTAssertNotNil(call.presentedViewController)
            XCTAssertEqual(changes, 0)
            XCTAssertTrue(descendants(call.view).contains { $0 === scroll })
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = button === controls.moreButton ? "Native More panel" : "Native View panel"
            attachment.lifetime = .keepAlways; add(attachment)
            call.dismiss(animated: false)
            await waitUntil { call.presentedViewController == nil }
        }
    }

    func testCallCanRetireDuringPanelPresentation() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        let anchor = UIButton(frame: CGRect(x: 16, y: 100, width: 100, height: 48))
        host.view.addSubview(anchor)
        let owner = MeetingPanelOwner()
        defer { owner.retire(); window.isHidden = true; previous?.makeKey() }
        MeetingActionsController.showView(state: .init(layout: .grid, display: .all), from: anchor, owner: owner,
            chooseLayout: { _ in XCTFail("Retired panel changed layout") },
            chooseDisplay: { _ in XCTFail("Retired panel changed subscriptions") },
            followSpeaker: { XCTFail("Retired panel changed pin") }, onVisibilityChanged: { _ in })
        XCTAssertNotNil(host.presentedViewController)
        owner.retire()
        await waitUntil { host.presentedViewController == nil }
        XCTAssertFalse(owner.validity(from: anchor)())
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "UIKit presentation did not settle", file: file, line: line)
    }
}
