import AVKit
import UIKit

/// Shared system PiP lifecycle. Each new AVKit controller gets a fresh content
/// controller; reusing a detached content controller can corrupt its parent chain.
@MainActor
final class FloatingVideoController: NSObject, @preconcurrency AVPictureInPictureControllerDelegate {
    private enum Phase { case idle, starting, active, stopping }
    private let contentView: UIView
    private weak var sourceView: UIView?
    private weak var configuredSource: UIView?
    private var contentController: AVPictureInPictureVideoCallViewController?
    private var controller: AVPictureInPictureController?
    private var readiness: NSKeyValueObservation?
    private var phase: Phase = .idle
    private var suspended = false
    private var closedWhileBackgrounded = false
    private var manualStartPending = false
    var onWillStart: (() -> Void)?
    var onStopped: (() -> Void)?
    var preferredSize = CGSize(width: 320, height: 180) {
        didSet { contentController?.preferredContentSize = preferredSize }
    }

    init(contentView: UIView) {
        self.contentView = contentView
        super.init()
    }

    var canShow: Bool {
        AVPictureInPictureController.isPictureInPictureSupported() && sourceView != nil && !suspended
    }

    func setSourceView(_ view: UIView?) {
        sourceView = view
        guard view != nil else { tearDown(); return }
        prepare()
    }

    private func prepare(manual: Bool = false) {
        guard canShow, manual || FloatingVideoPreference.enabled,
              UIApplication.shared.applicationState != .background,
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
        guard manualStartPending, phase == .idle, UIApplication.shared.applicationState == .active,
              let controller, controller.isPictureInPicturePossible else { return }
        manualStartPending = false
        controller.startPictureInPicture()
    }

    func refreshPreference() {
        if FloatingVideoPreference.enabled { prepare() }
        else { tearDown() }
    }

    func setSuspended(_ suspended: Bool) {
        self.suspended = suspended
        if suspended { tearDown() }
        else { prepare() }
    }

    func foregrounded() {
        closedWhileBackgrounded = false
        controller?.canStartPictureInPictureAutomaticallyFromInline = FloatingVideoPreference.enabled
        if phase == .active || phase == .starting {
            phase = .stopping
            controller?.stopPictureInPicture()
        } else { prepare() }
    }

    private func tearDown() {
        let wasPresenting = phase != .idle
        readiness = nil
        manualStartPending = false
        controller?.delegate = nil
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        controller?.stopPictureInPicture()
        controller?.contentSource = nil
        controller = nil
        contentController = nil
        configuredSource = nil
        phase = .idle
        if wasPresenting { onStopped?() }
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === self.controller else { return }
        phase = .starting
        onWillStart?()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === self.controller else { return }
        phase = .active
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === self.controller else { return }
        let userClosed = phase != .stopping && UIApplication.shared.applicationState == .background
        phase = .idle
        onStopped?()
        if userClosed {
            closedWhileBackgrounded = true
            controller.canStartPictureInPictureAutomaticallyFromInline = false
        } else if !FloatingVideoPreference.enabled {
            tearDown()
        } else { prepare() }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        guard controller === self.controller else { return }
        phase = .idle
        onStopped?()
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(sourceView?.window != nil)
    }
}
