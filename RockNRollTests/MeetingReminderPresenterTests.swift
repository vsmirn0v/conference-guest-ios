import ConferenceCore
import XCTest
@testable import RockNRoll

@MainActor final class MeetingReminderPresenterTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func fixture(width: CGFloat = 390, height: CGFloat = 844) -> (UIWindow, MeetingReminderHost, MeetingAccessControls) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        let access = MeetingAccessControls(); access.frame = CGRect(x: width - 248, y: height - 160, width: 240, height: 48)
        let toolbar = UIView(frame: CGRect(x: 8, y: height - 104, width: width - 16, height: 60))
        controller.view.addSubview(access); controller.view.addSubview(toolbar)
        access.reminderHost.bind(surface: controller.view, access: access, toolbar: toolbar, blocked: { false }, privateContent: { false })
        return (window, access.reminderHost, access)
    }
    private func coordinator() async -> CalendarReminderCoordinator {
        let prefs = UserDefaults(suiteName: "ReminderPresenter." + UUID().uuidString)!
        prefs.set(true, forKey: "calendarMeetings.enabled"); prefs.set(["work"], forKey: "calendarMeetings.selected")
        let coordinator = CalendarReminderCoordinator(preferences: prefs, storage: CalendarUIFixture.Storage(), notifications: NoNotifications())
        var events: [CalendarMeeting] = []
        for id in ["first", "second"] {
            var meeting = CalendarMeeting(id: id, seriesID: id, calendarID: "work", calendarTitle: "Work", title: "Private " + id,
                start: Date().addingTimeInterval(-180), end: Date().addingTimeInterval(1800))
            meeting.invitation = URL(string: "https://salutejazz.ru/calls/" + id)!; meeting.engine = .guest
            events.append(meeting)
        }
        await coordinator.setEnabled(true); coordinator.update(meetings: events, available: true)
        await coordinator.waitForReconciliation(); return coordinator
    }
    private func events(_ coordinator: CalendarReminderCoordinator) -> [ReminderForegroundEvent] {
        coordinator.repository.occurrences.map { .init(plan: .init(occurrence: $0, phase: .after,
            date: $0.start.addingTimeInterval(120)), scope: .anotherMeeting) }
    }
    func testCardDoesNotMoveControlsAndUncoveredTouchesPassThrough() async throws {
        let (window, host, access) = fixture(); defer { window.isHidden = true }
        let coordinator = await coordinator(), presenter = MeetingReminderPresenter()
        let before = access.frame, plans = events(coordinator)
        XCTAssertEqual(presenter.render(plans, host: host, coordinator: coordinator), Set(plans.map(\.id)))
        window.layoutIfNeeded(); XCTAssertEqual(access.frame, before)
        let overlay = try XCTUnwrap(descendants(window).first { $0.accessibilityIdentifier == "reminders.overlay" })
        XCTAssertNil(overlay.hitTest(CGPoint(x: 4, y: 4), with: nil), "Transparent overlay must not swallow meeting controls")
        let buttons = descendants(overlay).compactMap { $0 as? UIButton }.filter { !$0.isHidden }
        XCTAssertTrue(buttons.allSatisfy { $0.bounds.height >= 44 })
        let collapse = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "reminders.collapse" })
        collapse.sendActions(for: .touchUpInside)
        XCTAssertNotNil(access.moreButton.accessibilityValue)
        XCTAssertEqual(access.reminderActions.count, 1)
    }
    func testPrivacyAndHostReplacementRemoveOldSurfaceAndBadge() async throws {
        let (first, host, access) = fixture(width: 320, height: 568)
        let (second, next, _) = fixture(width: 800, height: 420)
        defer { first.isHidden = true; second.isHidden = true }
        let coordinator = await coordinator(), presenter = MeetingReminderPresenter(), plans = events(coordinator)
        host.privateContent = { true }
        _ = presenter.render(plans, host: host, coordinator: coordinator)
        let labels = descendants(first).compactMap { ($0 as? UILabel)?.text }
        XCTAssertTrue(labels.contains("Meeting reminder")); XCTAssertFalse(labels.contains("Private first"))
        _ = presenter.render(plans, host: next, coordinator: coordinator)
        XCTAssertFalse(descendants(first).contains { $0.accessibilityIdentifier == "reminders.overlay" })
        XCTAssertTrue(access.reminderActions.isEmpty)
        XCTAssertEqual(descendants(second).filter { $0.accessibilityIdentifier == "reminders.overlay" }.count, 1)
        _ = presenter.render([], host: next, coordinator: coordinator)
        XCTAssertFalse(descendants(second).contains { $0.accessibilityIdentifier == "reminders.overlay" })
    }
    func testObstructingPanelDoesNotMountOrConsume() async {
        let (window, host, _) = fixture(); defer { window.isHidden = true }
        let coordinator = await coordinator(), presenter = MeetingReminderPresenter()
        host.blocked = { true }
        XCTAssertTrue(presenter.render(events(coordinator), host: host, coordinator: coordinator).isEmpty)
        XCTAssertFalse(descendants(window).contains { $0.accessibilityIdentifier == "reminders.overlay" })
    }

    func testProductionNativeAndGuestHostsMountOnActualControlSurface() async throws {
        for guest in [false, true] {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            let controller: UIViewController = guest ? GuestCallLayoutFixture() : RockCallViewController(title: "Current", catchUp: CatchUpStore(), chat: ChatStore())
            window.rootViewController = controller; window.makeKeyAndVisible(); window.layoutIfNeeded(); controller.view.layoutIfNeeded()
            let host = guest ? (controller as? GuestCallLayoutFixture)?.reminderHostForTesting : (controller as? RockCallViewController)?.reminderHost
            let endpoint = try XCTUnwrap(host)
            XCTAssertNotNil(endpoint.surface?.window); XCTAssertNotNil(endpoint.access?.window)
            let owner = await coordinator(), presenter = MeetingReminderPresenter(), plans = events(owner)
            XCTAssertEqual(presenter.render(plans, host: endpoint, coordinator: owner).count, 2)
            XCTAssertTrue(descendants(window).contains { $0.accessibilityIdentifier == "reminders.overlay" })
            presenter.backgrounded(); _ = presenter.render([], host: endpoint, coordinator: owner)
            _ = presenter.render(plans, host: endpoint, coordinator: owner)
            let open = descendants(window).first { $0.accessibilityIdentifier == "reminders.view" }
            XCTAssertTrue(open?.superview?.superview?.isHidden == true, "A return restores compact access rather than expanding again")
            XCTAssertEqual(descendants(window).first { $0.accessibilityIdentifier == "reminders.overlay" }?.overrideUserInterfaceStyle, .dark)
            window.isHidden = true; previous?.makeKey()
        }
    }

    func testCardAreasNeverIntersectRetainedControlsAtAccessibilitySizes() {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 568, height: 320), CGSize(width: 390, height: 844), CGSize(width: 1024, height: 768)] {
            for large in [false, true] {
                let bounds = CGRect(origin: .zero, size: size)
                let base = CallPresentationGeometry(bounds: bounds, insets: .zero, headerHeight: 80, toolbarHeight: large ? 100 : 60,
                    hidden: false, largeText: large, floating: true)
                let access = MeetingAccessGeometry(base: base, bounds: bounds, insets: .zero,
                    accessSize: CGSize(width: 240, height: large ? 96 : 48), largeText: large)
                let safe = bounds.insetBy(dx: 12, dy: 8)
                for area in MeetingReminderGeometry.freeAreas(in: safe, controls: [access.access, access.toolbar]) where !area.isEmpty {
                    XCTAssertFalse(area.intersects(access.access)); XCTAssertFalse(area.intersects(access.toolbar))
                }
            }
        }
    }

    func testStartingLocalCaptureRefreshesPrivacyWithoutAnotherCalendarOrLayoutEvent() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let call = RockCallViewController(title: "Current", catchUp: CatchUpStore(), chat: ChatStore())
        window.rootViewController = call; window.makeKeyAndVisible(); window.layoutIfNeeded(); call.view.layoutIfNeeded()
        defer { window.isHidden = true; previous?.makeKey() }
        let owner = await coordinator(), presenter = MeetingReminderPresenter()
        owner.scene = { .init(visible: true, room: MeetingRoomIdentity(URL(string: "https://salutejazz.ru/calls/current")!, engine: .guest)) }
        owner.onPresentation = { [weak owner, weak presenter, weak call] events in
            guard let owner, let presenter else { return [] }
            return presenter.render(events, host: call?.reminderHost, coordinator: owner)
        }
        owner.refreshPresentation()
        XCTAssertTrue(descendants(window).compactMap { ($0 as? UILabel)?.text }.contains("Private first"))
        call.setSharing(true)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        let labels = descendants(window).compactMap { ($0 as? UILabel)?.text }
        XCTAssertTrue(labels.contains("Meeting reminder")); XCTAssertFalse(labels.contains("Private first"))
    }
    func testUnchangedCallLayoutDoesNotScheduleRepeatedCoordinatorWork() async {
        let (window, host, access) = fixture(); defer { window.isHidden = true }
        var changes = 0; host.onChange = { changes += 1 }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        changes = 0
        for _ in 0..<20 {
            host.bind(surface: window.rootViewController!.view, access: access, toolbar: host.toolbar!, blocked: { false }, privateContent: { false })
        }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(changes, 0)
    }

    func testDeferredCardResumesAfterProgrammaticParticipantsDismissalWithoutGeometryChange() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        let call = RockCallViewController(title: "Current", catchUp: CatchUpStore(), chat: ChatStore())
        window.rootViewController = call; window.makeKeyAndVisible(); window.layoutIfNeeded(); call.view.layoutIfNeeded()
        defer { window.isHidden = true; previous?.makeKey() }
        let button = try XCTUnwrap(descendants(call.view).compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == L("Musicians") })
        button.sendActions(for: .touchUpInside)
        for _ in 0..<100 where call.presentedViewController?.isBeingPresented != false { try await Task.sleep(for: .milliseconds(10)) }
        let panel = try XCTUnwrap(call.presentedViewController)
        let bounds = call.view.bounds
        let owner = await coordinator(), presenter = MeetingReminderPresenter()
        owner.scene = { .init(visible: true, room: MeetingRoomIdentity(URL(string: "https://salutejazz.ru/calls/current")!, engine: .guest)) }
        owner.onPresentation = { [weak owner, weak presenter, weak call] events in
            guard let owner, let presenter else { return [] }
            return presenter.render(events, host: call?.reminderHost, coordinator: owner)
        }
        owner.refreshPresentation()
        XCTAssertTrue(owner.repository.states.values.allSatisfy { $0.presentation == nil })
        await withCheckedContinuation { continuation in panel.dismiss(animated: true) { continuation.resume() } }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(call.view.bounds, bounds)
        XCTAssertTrue(owner.repository.states.values.contains { $0.presentation != nil })
        XCTAssertTrue(descendants(window).contains { $0.accessibilityIdentifier == "reminders.collapse" })
    }

    func testReminderBadgeKeepsMoreTitleAndSizeStable() {
        let (window, _, access) = fixture(); defer { window.isHidden = true }
        let before = access.fittingSize(availableWidth: 320)
        for count in [0, 1, 12, 0] {
            access.setReminderBadge(count)
            XCTAssertEqual(access.moreButton.configuration?.title, L("More"))
            XCTAssertEqual(access.fittingSize(availableWidth: 320), before)
            XCTAssertEqual(access.moreButton.accessibilityValue == nil, count == 0)
        }
    }
    func testMoreWidthIncludesAccessibilitySymbolMetricsBeforeBadgeAppears() {
        let (window, _, access) = fixture(width: 667, height: 375); defer { window.isHidden = true }
        let parent = window.rootViewController!, child = UIViewController()
        parent.addChild(child); parent.view.addSubview(child.view); child.view.addSubview(access); child.didMove(toParent: parent)
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            parent.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: category), forChild: child)
            let before = access.fittingSize(availableWidth: 600)
            access.frame = CGRect(origin: .zero, size: before); access.layoutIfNeeded()
            let moreFrame = access.moreButton.frame
            for count in [0, 1, 12, 0] {
                access.setReminderBadge(count); access.layoutIfNeeded()
                XCTAssertEqual(access.fittingSize(availableWidth: 600), before)
                XCTAssertEqual(access.moreButton.frame, moreFrame)
                let content = access.moreButton.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 48))
                XCTAssertGreaterThanOrEqual(access.moreButton.bounds.width, ceil(content.width))
                if let label = access.moreButton.titleLabel {
                    XCTAssertGreaterThanOrEqual(label.bounds.width + 0.5,
                        label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 48)).width)
                } else { XCTFail("More must retain its full title") }
            }
        }
    }
    private final class NoNotifications: ReminderNotifying {
        func authorization() -> ReminderAuthorization { .allowed }
        func request(sensitive: Bool) -> Bool { true }
        func pending() -> [String: String] { [:] }
        func add(_ reminder: ReminderNotification) {}
        func removePending(_ ids: [String]) {}
        func removeDelivered(occurrenceIDs: Set<String>) {}
        func removeAllDelivered() {}
    }
}
