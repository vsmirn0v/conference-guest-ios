import Combine
import ConferenceCore
import Foundation
import UIKit

@MainActor
protocol MacMeetingSession: AnyObject {
    var desktopChanges: AnyPublisher<Void, Never> { get }
    var desktopMeetingActive: Bool { get }
    var desktopSessionToken: String { get }
    var desktopMeetingTitle: String { get }
    var desktopEngine: (any CallEngine)? { get }
    var isInConference: Bool { get }
    func prepareToFloat()
    func backgroundedWithoutFloatingVideo()
    func restoreFromFloatingVideo()
    func leave()
    func reminderVisibilityChanged(_ visible: Bool)
    var desktopCalendar: CalendarMeetingStore? { get }
    func desktopJoinCalendarMeeting(_ meeting: CalendarMeeting)
}

extension MacMeetingSession {
    func reminderVisibilityChanged(_ visible: Bool) {}
    var desktopCalendar: CalendarMeetingStore? { nil }
    func desktopJoinCalendarMeeting(_ meeting: CalendarMeeting) {}
}

extension ConferenceModel: MacMeetingSession {
    var desktopChanges: AnyPublisher<Void, Never> { objectWillChange.eraseToAnyPublisher() }
    var desktopCalendar: CalendarMeetingStore? { calendar }
    func desktopJoinCalendarMeeting(_ meeting: CalendarMeeting) { joinCalendarMeeting(meeting) }
}

@MainActor
protocol MacMeetingPresentation: AnyObject {
    var hiddenForMeeting: Bool { get }
    var visibleForReminders: Bool { get }
    var schedulingAvailable: Bool { get }
    func bindMainWindow() -> Bool
    func markVisible()
    func update(_ state: MacMeetingMenuState)
    func showMeeting()
    func closeMeetingWindow()
    func hideMeeting() -> Bool
    func invalidate()
}

extension MacMeetingPresentation {
    var visibleForReminders: Bool { !hiddenForMeeting }
    var schedulingAvailable: Bool { true }
}

@MainActor
private final class NativeMacMeetingPresentation: MacMeetingPresentation {
    fileprivate let bridge: RockMacMeetingWindowBridge
    init(window: UIWindow?, action: @escaping (String) -> Void) {
        bridge = RockMacMeetingWindowBridge(window: window, action: action)
    }
    func bindMainWindow() -> Bool { bridge.bindMainWindow() }
    var hiddenForMeeting: Bool { bridge.hiddenForMeeting }
    var visibleForReminders: Bool { bridge.visibleForReminders }
    var schedulingAvailable: Bool { bridge.schedulingAvailable }
    func markVisible() { bridge.markVisible() }
    func update(_ state: MacMeetingMenuState) {
        bridge.residentEnabled = state.resident
        bridge.updateActive(state.active, title: state.title, microphoneOn: state.microphoneOn, menu: state.menu)
    }
    func showMeeting() { bridge.showMeeting() }
    func closeMeetingWindow() { bridge.closeMeetingWindow() }
    func hideMeeting() -> Bool { bridge.hideMeeting() }
    func invalidate() { bridge.invalidate() }
}

/// Window visibility never changes the session or starts another engine.
@MainActor
final class MacMeetingCoordinator {
    private weak var model: (any MacMeetingSession)?
    private var bridge: (any MacMeetingPresentation)!
    private let audioDevices: MacAudioDevices
    private var subscriptions = Set<AnyCancellable>()
    private var engineSubscription: AnyCancellable?
    private var controlsSubscription: AnyCancellable?
    private var engineID: ObjectIdentifier?
    private var controls: CallWorkspaceControls?
    private var refreshPending = false
    private var lastSnapshot: MacMeetingMenuState?
    private var bound = false
    private var bindingTask: Task<Void, Never>?
    private var terminating = false
    private let calendarActivity = MacCallActivity(begin: { MacCallActivity.beginScheduledActivity() })
    private var activityDeadline: Task<Void, Never>?

    init(model: any MacMeetingSession, window: UIWindow? = nil, audioDevices: MacAudioDevices = .shared,
         makePresentation: ((@escaping (String) -> Void) -> any MacMeetingPresentation)? = nil) {
        self.audioDevices = audioDevices
        self.model = model
        let action: (String) -> Void = { [weak self] action in self?.perform(action) }
        bridge = makePresentation?(action) ?? NativeMacMeetingPresentation(window: window, action: action)
        model.desktopChanges.sink { [weak self] in self?.scheduleRefresh() }.store(in: &subscriptions)
        audioDevices.$snapshot.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        if let calendar = model.desktopCalendar {
            calendar.objectWillChange.sink { [weak self] in self?.scheduleRefresh() }.store(in: &subscriptions)
            calendar.onScheduledActivity = { [weak self] deadline in self?.setScheduledActivity(deadline) }
            calendar.schedulingIsAvailable = { [weak self] in self?.bridge.schedulingAvailable == true }
        }
    }

    func becameActive() {
        let wasHidden = bridge.hiddenForMeeting
        bound = bridge.bindMainWindow()
        if !bound { bindingLost() }
        bridge.markVisible()
        model?.desktopCalendar?.setSchedulingAvailable(bound && bridge.schedulingAvailable)
        model?.reminderVisibilityChanged(bridge.visibleForReminders)
        if wasHidden && !bridge.hiddenForMeeting { model?.restoreFromFloatingVideo() }
        #if DEBUG
        NSLog("Mac meeting window binding: %@ %@", String(bound), String(describing: RockMacMeetingBridgeDiagnostics()))
        #endif
        refresh()
        if !bound {
            bindingTask?.cancel()
            bindingTask = Task { @MainActor [weak self] in
                for _ in 0..<5 {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self, !self.terminating else { return }
                    if self.bridge.bindMainWindow() { self.bound = true; self.lastSnapshot = nil; self.refresh(); return }
                }
            }
        }
    }

    private func scheduleRefresh() {
        guard !refreshPending, !terminating else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshPending = false
            self?.refresh()
        }
    }

    private func refresh() {
        guard let model, !terminating else { return }
        if !bound { bound = bridge.bindMainWindow(); if !bound { return } }
        if !bridge.bindMainWindow() {
            bindingLost()
            return
        }
        model.desktopCalendar?.setSchedulingAvailable(bridge.schedulingAvailable)
        let engine = model.desktopEngine
        let identifier = engine.map(ObjectIdentifier.init)
        if identifier != engineID {
            engineID = identifier
            controlsSubscription = nil; controls = nil
            engineSubscription = engine?.callWorkspacePublisher.sink { [weak self] controls in
                guard let self else { return }
                self.controls = controls
                self.controlsSubscription = controls?.objectWillChange.sink { [weak self] in self?.scheduleRefresh() }
                self.scheduleRefresh()
            }
        }
        let calendar = model.desktopCalendar
        let state = MacMeetingMenuState(active: model.desktopMeetingActive, joined: model.isInConference,
            title: model.desktopMeetingActive ? model.desktopMeetingTitle : L("Rock’n’Roll"), session: model.desktopSessionToken,
            microphoneOn: controls?.microphoneOn == true,
            microphoneAvailable: controls?.microphoneAvailable == true && controls?.toggleMicrophone != nil,
            held: controls?.onHold == true, audio: audioDevices.snapshot,
            resident: calendar?.keepInMenuBar == true,
            nextMeeting: calendar?.joiningMeeting ?? calendar?.nextScheduledMeeting,
            countdown: calendar?.countdown, automaticJoining: calendar?.automaticJoinMode == .scheduled,
            automaticPaused: calendar?.automaticJoinPausedUntil.map { $0 > Date() } ?? false,
            nextSkipped: calendar?.nextScheduledMeeting.map { calendar?.automaticJoinSuppressed($0) == true } ?? false)
        guard state != lastSnapshot else { return }
        lastSnapshot = state
        bridge.update(state)
    }

    private func bindingLost() {
        bound = false; lastSnapshot = nil
        model?.desktopCalendar?.setSchedulingAvailable(false)
        bridge.update(MacMeetingMenuState(active: false, joined: false, title: "", session: "",
            microphoneOn: false, microphoneAvailable: false, held: false, audio: MacAudioSnapshot()))
    }

    private func perform(_ action: String) {
        guard let model, !terminating else { return }
        if action == "terminate" {
            terminating = true; bindingTask?.cancel(); setScheduledActivity(nil)
            model.desktopCalendar?.setSchedulingAvailable(false); model.leave(); return
        }
        if action.hasPrefix("scheduling:") {
            model.desktopCalendar?.setSchedulingAvailable(action == "scheduling:resume" && bridge.schedulingAvailable, resetEligibility: true)
            return
        }
        if action == "reminderVisibility" { model.reminderVisibilityChanged(bridge.visibleForReminders); return }
        if action == "binding" { if !terminating { becameActive() }; return }
        guard !terminating, bound else { return }
        guard bridge.bindMainWindow() else { bindingLost(); return }
        if action == "calendar:settings" {
            bridge.showMeeting(); model.desktopCalendar?.showingMacSettings = true; return
        }
        if action == "calendar:pause" { model.desktopCalendar?.pauseScheduledJoiningToday(); return }
        if action == "calendar:resume" { model.desktopCalendar?.resumeScheduledJoining(); return }
        if action.hasPrefix("calendar:join:") || action.hasPrefix("calendar:skip:") {
            guard !model.desktopMeetingActive, let calendar = model.desktopCalendar,
                  let meeting = calendar.meetings.first(where: { Self.calendarAction($0) == String(action.dropFirst("calendar:join:".count)) }),
                  meeting.hasResolvedInvitation, meeting.end > Date() else { return }
            if action.hasPrefix("calendar:skip:") { calendar.suppressAutomaticJoin(for: meeting) }
            else { model.desktopJoinCalendarMeeting(meeting) }
            return
        }
        if action == "visible" { model.reminderVisibilityChanged(bridge.visibleForReminders); model.restoreFromFloatingVideo(); return }
        if action == "hidden" { model.reminderVisibilityChanged(false); model.prepareToFloat(); model.backgroundedWithoutFloatingVideo(); return }
        let pieces = action.split(separator: ":")
        guard pieces.count >= 2, pieces[0] == Substring(model.desktopSessionToken), model.desktopMeetingActive else { return }
        switch pieces[1] {
        case "mic":
            guard model.isInConference, controls?.onHold == false, controls?.microphoneAvailable == true else { return }
            guard pieces.count == 3, let desired = MacMeetingMenuState.microphoneIntent(String(pieces[2])),
                  controls?.microphoneOn != desired else { return }
            controls?.toggleMicrophone?()
        case "leave":
            model.leave()
        case "input", "output":
            guard model.isInConference, controls?.onHold == false, pieces.count == 3, let id = UInt32(pieces[2]) else { return }
            do { try audioDevices.select(id, for: pieces[1] == "input" ? .input : .output) }
            catch { model.desktopEngine?.showMediaStatus(L("Audio device unavailable")) }
        default: break
        }
    }

    func invalidate() {
        terminating = true; bindingTask?.cancel()
        setScheduledActivity(nil)
        model?.desktopCalendar?.setSchedulingAvailable(false)
        subscriptions.removeAll(); engineSubscription = nil; controlsSubscription = nil
        bridge.invalidate()
    }
    var canHideMeeting: Bool { !terminating && bound && (model?.desktopMeetingActive == true || model?.desktopCalendar?.keepInMenuBar == true) }
    private func setScheduledActivity(_ deadline: Date?) {
        guard let deadline else { activityDeadline?.cancel(); activityDeadline = nil; calendarActivity.setActive(false); return }
        guard activityDeadline == nil else { return }
        calendarActivity.setActive(true)
        let remaining = min(45, max(0.05, deadline.timeIntervalSinceNow))
        activityDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            self?.calendarActivity.setActive(false); self?.activityDeadline = nil
        }
    }
    nonisolated static func calendarAction(_ meeting: CalendarMeeting) -> String {
        Data((meeting.id + "|" + String(meeting.start.timeIntervalSince1970)).utf8).base64EncodedString()
    }
    func hideMeeting() {
        guard !terminating else { return }
        refresh()
        if bound { bridge.closeMeetingWindow() }
    }
    #if DEBUG
    var stateForTesting: [AnyHashable: Any] {
        (bridge as? NativeMacMeetingPresentation)?.bridge.stateForTesting() ?? [:]
    }
    func closeForTesting() { (bridge as? NativeMacMeetingPresentation)?.bridge.closeForTesting() }
    func closeThroughDelegateForTesting() { (bridge as? NativeMacMeetingPresentation)?.bridge.closeThroughDelegateForTesting() }
    func showForTesting() { bridge.showMeeting() }
    func menuActionForTesting(_ action: String) -> Bool {
        (bridge as? NativeMacMeetingPresentation)?.bridge.invokeMenuActionForTesting(action) ?? false
    }
    #endif
}

struct MacMeetingMenuState: Equatable {
    var active: Bool
    var joined: Bool
    var title: String
    var session: String
    var microphoneOn: Bool
    var microphoneAvailable: Bool
    var held: Bool
    var audio: MacAudioSnapshot
    var resident = false
    var nextMeeting: CalendarMeeting? = nil
    var countdown: Int? = nil
    var automaticJoining = false
    var automaticPaused = false
    var nextSkipped = false

    static func microphoneIntent(_ value: String) -> Bool? {
        switch value { case "on": return true; case "off": return false; default: return nil }
    }

    var canToggleMicrophone: Bool { active && joined && microphoneAvailable && !held }
    var menu: [[String: Any]] {
        if !active {
            var items: [[String: Any]] = [["title": L("Rock’n’Roll"), "enabled": false]]
            if let nextMeeting {
                let text = countdown.map { L("Joining in %d…", $0) } ?? nextMeeting.start.formatted(date: .omitted, time: .shortened)
                items.append(["title": nextMeeting.title + " · " + text, "enabled": false])
                if nextSkipped { items.append(["title": L("Automatic join skipped"), "enabled": false]) }
                items.append(["title": L("Join meeting"), "action": "calendar:join:" + MacMeetingCoordinator.calendarAction(nextMeeting)])
                if automaticJoining && !nextSkipped {
                    items.append(["title": L("Skip automatic join for this meeting"), "action": "calendar:skip:" + MacMeetingCoordinator.calendarAction(nextMeeting)])
                }
            }
            if automaticJoining {
                items.append(["title": L(automaticPaused ? "Resume automatic joining" : "Pause automatic joining today"),
                              "action": automaticPaused ? "calendar:resume" : "calendar:pause"])
            }
            items.append(contentsOf: [["separator": true], ["title": L("Open Rock’n’Roll"), "action": "show"],
                ["title": L("Settings…"), "action": "calendar:settings"], ["title": L("Quit Rock’n’Roll"), "action": "quit"]])
            return items
        }
        var items: [[String: Any]] = [
            ["title": title, "enabled": false],
            ["title": L("Show meeting"), "action": "show"],
            ["separator": true],
            ["title": L(microphoneOn ? "Mute microphone" : "Unmute microphone"),
             "action": "\(session):mic:\(microphoneOn ? "off" : "on")", "enabled": canToggleMicrophone]
        ]
        if held { items.append(["title": L("Jam on hold"), "enabled": false]) }
        for direction in MacAudioDirection.allCases {
            let devices = audio.devices(for: direction)
            items.append(["title": L(direction == .input ? "Microphone" : "Audio output"),
                "enabled": joined && !held && !devices.isEmpty,
                "tooltip": L("Audio device selections also affect other apps."),
                "children": devices.map { device in
                    ["title": device.name, "action": "\(session):\(direction == .input ? "input" : "output"):\(device.id)",
                     "selected": device.id == audio.selectedID(for: direction)] as [String: Any]
                }])
        }
        items.append(["separator": true])
        items.append(["title": L("Leave jam"), "action": "\(session):leave"])
        items.append(["title": L("Quit Rock’n’Roll"), "action": "quit"])
        return items
    }
}
