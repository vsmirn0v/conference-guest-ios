#if NATIVE_DIRECT_UPDATES
import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor struct NativeDesktopUpdateMediaGate {
    var claimIfDrained: (UUID) -> Bool
    var drain: (UUID) async -> Bool
    var release: (UUID) -> Void
    static var live: Self { .init(
        claimIfDrained: { NativeDesktopForegroundMedia.shared.prepareForUpdateIfDrained($0) },
        drain: { await NativeDesktopForegroundMedia.shared.prepareForUpdate($0) },
        release: { NativeDesktopForegroundMedia.shared.cancelUpdatePreparation($0) }) }
}

/// Direct-distribution only. Meeting admission and Sparkle callbacks share MainActor.
@MainActor final class NativeDesktopUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    let safety: NativeUpdateSafety
    @Published private(set) var status = "Updates install only when no meeting is active."
    @Published private(set) var beta = UserDefaults.standard.bool(forKey: "native.updates.beta")
    private var subscriptions = Set<AnyCancellable>()
    private var deferred: [() -> Void] = []
    private var installWhenIdle: (() -> Void)?
    private var driver: MeetingSafeUpdateDriver!
    private(set) var updater: SPUUpdater!
    var busy: () -> Bool = { true }
    var channelLocked: Bool { safety.recoveryTargetBuild != nil || prepared || updater?.sessionInProgress == true }
    private var prepared = false
    private var stage2Requested = false
    private var cycleActive = false
    private var cycleEpoch = UUID()
    private var mediaPreparedForInstall = false
    private var mediaPreparation: Task<Bool, Never>?
    private let mediaGate: NativeDesktopUpdateMediaGate
    var mayStartMeeting: Bool { safety.mayStartMeeting }

    init(safety: NativeUpdateSafety, mediaGate: NativeDesktopUpdateMediaGate? = nil) {
        self.safety = safety; self.mediaGate = mediaGate ?? .live
        super.init()
        driver = MeetingSafeUpdateDriver(owner: self)
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        safety.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        updater.publisher(for: \.canCheckForUpdates).sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        if let target = safety.recoveryTargetBuild { status = "Finish updating to build \(target) before joining a meeting."; prepared = true }
    }
    func start() { do { try updater.start() } catch { status = error.localizedDescription } }
    func check() {
        guard updater.canCheckForUpdates else { return }
        if busy() {
            status = "Checking in the background. Installation will wait until the meeting ends."
            updater.checkForUpdatesInBackground()
        } else { updater.checkForUpdates() }
    }
    func setBeta(_ value: Bool) {
        guard !channelLocked else { return }
        beta = value; UserDefaults.standard.set(value, forKey: "native.updates.beta")
        updater.resetUpdateCycle()
    }
    func showWhenIdle(_ action: @escaping () -> Void) {
        if busy() { deferred.append(action); status = "An update is waiting until the meeting ends." }
        else { action() }
    }
    func activityChanged() {
        guard !busy(), !safety.installationReserved else { return }
        if let action = installWhenIdle { installWhenIdle = nil; action(); return }
        while !deferred.isEmpty, !busy(), !safety.installationReserved {
            deferred.removeFirst()()
        }
    }
    private func reserve() -> Bool {
        guard cycleActive, !busy() else { return false }
        if !mediaPreparedForInstall { mediaPreparedForInstall = mediaGate.claimIfDrained(cycleEpoch) }
        guard mediaPreparedForInstall else { return false }
        do { return try safety.reserveInstallation(busy: busy()) }
        catch { status = error.localizedDescription; return false }
    }
    func prepareChoice(_ item: SUAppcastItem) -> Bool {
        guard cycleActive else { return false }
        do {
            guard let target = Int(item.versionString) else { throw NativeUpdateSafety.SafetyError.invalidBuild }
            try safety.prepareUpdate(targetBuild: target); prepared = true; return true
        } catch { status = error.localizedDescription; return false }
    }
    func installChoice(_ choice: SPUUserUpdateChoice, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard cycleActive else { return }
        guard choice == .install else { reply(choice); return }
        if reserve() { reply(choice); return }
        if busy() {
            let epoch = cycleEpoch
            installWhenIdle = { [weak self] in
                guard let self, self.cycleActive, self.cycleEpoch == epoch else { return }
                self.installChoice(choice, reply: reply)
            }
            status = "The update will install after the meeting ends."
            return
        }
        let epoch = cycleEpoch
        Task { @MainActor [weak self] in
            guard let self, cycleActive, cycleEpoch == epoch else { return }
            if mediaPreparation == nil {
                mediaPreparation = Task { await self.mediaGate.drain(epoch) }
            }
            let clean = await mediaPreparation?.value == true
            guard cycleActive, cycleEpoch == epoch else { return }
            mediaPreparation = nil; mediaPreparedForInstall = clean
            guard clean, reserve() else {
                status = "Media could not stop safely for the update. Leave any private check and try again."
                reply(.dismiss); return
            }
            reply(choice)
        }
    }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard !safety.installationReserved else { throw NativeUpdateSafety.SafetyError.installerMayRun }
        status = "Checking for updates…"
        cycleActive = true; cycleEpoch = UUID(); installWhenIdle = nil; deferred.removeAll(); driver.invalidate()
    }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { beta ? ["beta"] : [] }
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard cycleActive, let target = Int(item.versionString) else { throw NativeUpdateSafety.SafetyError.invalidBuild }
        try safety.prepareUpdate(targetBuild: target); prepared = true
    }
    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) { safety.markInstallerMayRun() }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { stage2Requested = true }
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { reserve() }
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock action: @escaping () -> Void) -> Bool {
        guard cycleActive, prepareChoice(item) else { return true }
        let epoch = cycleEpoch
        installWhenIdle = { [weak self] in
            guard let self, self.cycleActive, self.cycleEpoch == epoch else { return }
            self.installChoice(.install) { if $0 == .install { action() } }
        }
        Task { @MainActor [weak self] in self?.activityChanged() }
        return true
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        status = error.localizedDescription
        if !stage2Requested { safety.releaseReservationAfterVerifiedStage2NotRequested() }
        invalidateCycle()
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        invalidateCycle()
        clearPreparedIfSafe()
        if error == nil, !prepared { status = "Updates install only when no meeting is active." }
    }
    private func invalidateCycle() {
        let epoch = cycleEpoch
        cycleActive = false; cycleEpoch = UUID(); installWhenIdle = nil; deferred.removeAll(); driver.invalidate()
        if !safety.installationReserved {
            mediaPreparedForInstall = false
            // A native operation may outlive cancellation. Release its exclusion
            // only after that retained drain task has actually completed.
            let pending = mediaPreparation; mediaPreparation = nil
            if let pending { Task { _ = await pending.value; self.mediaGate.release(epoch) } }
            else { mediaGate.release(epoch) }
        }
    }
    func clearPreparedIfSafe() {
        do { if try safety.clearPreparedUpdateIfSafe() { prepared = false } }
        catch { status = error.localizedDescription }
    }
    func willTerminate() { clearPreparedIfSafe() }
}

@MainActor private final class MeetingSafeUpdateDriver: NSObject, SPUUserDriver {
    weak var owner: NativeDesktopUpdates?
    private var generation = 0
    private let standard = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
    init(owner: NativeDesktopUpdates) { self.owner = owner }
    private func present(_ action: @escaping () -> Void) {
        let token = generation
        owner?.showWhenIdle { [weak self] in guard self?.generation == token else { return }; action() }
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) { present { self.standard.show(request, reply: reply) } }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { present { self.standard.showUserInitiatedUpdateCheck(cancellation: cancellation) } }
    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let token = generation
        present { self.standard.showUpdateFound(with: item, state: state) { choice in
            guard self.generation == token else { return }
            guard choice != .install || self.owner?.prepareChoice(item) == true else { reply(.dismiss); return }
            if state.stage == .installing { self.owner?.installChoice(choice, reply: reply) } else { reply(choice) }
        } }
    }
    func showUpdateReleaseNotes(with data: SPUDownloadData) { present { self.standard.showUpdateReleaseNotes(with: data) } }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { present { self.standard.showUpdateReleaseNotesFailedToDownloadWithError(error) } }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { present { self.standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement) } }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { present { self.standard.showUpdaterError(error, acknowledgement: acknowledgement) } }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { present { self.standard.showDownloadInitiated(cancellation: cancellation) } }
    func showDownloadDidReceiveExpectedContentLength(_ length: UInt64) { standard.showDownloadDidReceiveExpectedContentLength(length) }
    func showDownloadDidReceiveData(ofLength length: UInt64) { standard.showDownloadDidReceiveData(ofLength: length) }
    func showDownloadDidStartExtractingUpdate() { present { self.standard.showDownloadDidStartExtractingUpdate() } }
    func showExtractionReceivedProgress(_ progress: Double) { standard.showExtractionReceivedProgress(progress) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let token = generation
        present { self.standard.showReady { choice in
            guard self.generation == token else { return }; self.owner?.installChoice(choice, reply: reply)
        } }
    }
    func showInstallingUpdate(withApplicationTerminated terminated: Bool, retryTerminatingApplication retry: @escaping () -> Void) {
        let token = generation
        present { self.standard.showInstallingUpdate(withApplicationTerminated: terminated) {
            guard self.generation == token, !terminated else { return }; self.owner?.installChoice(.install) { _ in retry() }
        } }
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement) }
    func invalidate() { generation += 1 }
    func dismissUpdateInstallation() { invalidate(); standard.dismissUpdateInstallation() }
}

struct NativeDesktopUpdateBanner: View {
    @ObservedObject var updates: NativeDesktopUpdates
    var body: some View {
        if !updates.mayStartMeeting {
            HStack {
                Label(updates.status, systemImage: "arrow.down.circle")
                Spacer()
                Button("Finish update…") { updates.check() }.disabled(!updates.updater.canCheckForUpdates)
            }.padding(12).background(.regularMaterial)
        }
    }
}

struct NativeDesktopUpdatesView: View {
    @ObservedObject var updates: NativeDesktopUpdates
    var body: some View {
        Form {
            Section("Software updates") {
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                   let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                    LabeledContent("Installed version", value: "\(version) (\(build))")
                }
                Toggle("Automatically check for updates", isOn: Binding(get: { updates.updater.automaticallyChecksForUpdates }, set: { updates.updater.automaticallyChecksForUpdates = $0; updates.objectWillChange.send() }))
                Toggle("Automatically download updates", isOn: Binding(get: { updates.updater.automaticallyDownloadsUpdates }, set: { updates.updater.automaticallyDownloadsUpdates = $0; updates.objectWillChange.send() }))
                Toggle("Beta updates", isOn: Binding(get: { updates.beta }, set: { updates.setBeta($0) })).disabled(updates.channelLocked)
                Text("Beta updates include early changes. Turning this off waits for a newer stable release; it does not downgrade your app.").font(.caption).foregroundStyle(.secondary)
                Button("Check for Updates…") { updates.check() }.disabled(!updates.updater.canCheckForUpdates)
                Text(updates.status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
