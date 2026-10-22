import ConferenceCore
import AVFoundation
import CryptoKit
import Security
import UIKit
import WebRTC
import XCTest
@testable import RockNRoll

@MainActor
final class MacMeetingLiveTests: XCTestCase {
    func testOwnedScheduledQAPersistenceAudit() throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              ProcessInfo.processInfo.environment["ROCKNROLL_TEST_MAC_QA_AUDIT"] == "1",
              let raw = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_MAC_SCHEDULE_INVITE"],
              let invitation = URL(string: raw) else {
            throw XCTSkip("Opt-in read-only audit of the owned scheduled QA invitation")
        }
        let identity = invitation.absoluteString
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        guard digest == "e566d10a8f9cc7b185af5736bfe330dd20b8e3a08da32fc46d32d2598984872f" else {
            XCTFail("Audit is restricted to the recorded disposable QA invitation"); return
        }
        var audit: [String: Any] = ["cloudRecordID": "item-" + digest, "cloudInspected": false,
            "savedNameIsQA": UserDefaults.standard.string(forKey: "savedDisplayName") == "Hidden scheduled QA"]
        func read(_ service: String, label: String) -> Data? {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: "saved-rooms",
                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            audit[label + "Readable"] = status == errSecSuccess || status == errSecItemNotFound
            if status == errSecItemNotFound {
                audit[label + "Exists"] = false; audit[label + "ContainsQA"] = false
            } else if status == errSecSuccess {
                audit[label + "Exists"] = true
            }
            return status == errSecSuccess ? result as? Data : nil
        }
        if let data = read("dev.vsmirn0v.conferenceguest.room-history", label: "history") {
            let history = try? JSONDecoder().decode(RecentRooms.self, from: data)
            audit["historyDecoded"] = history != nil
            if let history { audit["historyContainsQA"] = history.items.contains { $0.id == identity } }
        }
        if let data = read("dev.vsmirn0v.conferenceguest.icloud-replica", label: "replica") {
            struct Replica: Decodable { let document: RoomSyncDocument }
            let replica = try? JSONDecoder().decode(Replica.self, from: data)
            audit["replicaDecoded"] = replica != nil
            if let replica {
                let room = replica.document.rooms[identity]
                audit["replicaContainsQA"] = room != nil
                audit["replicaQAVisible"] = room?.exists.value == true
            }
        }
        let data = try JSONSerialization.data(withJSONObject: audit, options: [.sortedKeys])
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mac-scheduled-qa-persistence-audit.json")
        try data.write(to: file, options: .atomic)
        print("MAC_SCHEDULED_QA_AUDIT \(String(decoding: data, as: UTF8.self))")
        for label in ["history", "replica"] {
            XCTAssertEqual(audit[label + "Readable"] as? Bool, true, "Keychain audit could not read \(label) without interaction")
            if audit[label + "Exists"] as? Bool == true {
                XCTAssertEqual(audit[label + "Decoded"] as? Bool, true, "Keychain audit could not decode \(label)")
            }
        }
    }

    func testRemoveOwnedScheduledQAThroughNormalSyncTombstone() throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              ProcessInfo.processInfo.environment["ROCKNROLL_TEST_MAC_QA_CLEANUP"] == "1",
              let raw = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_MAC_SCHEDULE_INVITE"],
              let invitation = URL(string: raw) else {
            throw XCTSkip("Opt-in cleanup of only the confirmed owned scheduled QA record")
        }
        let identity = invitation.absoluteString
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        guard digest == "e566d10a8f9cc7b185af5736bfe330dd20b8e3a08da32fc46d32d2598984872f" else {
            XCTFail("Cleanup is restricted to the recorded disposable QA invitation"); return
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let model = try XCTUnwrap((scene.delegate as? SceneDelegate)?.meetingForTesting)
        let originalSync = RoomSyncCoordinator.active
        let originalContinuation = MeetingContinuationCoordinator.active
        defer {
            RoomSyncCoordinator.active = originalSync
            MeetingContinuationCoordinator.active = originalContinuation
        }
        let sync = model.sync
        guard originalSync === sync, !model.desktopMeetingActive, !sync.busy,
              model.history.removedRoom == nil else {
            throw XCTSkip("Cleanup requires idle existing app owners and no pending history undo")
        }
        guard sync.storageWarning == nil, model.history.persistenceWarning == nil else {
            XCTFail("Resolve existing persistence errors before owned-record cleanup"); return
        }
        func read(_ service: String) throws -> Data {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: "saved-rooms",
                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return try XCTUnwrap(status == errSecSuccess ? result as? Data : nil,
                                 "Expected QA store is unavailable without interaction")
        }
        func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
            try XCTUnwrap(try? JSONDecoder().decode(type, from: data), "Expected QA store could not be decoded")
        }
        func unrelatedReplicaFields(_ data: Data) throws -> NSDictionary {
            var root = try XCTUnwrap(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            var document = try XCTUnwrap(root["document"] as? [String: Any])
            var rooms = try XCTUnwrap(document["rooms"] as? [String: Any])
            rooms.removeValue(forKey: identity)
            document["rooms"] = rooms
            document.removeValue(forKey: "counter") // The normal tombstone advances the document clock.
            root["document"] = document
            return root as NSDictionary
        }
        struct Replica: Decodable { let document: RoomSyncDocument }
        let historyService = "dev.vsmirn0v.conferenceguest.room-history"
        let replicaService = "dev.vsmirn0v.conferenceguest.icloud-replica"
        let beforeHistory = try decode(RecentRooms.self, read(historyService))
        let beforeReplicaData = try read(replicaService)
        let beforeReplica = try decode(Replica.self, beforeReplicaData)
        let beforeOtherReplica = try unrelatedReplicaFields(beforeReplicaData)
        let beforeName = UserDefaults.standard.object(forKey: "savedDisplayName") as? NSObject
        guard model.history.rooms == beforeHistory.items else {
            XCTFail("Existing history owner is stale; no cleanup performed"); return
        }
        let owned = try XCTUnwrap(beforeReplica.document.rooms[identity], "Expected owned replica record is missing")
        if beforeHistory.items.contains(where: { $0.id == identity }) || owned.exists.value {
            // No replacement stores, cloud toggles or raw Keychain writes: the
            // existing owner persists and schedules its ordinary sync tombstone.
            model.history.remove(invitation)
        }
        let afterHistory = try decode(RecentRooms.self, read(historyService))
        let afterReplicaData = try read(replicaService)
        let afterReplica = try decode(Replica.self, afterReplicaData)
        let audit: [String: Any] = ["cloudRecordID": "item-" + digest, "cloudInspected": false,
            "normalCloudSyncEnabled": sync.enabled,
            "historyContainsQA": afterHistory.items.contains { $0.id == identity },
            "replicaQATombstone": afterReplica.document.rooms[identity]?.exists.value == false,
            "otherHistoryUnchanged": beforeHistory.items.filter { $0.id != identity } == afterHistory.items.filter { $0.id != identity },
            "otherReplicaUnchanged": beforeOtherReplica.isEqual(try unrelatedReplicaFields(afterReplicaData)),
            "savedNameUnchanged": beforeName == UserDefaults.standard.object(forKey: "savedDisplayName") as? NSObject,
            "persistenceSucceeded": model.history.persistenceWarning == nil && sync.storageWarning == nil]
        let data = try JSONSerialization.data(withJSONObject: audit, options: [.sortedKeys])
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mac-scheduled-qa-cleanup.json")
        try data.write(to: file, options: .atomic)
        print("MAC_SCHEDULED_QA_CLEANUP \(String(decoding: data, as: UTF8.self))")
        XCTAssertEqual(audit["historyContainsQA"] as? Bool, false)
        for key in ["replicaQATombstone", "otherHistoryUnchanged", "otherReplicaUnchanged", "savedNameUnchanged", "persistenceSucceeded"] {
            XCTAssertEqual(audit[key] as? Bool, true, "Owned cleanup verification failed: \(key)")
        }
    }

    /// Real scheduler admission and transport; no mocked join callback. The
    /// calendar, history and sync replica are isolated; capture stays off.
    func testScheduledHiddenJoinReceivesDecodedMediaAndLeavesWhileHidden() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              let link = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_MAC_SCHEDULE_INVITE"],
              let invitation = URL(string: link) else {
            throw XCTSkip("Opt-in hidden scheduled join with a disposable synthetic media sender")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let delegate = try XCTUnwrap(scene.delegate as? SceneDelegate)
        let window = try XCTUnwrap(delegate.window)
        guard delegate.meetingForTesting?.desktopMeetingActive != true else {
            throw XCTSkip("Never replace an existing meeting for qualification")
        }
        let originalReminders = CalendarReminderBroker.shared.sharedCoordinator
        guard !originalReminders.hasOpenIntent, !CalendarReminderBroker.shared.hasPendingIntent else {
            throw XCTSkip("Never replace a pending reminder action for qualification")
        }
        let originalSync = RoomSyncCoordinator.active
        let originalContinuation = MeetingContinuationCoordinator.active
        delegate.macMeetingForTesting?.invalidate()
        let original = window.rootViewController
        let container = MeetingContainerViewController()
        container.mountHome(UIViewController())
        window.rootViewController = container; window.makeKeyAndVisible()
        let suite = "MacScheduledMedia-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(true, forKey: "calendarMeetings.enabled")
        preferences.set(["work"], forKey: "calendarMeetings.selected")
        preferences.set("Hidden scheduled QA", forKey: "savedDisplayName")
        let due = Date().addingTimeInterval(30)
        let event = CalendarMeeting(id: "scheduled-media", seriesID: "scheduled-media", calendarID: "work",
            calendarTitle: "Isolated qualification", title: "Scheduled media qualification", start: due,
            end: due.addingTimeInterval(120), links: [invitation])
        let detector = VendorEndpointResolver.makeDetector()
        let reminders = CalendarReminderCoordinator(preferences: preferences,
            storage: CalendarReminderTests.Storage(), notifications: CalendarReminderTests.Notifications())
        let calendar = CalendarMeetingStore(reader: CalendarMeetingStoreTests.Reader(events: [event]),
            detector: detector, preferences: preferences, storage: RoomSyncCoordinatorTests.Storage(), reminders: reminders)
        calendar.setAutomaticJoinMode(.scheduled)
        let model = ConferenceModel(history: RoomHistoryStore(storage: RoomSyncCoordinatorTests.Storage()),
            preferences: preferences, engineDetector: detector, calendar: calendar)
        model.installSyncFixture(RoomSyncCoordinator(history: model.history, name: model.displayName,
            preferences: preferences, storage: RoomSyncCoordinatorTests.Storage(),
            transport: RoomSyncCoordinatorTests.Cloud()))
        model.installContinuationFixture(model.makeContinuationCoordinator(preferences: preferences))
        var scheduledStartedAt: Date?
        let scheduledJoin = calendar.onScheduledJoin
        calendar.onScheduledJoin = { meeting in
            scheduledStartedAt = Date()
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(due), 0, "Admission must not occur early")
            scheduledJoin(meeting)
        }
        model.setup.suspendForMeeting(); model.configure(container: container)
        let desktop = MacMeetingCoordinator(model: model, window: window)
        defer {
            model.leave(); calendar.setEnabled(false); desktop.showForTesting(); desktop.invalidate()
            window.rootViewController = original
            RoomSyncCoordinator.active = originalSync
            MeetingContinuationCoordinator.active = originalContinuation
            CalendarReminderBroker.shared.attach(originalReminders)
            delegate.restoreMacMeetingForTesting()
            preferences.removePersistentDomain(forName: suite)
        }
        desktop.becameActive(); calendar.foregrounded(allowAutomaticJoin: false)
        for _ in 0..<100 where calendar.loading || desktop.stateForTesting["bound"] as? Bool != true {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(calendar.meetings.count, 1, "The real invitation must resolve before the start boundary")
        XCTAssertEqual(desktop.stateForTesting["schedulingAvailable"] as? Bool, true)
        XCTAssertTrue(desktop.hasScheduledActivityForTesting, "The finite preflight lease must be acquired")
        desktop.closeForTesting(); calendar.backgrounded()
        try await Task.sleep(for: .milliseconds(300))
        let frontmost = desktop.stateForTesting["frontmostPID"] as? Int
        XCTAssertEqual(desktop.stateForTesting["hidden"] as? Bool, true)
        XCTAssertNotEqual(frontmost, Int(getpid()))
        print("MAC_SCHEDULED_MEDIA_ARMED due=\(due) pid=\(getpid()) allowed=\(calendar.canAutomaticallyJoin(calendar.meetings.first ?? event)) preflight=\(desktop.hasScheduledActivityForTesting)")
        var lastTrace = Date.distantPast
        while !model.isInConference, !model.statusIsError, Date() < due.addingTimeInterval(20) {
            if Date().timeIntervalSince(lastTrace) > 2 {
                lastTrace = Date()
                print("MAC_SCHEDULED_TRACE t=\(Date().timeIntervalSince(due)) available=\(calendar.schedulingIsAvailable()) allowed=\(calendar.canAutomaticallyJoin(calendar.meetings.first ?? event)) countdown=\(String(describing: calendar.countdown)) enabled=\(calendar.scheduledJoiningEnabled) setup=\(model.setup.blocksAutomaticJoin) joining=\(model.isJoining)")
                fflush(stdout)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(model.isInConference, model.status)
        XCTAssertNotNil(scheduledStartedAt)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(due), 0, "Scheduled attendance must never start early")
        let engine = try XCTUnwrap(model.desktopEngine as? NativeConferenceEngine)
        XCTAssertEqual(desktop.stateForTesting["hidden"] as? Bool, true)
        XCTAssertEqual(desktop.stateForTesting["frontmostPID"] as? Int, frontmost)
        XCTAssertFalse(engine.studioForTesting.microphoneOn)
        XCTAssertFalse(engine.studioForTesting.cameraOn)
        XCTAssertFalse(desktop.hasScheduledActivityForTesting)
        func audioEnergy(_ rows: [[String: Any]]) -> Double {
            rows.filter { $0["type"] as? String == "inbound-rtp" && $0["kind"] as? String == "audio" }
                .reduce(0) { $0 + (($1["totalAudioEnergy"] as? NSNumber)?.doubleValue ?? 0) }
        }
        var before = await GuestMicrophoneProbe.codecEvidenceForTesting()
        for _ in 0..<100 where audioEnergy(before) == 0 {
            try await Task.sleep(for: .milliseconds(100))
            before = await GuestMicrophoneProbe.codecEvidenceForTesting()
        }
        XCTAssertGreaterThan(audioEnergy(before), 0, "Hidden attendance must decode non-silent remote audio")
        try await Task.sleep(for: .seconds(3))
        let after = await GuestMicrophoneProbe.codecEvidenceForTesting()
        XCTAssertGreaterThan(audioEnergy(after), audioEnergy(before))
        XCTAssertTrue(AVAudioSession.sharedInstance().currentRoute.outputs.count > 0)
        let rtcAudio = RTCAudioSession.sharedInstance()
        XCTAssertTrue(rtcAudio.isActive)
        // isAudioEnabled gates playout only when manual audio is selected.
        XCTAssertTrue(!rtcAudio.useManualAudio || rtcAudio.isAudioEnabled)
        print("MAC_SCHEDULED_AUDIO_MODE manual=\(rtcAudio.useManualAudio) enabled=\(rtcAudio.isAudioEnabled)")
        let outputSeconds = min(45, max(0, Double(ProcessInfo.processInfo.environment["ROCKNROLL_TEST_MAC_OUTPUT_SECONDS"] ?? "0") ?? 0))
        if outputSeconds > 0 {
            print("MAC_SCHEDULED_OUTPUT_READY pid=\(getpid())"); fflush(stdout)
            try await Task.sleep(for: .seconds(outputSeconds))
        }
        let session = model.desktopSessionToken
        desktop.showForTesting()
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(model.desktopSessionToken, session, "Opening must adopt the scheduled meeting")
        for _ in 0..<100 where !engine.hasReceivedVideoFrameForTesting {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(engine.hasReceivedVideoFrameForTesting)
        if ProcessInfo.processInfo.environment["ROCKNROLL_TEST_RENDERER_OWNERSHIP"] == "1" {
            try await qualifyDistinctPublisherPixels(engine.streamViewsForTesting)
        }
        desktop.closeForTesting(); model.leave()
        try await Task.sleep(for: .seconds(2))
        XCTAssertFalse(model.desktopMeetingActive)
        XCTAssertEqual(desktop.stateForTesting["hidden"] as? Bool, true)
        XCTAssertFalse(desktop.hasScheduledActivityForTesting)
        XCTAssertFalse(engine.hasJoinStarted)
        if outputSeconds > 0 {
            print("MAC_SCHEDULED_OUTPUT_LEFT pid=\(getpid())"); fflush(stdout)
            try await Task.sleep(for: .seconds(min(outputSeconds, 15)))
        }
        print("MAC_SCHEDULED_MEDIA_VERIFIED decodedEnergy=\(audioEnergy(after)) frontmostUnchanged=true microphoneOff=true cameraOff=true")
    }

    private func qualifyDistinctPublisherPixels(_ streams: GuestStreamViews) async throws {
        let previous = streams.onGalleryPresentation
        var items: [GuestStreamViews.GalleryItem] = []
        streams.onGalleryPresentation = { next in previous?(next); items = next }
        defer { streams.onGalleryPresentation = previous }
        streams.refreshSelection()
        for _ in 0..<100 where items.filter({ $0.name.hasPrefix("QA sender ") && $0.renderer != nil }).count < 2 {
            try await Task.sleep(for: .milliseconds(100))
        }
        let first = try XCTUnwrap(items.first { $0.name == "QA sender A" && !$0.id.isShare }?.renderer)
        let second = try XCTUnwrap(items.first { $0.name == "QA sender B" && !$0.id.isShare }?.renderer)
        XCTAssertFalse(first === second, "Different participant identities must not share a frame renderer")
        let a = expectation(description: "Red pixels belong to sender A")
        let b = expectation(description: "Blue pixels belong to sender B")
        a.assertForOverFulfill = false; b.assertForOverFulfill = false
        func tap(_ renderer: UIView, red: Bool, ready: XCTestExpectation) throws -> GuestVideoFrameTap {
            try XCTUnwrap(GuestVideoFrameTap(view: renderer) { frame in
                let pixels = frame.buffer.toI420()
                let row = Int(pixels.height / 4), column = Int(pixels.width / 4)
                let u = Int(pixels.dataU[row * Int(pixels.strideU) + column])
                let v = Int(pixels.dataV[row * Int(pixels.strideV) + column])
                if red ? u > v + 30 : v > u + 30 { XCTFail("A participant renderer delivered the other camera's pixels") }
                if red ? v > u + 30 : u > v + 30 { ready.fulfill() }
            })
        }
        let taps = try [tap(first, red: true, ready: a), tap(second, red: false, ready: b)]
        defer { taps.forEach { $0.invalidate() } }
        await fulfillment(of: [a, b], timeout: 12)
        try await Task.sleep(for: .seconds(3))
        print("MAC_RENDERER_BASELINE_VERIFIED publishers=2 distinctRenderers=true labeledColorFrames=true")
    }

    func testFreshProcessIdleMenuSchedulesWhileWindowIsHidden() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              let seconds = Double(ProcessInfo.processInfo.environment["ROCKNROLL_TEST_MAC_SCHEDULE_SECONDS"] ?? ""), seconds >= 5 else {
            throw XCTSkip("Opt-in fresh-process hidden calendar timing qualification")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = try XCTUnwrap((scene.delegate as? SceneDelegate)?.window)
        let preferences = UserDefaults(suiteName: "MacScheduleLive-" + UUID().uuidString)!
        preferences.set(true, forKey: "calendarMeetings.enabled"); preferences.set(["work"], forKey: "calendarMeetings.selected")
        let due = Date().addingTimeInterval(seconds)
        let event = CalendarMeeting(id: "native-idle", seriesID: "native-idle", calendarID: "work", calendarTitle: "QA",
            title: "Local calendar timing check", start: due, end: due.addingTimeInterval(60),
            links: [URL(string: "https://jazz.example.test/calls/room")!])
        let reader = CalendarMeetingStoreTests.Reader(events: [event])
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CalendarMeetingStoreTests.Response.self]
        let reminders = CalendarReminderCoordinator(preferences: preferences, storage: CalendarReminderTests.Storage(), notifications: CalendarReminderTests.Notifications())
        let calendar = CalendarMeetingStore(reader: reader, detector: MeetingEngineDetector(serviceName: "fixture", session: URLSession(configuration: config)),
            preferences: preferences, storage: RoomSyncCoordinatorTests.Storage(), reminders: reminders)
        calendar.setAutomaticJoinMode(.scheduled); calendar.canAutomaticallyJoin = { _ in true }
        let session = MeetingSessionStub(); session.desktopMeetingActive = false; session.isInConference = false; session.desktopCalendar = calendar
        let desktop = MacMeetingCoordinator(model: session, window: window, audioDevices: MacAudioDevices(isMac: false))
        defer { calendar.setEnabled(false); desktop.showForTesting(); desktop.invalidate() }
        desktop.becameActive()
        for _ in 0..<30 where desktop.stateForTesting["bound"] as? Bool != true { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(desktop.stateForTesting["bound"] as? Bool, true)
        XCTAssertEqual(desktop.stateForTesting["schedulingAvailable"] as? Bool, true)
        let joined = expectation(description: "Scheduled boundary executes without foreground activation")
        var joinedAt: Date?
        calendar.onScheduledJoin = { _ in joinedAt = Date(); joined.fulfill() }
        try await MacCalendarSchedulingTests().ready(calendar)
        desktop.closeForTesting(); calendar.backgrounded()
        XCTAssertEqual(desktop.stateForTesting["hidden"] as? Bool, true)
        let frontmost = desktop.stateForTesting["frontmostPID"] as? Int
        print("MAC_IDLE_SCHEDULE_ARMED due=\(due) seconds=\(seconds) frontmost=\(String(describing: frontmost)) pid=\(getpid())")
        await fulfillment(of: [joined], timeout: seconds + 20)
        let elapsed = try XCTUnwrap(joinedAt).timeIntervalSince(due)
        XCTAssertGreaterThanOrEqual(elapsed, 4); XCTAssertLessThan(elapsed, 10)
        XCTAssertEqual(desktop.stateForTesting["hidden"] as? Bool, true)
        XCTAssertEqual(desktop.stateForTesting["frontmostPID"] as? Int, frontmost)
        XCTAssertNotEqual(frontmost, Int(getpid()))
        print("MAC_IDLE_SCHEDULE_VERIFIED lateness_seconds=\(elapsed) state=\(desktop.stateForTesting)")
    }

    func testLiveGuestMediaSurvivesCloseAndRestoreWithoutJoiningAgain() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              let invite = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_MAC_BACKGROUND_INVITE"] else {
            throw XCTSkip("Requires Mac UI activation and a disposable room with synthetic media")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let model = try XCTUnwrap((scene.delegate as? SceneDelegate)?.meetingForTesting)
        let desktop = try XCTUnwrap((scene.delegate as? SceneDelegate)?.macMeetingForTesting)
        defer { desktop.showForTesting(); model.leave() }
        // Qualify the actual native Close button and menu with an independent media sender.
        print("MAC_BACKGROUND_WINDOW_READY pid=\(getpid())")
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while desktop.stateForTesting["bound"] as? Bool != true, ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(100))
        }
        guard desktop.stateForTesting["bound"] as? Bool == true else {
            XCTFail("Native test window did not bind: \(desktop.stateForTesting)"); return
        }
        model.testDisplayNameOverride = "Mac window QA"
        model.receive(url: try XCTUnwrap(URL(string: invite))); model.join()
        let joinDeadline = ProcessInfo.processInfo.systemUptime + 50
        while !model.isInConference, !model.statusIsError, ProcessInfo.processInfo.systemUptime < joinDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(model.isInConference, model.status)
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(desktop.stateForTesting["statusItem"] as? Bool, true)
        let session = model.desktopSessionToken
        var before: [[String: Any]] = []
        func received(_ rows: [[String: Any]], kind: String) -> Int64 {
            rows.filter { $0["type"] as? String == "inbound-rtp" && $0["kind"] as? String == kind }
                .reduce(0) { $0 + (($1["bytesReceived"] as? NSNumber)?.int64Value ?? 0) }
        }
        let mediaDeadline = ProcessInfo.processInfo.systemUptime + 30
        repeat {
            before = await GuestMicrophoneProbe.codecEvidenceForTesting()
            if received(before, kind: "audio") > 0 && received(before, kind: "video") > 0 { break }
            try await Task.sleep(for: .milliseconds(200))
        } while ProcessInfo.processInfo.systemUptime < mediaDeadline
        guard received(before, kind: "audio") > 0, received(before, kind: "video") > 0 else {
            XCTFail("Synthetic audio/video baseline did not arrive: \(before)"); return
        }
        print("MAC_BACKGROUND_MEETING_READY session=\(session)")
        let manualSeconds = Double(ProcessInfo.processInfo.environment["ROCKNROLL_TEST_MAC_BACKGROUND_MANUAL_SECONDS"] ?? "0") ?? 0
        if manualSeconds > 0 { try await Task.sleep(for: .seconds(min(manualSeconds, 300))) }
        XCTAssertTrue(desktop.menuActionForTesting("show"))
        try await Task.sleep(for: .milliseconds(500))
        desktop.closeForTesting()
        try await Task.sleep(for: .seconds(4))
        XCTAssertTrue(model.isInConference)
        XCTAssertEqual(desktop.stateForTesting["hidden"] as? Bool, true)
        XCTAssertEqual(model.desktopSessionToken, session)
        let after = await GuestMicrophoneProbe.codecEvidenceForTesting()
        XCTAssertGreaterThan(received(after, kind: "audio"), received(before, kind: "audio"))
        // Video may deliberately unsubscribe while hidden if there is no PiP.
        // Restoring the window must resume fresh frames, never require a rejoin.
        desktop.showForTesting()
        let resumeDeadline = ProcessInfo.processInfo.systemUptime + 15
        var restored: [[String: Any]] = []
        repeat {
            restored = await GuestMicrophoneProbe.codecEvidenceForTesting()
            if received(restored, kind: "video") > 0 { break }
            try await Task.sleep(for: .milliseconds(200))
        } while ProcessInfo.processInfo.systemUptime < resumeDeadline
        XCTAssertGreaterThan(received(restored, kind: "video"), 0)
        try await Task.sleep(for: .seconds(1))
        let moving = await GuestMicrophoneProbe.codecEvidenceForTesting()
        XCTAssertGreaterThan(received(moving, kind: "video"), received(restored, kind: "video"))
        XCTAssertEqual(model.desktopSessionToken, session)
        // AppKit's normal Close command reaches the delegate backstop too.
        desktop.closeThroughDelegateForTesting()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(desktop.stateForTesting["hidden"] as? Bool, true)
        XCTAssertTrue(model.isInConference)
        XCTAssertTrue(desktop.menuActionForTesting("show"))
        XCTAssertEqual(model.desktopSessionToken, session)
        print("MAC_BACKGROUND_MEDIA_VERIFIED audio_bytes=\(received(after, kind: "audio")) restored_video_bytes=\(received(moving, kind: "video"))")
    }
}
