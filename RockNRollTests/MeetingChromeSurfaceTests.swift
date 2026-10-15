import AVKit
import ReplayKit
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class MeetingChromeSurfaceTests: XCTestCase {
    private let accessible = MeetingChromeSurface.AccessibilityState(
        reduceTransparency: false, increaseContrast: false, reduceMotion: false)

    func testGlassBackingIsRetainedAcrossLayoutAndStateUpdates() throws {
        try requireGlass()
        let surface = MeetingChromeSurface(accessibilityState: { self.accessible })
        surface.frame = CGRect(x: 0, y: 0, width: 304, height: 68)
        surface.layoutIfNeeded()
        let effectView = try XCTUnwrap(surface.subviews.first as? UIVisualEffectView)
        let effect = try XCTUnwrap(effectView.effect)
        let layers = surface.layer.sublayers?.map(ObjectIdentifier.init)
        XCTAssertFalse(effectView.isUserInteractionEnabled)
        if #available(iOS 26.0, *) {
            XCTAssertFalse(try XCTUnwrap(effect as? UIGlassEffect).isInteractive)
        }
        for index in 0..<250 {
            surface.frame.size.width = index.isMultiple(of: 2) ? 304 : 520
            surface.setNeedsLayout(); surface.layoutIfNeeded()
            NotificationCenter.default.post(name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        }
        XCTAssertEqual(surface.subviews.count, 1)
        XCTAssertTrue(surface.subviews.first === effectView)
        // UIKit copies effect values; the backing view and layers must stay retained.
        XCTAssertEqual(surface.layer.sublayers?.map(ObjectIdentifier.init), layers)
        if #available(iOS 26.0, *) {
            XCTAssertFalse(try XCTUnwrap(effectView.effect as? UIGlassEffect).isInteractive)
        }
        XCTAssertEqual(effectView.frame, surface.bounds)
        XCTAssertFalse(surface.isUserInteractionEnabled)
        XCTAssertTrue(surface.accessibilityElementsHidden)
    }

    func testAccessibilitySettingsSelectSolidAndRestoreRetainedGlassBacking() throws {
        try requireGlass()
        var state = accessible
        let surface = MeetingChromeSurface(accessibilityState: { state })
        let glass = try XCTUnwrap(surface.subviews.first as? UIVisualEffectView)
        let states: [(MeetingChromeSurface.AccessibilityState, Notification.Name)] = [
            (.init(reduceTransparency: true, increaseContrast: false, reduceMotion: false), UIAccessibility.reduceTransparencyStatusDidChangeNotification),
            (.init(reduceTransparency: false, increaseContrast: true, reduceMotion: false), UIAccessibility.darkerSystemColorsStatusDidChangeNotification),
            (.init(reduceTransparency: false, increaseContrast: false, reduceMotion: true), UIAccessibility.reduceMotionStatusDidChangeNotification)
        ]
        for (restricted, notification) in states {
            state = restricted
            NotificationCenter.default.post(name: notification, object: nil)
            XCTAssertTrue(glass.isHidden)
            XCTAssertEqual(surface.backgroundColor, MeetingChromeSurface.toolbarFallbackColor)
            state = accessible
            NotificationCenter.default.post(name: notification, object: nil)
            XCTAssertFalse(glass.isHidden)
            XCTAssertEqual(surface.backgroundColor, .clear)
            XCTAssertTrue(surface.subviews.first === glass)
            if #available(iOS 26.0, *) {
                XCTAssertFalse(try XCTUnwrap(glass.effect as? UIGlassEffect).isInteractive)
            }
            XCTAssertEqual(surface.subviews.count, 1)
        }
    }

    func testFallbackIsLazyOpaqueAndRetainsReadableDarkMeetingAppearance() throws {
        var state = accessible
        state.reduceTransparency = true
        let surface = MeetingChromeSurface(accessibilityState: { state })
        XCTAssertTrue(surface.subviews.isEmpty, "An inaccessible effect need not be allocated")
        XCTAssertEqual(surface.backgroundColor, MeetingChromeSurface.toolbarFallbackColor)
        XCTAssertGreaterThan(contrast(.white, MeetingChromeSurface.toolbarFallbackColor), 7)
        let toolbar = CallToolbar(items: actions())
        XCTAssertEqual(toolbar.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(surface.overrideUserInterfaceStyle, .unspecified, "Studio can inherit the system appearance")
        state = accessible
        NotificationCenter.default.post(name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
        if #available(iOS 26.0, *), ProcessInfo.processInfo.environment["MEETING_CHROME_SOLID"] != "1" {
            XCTAssertEqual(surface.subviews.count, 1)
        } else {
            XCTAssertTrue(surface.subviews.isEmpty)
            XCTAssertEqual(surface.backgroundColor, MeetingChromeSurface.toolbarFallbackColor)
        }
    }

    func testToolbarKeepsSixTargetsFramesCaptionsAndSymbolSlotsAt320PointsAndLargeText() {
        let buttons = actions()
        let toolbar = CallToolbar(items: buttons)
        let parent = UIViewController(), host = UIViewController()
        parent.addChild(host); parent.view.addSubview(host.view); host.didMove(toParent: parent)
        host.view.addSubview(toolbar)
        parent.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge), forChild: host)
        for (size, large) in [(CGSize(width: 320, height: 568), false), (CGSize(width: 568, height: 320), false),
                              (CGSize(width: 320, height: 568), true), (CGSize(width: 568, height: 320), true)] {
            toolbar.largeText = large
            let geometry = CallPresentationGeometry(bounds: CGRect(origin: .zero, size: size), insets: .zero,
                headerHeight: large ? 140 : 80, toolbarHeight: toolbar.preferredHeight, hidden: false, largeText: large)
            toolbar.frame = geometry.toolbar
            toolbar.arrange(rail: geometry.rail, largeText: large)
            toolbar.setNeedsLayout(); toolbar.layoutIfNeeded()
            let columns = geometry.rail ? (large ? 2 : 1) : large ? 2 : buttons.count
            let rows = (buttons.count + columns - 1) / columns
            let area = toolbar.bounds.insetBy(dx: 4, dy: 5)
            for (index, button) in buttons.enumerated() {
                let expected = CGRect(x: area.minX + CGFloat(index % columns) * area.width / CGFloat(columns),
                    y: area.minY + CGFloat(index / columns) * area.height / CGFloat(rows),
                    width: area.width / CGFloat(columns), height: area.height / CGFloat(rows)).insetBy(dx: 1, dy: 0)
                XCTAssertEqual(button.frame.minX, expected.minX, accuracy: 0.001)
                XCTAssertEqual(button.frame.minY, expected.minY, accuracy: 0.001)
                XCTAssertEqual(button.frame.width, expected.width, accuracy: 0.001)
                XCTAssertEqual(button.frame.height, expected.height, accuracy: 0.001)
                XCTAssertGreaterThanOrEqual(button.bounds.width, 44)
                XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
                XCTAssertTrue(toolbar.bounds.contains(button.frame))
                XCTAssertEqual(button.showsCaption, !geometry.rail || large)
                button.layoutIfNeeded()
                let symbol = button.subviews.compactMap { $0 as? UIImageView }.first { $0.bounds.size == CGSize(width: 26, height: 26) }
                XCTAssertNotNil(symbol, "The existing 26-point optical symbol slot must remain")
                XCTAssertEqual(button.configuration?.title, ["Mic", "Video", "Share", "Audio", "Reactions", "Leave"][index])
                XCTAssertEqual(button.configuration?.baseForegroundColor, .white)
            }
            XCTAssertEqual(toolbar.subviews.compactMap { $0 as? MeetingChromeSurface }.count, 1)
            XCTAssertEqual(toolbar.subviews.compactMap { $0 as? AlignedCallButton }, buttons)
            XCTAssertFalse(geometry.stage.intersects(geometry.toolbar), "Video stays outside the dock")
        }
    }

    func testMaskedNativePickersRetainHitTargetsAndAccessibilityAcrossResize() throws {
        for picker in [AVRoutePickerView(), RPSystemBroadcastPickerView()] as [UIView] {
            let container = UIView(frame: CGRect(x: 0, y: 0, width: 52, height: 58))
            let surface = MeetingChromeSurface()
            surface.frame = container.bounds; container.addSubview(surface)
            picker.frame = container.bounds; container.addSubview(picker)
            picker.accessibilityLabel = "System picker"
            let interaction = picker.isUserInteractionEnabled
            MeetingChromeSurface.hidePickerArtwork(in: picker)
            let mask = try XCTUnwrap(picker.layer.mask)
            let appearance = AlignedCallButton(frame: container.bounds)
            appearance.isUserInteractionEnabled = false
            appearance.accessibilityElementsHidden = true
            container.addSubview(appearance)
            for size in [CGSize(width: 52, height: 58), CGSize(width: 140, height: 90)] {
                container.frame.size = size; picker.frame = container.bounds; appearance.frame = container.bounds
                container.layoutIfNeeded(); picker.layoutIfNeeded()
                let hit = try XCTUnwrap(container.hitTest(CGPoint(x: container.bounds.midX, y: container.bounds.midY), with: nil))
                XCTAssertTrue(hit === picker || hit.isDescendant(of: picker))
                XCTAssertTrue(picker.layer.mask === mask)
                XCTAssertEqual(mask.opacity, 0)
                XCTAssertEqual(picker.isUserInteractionEnabled, interaction)
                XCTAssertFalse(picker.accessibilityElementsHidden)
                XCTAssertEqual(picker.accessibilityLabel, "System picker")
                XCTAssertEqual(picker.alpha, 1)
                XCTAssertFalse(picker.isHidden)
            }
        }
    }

    func testArtworkMaskSuppressesRenderingWithoutSuppressingActions() throws {
        let background = UIView(frame: CGRect(x: 0, y: 0, width: 52, height: 58))
        background.backgroundColor = .green
        let picker = UIButton(type: .custom)
        picker.backgroundColor = .red
        var actions = 0
        picker.addAction(UIAction { _ in actions += 1 }, for: .touchUpInside)
        background.addSubview(picker)
        MeetingChromeSurface.hidePickerArtwork(in: picker)
        let mask = picker.layer.mask
        for size in [CGSize(width: 52, height: 58), CGSize(width: 140, height: 90)] {
            background.frame.size = size; picker.frame = background.bounds
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.preferredRange = .standard
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let image = renderer.image { background.layer.render(in: $0.cgContext) }
            let pixel = try XCTUnwrap(image.cgImage?.dataProvider?.data)
            let bytes = try XCTUnwrap(CFDataGetBytePtr(pixel))
            // The fully transparent mask leaves the green backing visible.
            XCTAssertGreaterThan(bytes[1], 240)
            XCTAssertEqual(background.hitTest(CGPoint(x: 10, y: 10), with: nil), picker)
            picker.sendActions(for: .touchUpInside)
            XCTAssertTrue(picker.layer.mask === mask)
        }
        XCTAssertEqual(actions, 2)
    }

    func testBothCallImplementationsKeepPickerOverlaysClear() throws {
        let native = RockCallViewController(title: "Meeting", catchUp: CatchUpStore(), chat: ChatStore())
        native.loadViewIfNeeded()
        let guest = CallControls(localPreview: LocalSharePreview(), state: nil, coordinator: nil,
            router: nil, catchUp: CatchUpStore(), chat: ChatStore(), initialDisplayMode: .all,
            invitationURL: nil, roomIdentifier: "fixture", onDisplayMode: { _ in }, onFloat: {},
            onFloatingPreferenceChanged: {}, onLeave: {}, onScreenShare: { _ in },
            onMicrophoneState: { _ in }, onCameraState: { _ in })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true }
        guest.frame = host.view.bounds; host.view.addSubview(guest)
        for root in [native.view!, host.view!] {
            let toolbar = try XCTUnwrap(descendants(root).compactMap { $0 as? CallToolbar }.first)
            let items = toolbar.subviews.filter { !($0 is MeetingChromeSurface) }
            XCTAssertEqual(items.count, 6)
            let route = items[3]
            let artwork = try XCTUnwrap(route.subviews.compactMap { $0 as? AlignedCallButton }.first)
            XCTAssertEqual(artwork.backgroundColor?.cgColor.alpha ?? 0, 0)
            XCTAssertFalse(artwork.isUserInteractionEnabled)
            XCTAssertTrue(artwork.accessibilityElementsHidden)
            XCTAssertTrue(route.subviews.contains { $0.layer.mask?.opacity == 0 })
        }
        let broadcast = try XCTUnwrap(descendants(native.view).compactMap { $0 as? RPSystemBroadcastPickerView }.first)
        XCTAssertEqual(broadcast.layer.mask?.opacity, 0)
        let broadcastArtwork = try XCTUnwrap(broadcast.superview?.subviews.compactMap { $0 as? AlignedCallButton }.last)
        XCTAssertEqual(broadcastArtwork.backgroundColor?.cgColor.alpha ?? 0, 0)
    }

    func testNativeMacAudioButtonPresentsActualDevicePicker() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac else { throw XCTSkip("Mac audio picker") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let call = RockCallViewController(title: "Audio picker qualification", catchUp: CatchUpStore(), chat: ChatStore())
        window.rootViewController = call; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let route = try XCTUnwrap(descendants(call.view).compactMap { $0 as? MacAudioRouteButton }.first)
        XCTAssertEqual(route.layer.mask?.opacity, 0)
        route.sendActions(for: .touchUpInside)
        for _ in 0..<100 where call.presentedViewController == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let navigation = try XCTUnwrap(call.presentedViewController as? UINavigationController)
        let picker = try XCTUnwrap(navigation.topViewController as? MacAudioDevicePicker)
        picker.loadViewIfNeeded(); picker.tableView.layoutIfNeeded()
        for _ in 0..<100 where navigation.isBeingPresented || picker.view.window == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(navigation.isBeingPresented)
        XCTAssertNotNil(picker.view.window)
        XCTAssertFalse(picker.tableView.visibleCells.isEmpty)
        XCTAssertEqual(picker.tableView.numberOfSections, 2)
        XCTAssertGreaterThan(picker.tableView.numberOfRows(inSection: 0), 0)
        XCTAssertGreaterThan(picker.tableView.numberOfRows(inSection: 1), 0)
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        })
        attachment.name = "Native Mac audio picker from masked control"
        attachment.lifetime = .keepAlways; add(attachment)
        navigation.dismiss(animated: false)
    }

    /// Run twice with MEETING_CHROME_PROFILE=1, then with MEETING_CHROME_SOLID=1.
    /// This measures host-side state/layout work; compositor cost needs Instruments.
    func testOptInToolbarStateAndLayoutProfile() throws {
        guard ProcessInfo.processInfo.environment["MEETING_CHROME_PROFILE"] == "1" else {
            throw XCTSkip("Opt in with MEETING_CHROME_PROFILE=1")
        }
        let buttons = actions()
        let toolbar = CallToolbar(items: buttons)
        toolbar.frame = CGRect(x: 0, y: 0, width: 304, height: 68)
        var batches: [TimeInterval] = []
        for batch in 0..<11 {
            let start = ProcessInfo.processInfo.systemUptime
            for index in 0..<1_000 {
                for button in buttons { button.isEnabled = index.isMultiple(of: 2) }
                toolbar.setNeedsLayout(); toolbar.layoutIfNeeded()
            }
            if batch > 0 { batches.append(ProcessInfo.processInfo.systemUptime - start) }
        }
        let total = batches.reduce(0, +)
        let solid = ProcessInfo.processInfo.environment["MEETING_CHROME_SOLID"] == "1"
        print("MEETING_CHROME_PROFILE solid=\(solid) iterations=10000 total_ms=\(total * 1000) min_batch_ms=\((batches.min() ?? 0) * 1000) mean_us=\(total * 100)")
    }

    private func requireGlass() throws {
        guard #available(iOS 26.0, *), ProcessInfo.processInfo.environment["MEETING_CHROME_SOLID"] != "1" else {
            throw XCTSkip("Native glass requires iOS 26 and an unforced appearance")
        }
    }

    private func actions() -> [AlignedCallButton] {
        ["Mic", "Video", "Share", "Audio", "Reactions", "Leave"].map { title in
            let button = AlignedCallButton(frame: .zero)
            button.configuration = .plain()
            button.configuration?.title = title
            button.configuration?.image = UIImage(systemName: "circle")
            button.configuration?.baseForegroundColor = .white
            return button
        }
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    private func contrast(_ foreground: UIColor, _ background: UIColor) -> CGFloat {
        func luminance(_ color: UIColor) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        return (luminance(foreground) + 0.05) / (luminance(background) + 0.05)
    }
}
