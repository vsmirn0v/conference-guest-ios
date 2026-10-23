import Combine
import UIKit

/// Reads existing app/engine state. It owns neither audio nor Picture in Picture.
@MainActor
final class MeetingActivitySession {
    struct Context {
        let sessionID: UUID
        let title: String?
        let engine: any CallEngine
        let reconnecting: Bool
        let systemControls: Bool
        let otherCall: Bool
        let audioReady: Bool
    }
    private let preferences: UserDefaults
    private let source: () -> Context?
    private let driver: any MeetingActivityDriver
    let coordinator: MeetingActivityCoordinator
    private var subscriptions = Set<AnyCancellable>()
    private var engineSubscription: AnyCancellable?
    private var controlsSubscription: AnyCancellable?
    private var microphoneSubscription: AnyCancellable?
    private var controls: CallWorkspaceControls?
    private var microphone: PiPMicrophoneStatus = .unavailable
    private var boundSession: UUID?
    private var boundEngine: ObjectIdentifier?
    private var startedAt: Date?
    private var refreshPending = false
    private var freshnessTimer: Timer?

    init(changes: AnyPublisher<Void, Never>, preferences: UserDefaults,
         driver: (any MeetingActivityDriver)? = nil,
         foreground: (() -> Bool)? = nil,
         source: @escaping () -> Context?) {
        let driver = driver ?? MeetingActivitySupport.makeDriver()
        self.preferences = preferences; self.source = source; self.driver = driver
        coordinator = MeetingActivityCoordinator(driver: driver,
            foreground: foreground ?? { UIApplication.shared.applicationState == .active })
        changes.sink { [weak self] in self?.scheduleRefresh() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        scheduleRefresh()
    }
    deinit { freshnessTimer?.invalidate() }

    func foregrounded() { coordinator.foregrounded(); refresh() }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in self?.refreshPending = false; self?.refresh() }
    }

    private func refresh() {
        guard let context = source() else {
            engineSubscription = nil; controlsSubscription = nil; microphoneSubscription = nil
            boundSession = nil; boundEngine = nil; controls = nil; startedAt = nil; microphone = .unavailable
            freshnessTimer?.invalidate(); freshnessTimer = nil
            coordinator.update(nil)
            return
        }
        if boundSession != context.sessionID || boundEngine != ObjectIdentifier(context.engine) {
            engineSubscription = nil; controlsSubscription = nil; microphoneSubscription = nil
            if boundSession != context.sessionID { startedAt = Date() }
            boundSession = context.sessionID; boundEngine = ObjectIdentifier(context.engine)
            controls = nil; microphone = .unavailable
            engineSubscription = context.engine.callWorkspacePublisher.sink { [weak self] controls in
                guard let self else { return }
                self.controls = controls
                self.controlsSubscription = controls?.objectWillChange.sink { [weak self] in self?.scheduleRefresh() }
                self.scheduleRefresh()
            }
            microphoneSubscription = context.engine.activityMicrophonePublisher.removeDuplicates().sink { [weak self] status in
                self?.microphone = status; self?.scheduleRefresh()
            }
        }
        let enabled = preferences.object(forKey: MeetingActivityCoordinator.enabledKey) as? Bool ?? true
        guard enabled, !context.systemControls, driver.available else {
            freshnessTimer?.invalidate(); freshnessTimer = nil; coordinator.update(nil); return
        }
        let connection: MeetingActivityState.Connection = context.otherCall ? .otherCall :
            controls?.onHold == true ? .paused : context.reconnecting || !context.audioReady ? .reconnecting : .connected
        let status: MeetingActivityState.Microphone
        if connection != .connected { status = microphone == .muted ? .muted : .paused }
        else { status = microphone == .on ? .on : microphone == .muted ? .muted : .unknown }
        let showsTitle = preferences.object(forKey: MeetingActivityCoordinator.titleKey) as? Bool ?? true
        let title = showsTitle ? context.title.map { String($0.prefix(120)) } : nil
        let route = controls?.routeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = MeetingActivityState(startedAt: startedAt ?? Date(), connection: connection, microphone: status,
            title: title, route: route.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) })
        coordinator.update(MeetingActivitySnapshot(sessionID: context.sessionID, state: state))
        // A quiet meeting has no state events. One tolerant local tick renews
        // freshness while the app executes; it adds no network or audio work.
        if freshnessTimer == nil {
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = 15
            freshnessTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
    }
}
