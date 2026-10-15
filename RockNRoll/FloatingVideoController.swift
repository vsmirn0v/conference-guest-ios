import AVKit
import Combine
import UIKit

/// Shared system PiP lifecycle. Each new AVKit controller gets a fresh content
/// controller; reusing a detached content controller can corrupt its parent chain.
@MainActor
final class FloatingVideoController: NSObject, @preconcurrency AVPictureInPictureControllerDelegate {
    struct Environment {
        var applicationState: () -> UIApplication.State = { UIApplication.shared.applicationState }
        var supported: () -> Bool = { AVPictureInPictureController.isPictureInPictureSupported() }
        var possible: (AVPictureInPictureController) -> Bool = { $0.isPictureInPicturePossible }
        var active: (AVPictureInPictureController) -> Bool = { $0.isPictureInPictureActive }
        var start: (AVPictureInPictureController) -> Void = { $0.startPictureInPicture() }
        var stop: (AVPictureInPictureController) -> Void = { $0.stopPictureInPicture() }
        var recoveryTimeoutNanoseconds: UInt64 = 10_000_000_000
    }
    private let environment: Environment
    private enum Phase { case idle, starting, active, stopping }
    private let contentView: FloatingVideoContentView
    private var speakerSubscription: AnyCancellable?
    private weak var sourceView: UIView?
    private weak var configuredSource: UIView?
    private var contentController: AVPictureInPictureVideoCallViewController?
    private var controller: AVPictureInPictureController?
    private var readiness: NSKeyValueObservation?
    private var phase: Phase = .idle
    private var suspended = false
    private var closedWhileBackgrounded = false
    private var manualStartPending = false
    private var resumePending = false
    private var recoveryAttempts = 0
    private var recoveryTask: Task<Void, Never>?
    private var recoveryDeadline: Task<Void, Never>?
    private var recoveryDemand = false
    var onRecoveryDemandChanged: ((Bool) -> Void)?
    var needsRecoveryFrames: Bool { resumePending && !suspended && !closedWhileBackgrounded && !isEnded }
    var isPresenting: Bool { phase == .active || phase == .starting }
    private weak var microphoneActivity: MicrophoneActivity?
    var onPresentationChanged: ((Bool) -> Void)?
    private(set) var isEnded = false
    var onWillStart: (() -> Void)?
    var onStopped: (() -> Void)?
    #if DEBUG
    var hasSourceForTesting: Bool { sourceView != nil }
    var controllerForTesting: AVPictureInPictureController? { controller }
    #endif
    var preferredSize = CGSize(width: 320, height: 180) {
        didSet { if oldValue != preferredSize { contentController?.preferredContentSize = preferredSize } }
    }

    init(contentView: UIView, speaker: ActiveSpeakerStore? = nil, environment: Environment = Environment()) {
        self.environment = environment
        self.contentView = FloatingVideoContentView(videoContent: contentView)
        super.init()
        speakerSubscription = speaker?.$current.sink { [weak contentView = self.contentView] in
            contentView?.setSpeaker($0)
        }
    }

    var canShow: Bool {
        !isEnded && environment.supported() && sourceView != nil && !suspended
    }

    func bindMicrophoneActivity(_ activity: MicrophoneActivity) {
        if microphoneActivity !== activity { microphoneActivity?.setFloating(false) }
        microphoneActivity = activity
        activity.setFloating(isPresenting && !suspended)
        contentView.bindMicrophoneActivity(activity)
    }

    func setMicrophoneStatus(_ status: PiPMicrophoneStatus) {
        contentView.setMicrophoneStatus(status)
    }

    func setSourceView(_ view: UIView?, preservingPresentation: Bool = false) {
        guard !isEnded else { return }
        sourceView = view
        contentView.setWaitingForVideo(view == nil)
        guard view != nil else {
            // An active meeting can temporarily have no video. Keep its stable
            // PiP window/anchor while waiting for a replacement share or rejoin.
            if preservingPresentation && (phase == .active || phase == .starting || resumePending) { return }
            resumePending = false; updateRecoveryDemand()
            tearDown(); return
        }
        prepare()
        startPendingManualRequest()
    }

    private func prepare(manual: Bool = false) {
        guard canShow, manual || FloatingVideoPreference.enabled,
              environment.applicationState() != .background,
              phase == .idle, let sourceView, sourceView.window != nil else { return }
        if configuredSource === sourceView, controller != nil { return }
        tearDown()
        let content = AVPictureInPictureVideoCallViewController()
        content.preferredContentSize = preferredSize
        content.view.backgroundColor = .black
        contentView.removeFromSuperview()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        content.view.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: content.view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: content.view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: content.view.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: content.view.bottomAnchor)
        ])
        contentController = content
        configuredSource = sourceView
        let pip = AVPictureInPictureController(contentSource: .init(
            activeVideoCallSourceView: sourceView, contentViewController: content))
        controller = pip
        pip.canStartPictureInPictureAutomaticallyFromInline = FloatingVideoPreference.enabled
        pip.delegate = self
        readiness = pip.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.startPendingManualRequest() }
        }
    }

    func start() {
        guard canShow, !closedWhileBackgrounded else { return }
        prepare(manual: true)
        manualStartPending = true
        startPendingManualRequest()
    }

    private func startPendingManualRequest() {
        if resumePending || manualStartPending { traceRecovery("pip-start-check") }
        guard canShow, !closedWhileBackgrounded, phase == .idle,
              (manualStartPending && environment.applicationState() == .active || needsRecoveryFrames),
              let controller, environment.possible(controller) else { return }
        manualStartPending = false
        phase = .starting
        environment.start(controller)
    }

    func refreshPreference() {
        if FloatingVideoPreference.enabled { prepare() }
        else { resumePending = false; updateRecoveryDemand(); tearDown() }
    }

    func setSuspended(_ suspended: Bool) {
        guard !isEnded, self.suspended != suspended else { return }
        self.suspended = suspended
        traceRecovery(suspended ? "pip-suspend" : "pip-resume")
        if suspended {
            resumePending = resumePending || phase == .active || phase == .starting
            recoveryTask?.cancel(); recoveryTask = nil
            recoveryDeadline?.cancel(); recoveryDeadline = nil
            // AVKit owns window visibility during competing system calls. Stop
            // media delivery, not the window: iOS can retain it as active while
            // hiding it, and an explicit stop may never deliver didStop.
            if resumePending { onPresentationChanged?(false) }
        } else {
            recoveryAttempts = 0
            if resumePending, let controller {
                if environment.active(controller) {
                    phase = .active; resumePending = false
                    microphoneActivity?.setFloating(true)
                    onPresentationChanged?(true); onWillStart?()
                    traceRecovery("pip-resumed-existing-window")
                } else {
                    // Reconcile an inactive window even if AVKit omitted its
                    // delegate callback while the competing call owned media.
                    phase = .idle
                    microphoneActivity?.setFloating(false)
                    onPresentationChanged?(false); onStopped?()
                }
            }
            if resumePending {
                recoveryDeadline = Task { [weak self, timeout = environment.recoveryTimeoutNanoseconds] in
                    do { try await Task.sleep(nanoseconds: timeout) } catch { return }
                    guard let self, self.resumePending else { return }
                    self.traceRecovery("pip-recovery-timeout")
                    self.resumePending = false
                    self.updateRecoveryDemand()
                    self.tearDown()
                }
            }
            prepare()
            startPendingManualRequest()
        }
        updateRecoveryDemand()
    }

    private func traceRecovery(_ event: String) {
        #if DEBUG
        CameraBackgroundTrace.event(event, ["phase": String(describing: phase), "resumePending": resumePending,
            "suspended": suspended, "hasSource": sourceView != nil,
            "controllerActive": controller.map(environment.active) ?? false,
            "controllerPossible": controller.map(environment.possible) ?? false])
        #endif
    }

    func foregrounded() {
        guard !isEnded else { return }
        closedWhileBackgrounded = false
        resumePending = false; recoveryAttempts = 0
        recoveryTask?.cancel(); recoveryTask = nil
        recoveryDeadline?.cancel(); recoveryDeadline = nil
        updateRecoveryDemand()
        controller?.canStartPictureInPictureAutomaticallyFromInline = FloatingVideoPreference.enabled
        if phase == .active || phase == .starting {
            phase = .stopping
            if let controller { environment.stop(controller) }
        } else { prepare() }
    }

    /// A meeting's renderer cannot be rearmed by queued frames or scene callbacks.
    func end() {
        guard !isEnded else { return }
        isEnded = true
        resumePending = false; updateRecoveryDemand()
        sourceView = nil
        tearDown()
        speakerSubscription = nil
    }

    private func tearDown() {
        let wasPresenting = phase != .idle
        readiness = nil
        recoveryTask?.cancel(); recoveryTask = nil
        recoveryDeadline?.cancel(); recoveryDeadline = nil
        manualStartPending = false
        controller?.delegate = nil
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        if let controller { environment.stop(controller) }
        controller?.contentSource = nil
        controller = nil
        contentController = nil
        configuredSource = nil
        phase = .idle
        microphoneActivity?.setFloating(false)
        if wasPresenting { onPresentationChanged?(false); onStopped?() }
    }

    private func updateRecoveryDemand() {
        let value = needsRecoveryFrames
        guard recoveryDemand != value else { return }
        recoveryDemand = value; onRecoveryDemandChanged?(value)
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === self.controller else { return }
        #if DEBUG
        CameraBackgroundTrace.event("pip-will-start")
        #endif
        phase = .starting
        microphoneActivity?.setFloating(true)
        onPresentationChanged?(true)
        onWillStart?()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === self.controller else { return }
        #if DEBUG
        CameraBackgroundTrace.event("pip-started")
        #endif
        phase = .active
        resumePending = false; recoveryAttempts = 0
        recoveryDeadline?.cancel(); recoveryDeadline = nil
        updateRecoveryDemand()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === self.controller else { return }
        #if DEBUG
        CameraBackgroundTrace.event("pip-stopped")
        #endif
        let userClosed = phase != .stopping && !suspended && !resumePending && environment.applicationState() == .background
        phase = .idle
        microphoneActivity?.setFloating(false)
        onPresentationChanged?(false)
        onStopped?()
        if userClosed {
            closedWhileBackgrounded = true
            resumePending = false; updateRecoveryDemand()
            controller.canStartPictureInPictureAutomaticallyFromInline = false
        } else if !FloatingVideoPreference.enabled {
            tearDown()
        } else { prepare(); startPendingManualRequest() }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        guard controller === self.controller else { return }
        #if DEBUG
        CameraBackgroundTrace.event("pip-failed", ["error": (error as NSError).code])
        #endif
        phase = .idle
        microphoneActivity?.setFloating(false)
        onPresentationChanged?(false)
        onStopped?()
        guard needsRecoveryFrames else { return }
        recoveryAttempts += 1
        guard recoveryAttempts <= 2 else { resumePending = false; updateRecoveryDemand(); return }
        // AVKit may still be handing video back from the competing call. Retry
        // only a previously active PiP, never a user-dismissed or new window.
        recoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            self?.startPendingManualRequest()
        }
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler((sourceView ?? configuredSource)?.window != nil)
    }
}
