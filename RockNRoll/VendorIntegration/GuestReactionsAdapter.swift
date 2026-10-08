import AVFoundation
import Combine
import ConferenceCore
import JazzSDK
import UIKit

@MainActor
final class GuestReactionsAdapter {
    let model: MeetingReactionsModel
    private let state: JazzActiveConferenceState
    private let studio: StudioModel
    private let valid: () -> Bool
    private let transportReady: () -> Bool
    private let cameraAllowed: () -> Bool
    private let cameraObserver = CameraReactionObserver()
    private var capabilityObservation: NSKeyValueObservation?
    private var capabilityDeviceID: String?
    private var observedSourceID: String?
    private var subscriptions = Set<AnyCancellable>()
    private var notifications: [NSObjectProtocol] = []

    init(model: MeetingReactionsModel, state: JazzActiveConferenceState,
         coordinator: JazzActiveConferenceCoordinator, studio: StudioModel,
         valid: @escaping () -> Bool, transportReady: @escaping () -> Bool,
         cameraAllowed: @escaping () -> Bool) {
        self.model = model; self.state = state; self.studio = studio
        self.valid = valid; self.transportReady = transportReady; self.cameraAllowed = cameraAllowed
        model.sender = { [weak self] kind in
            guard let self, self.valid(), self.transportReady(), self.state.isToggleReactionsVisible else { return false }
            let reaction: JazzConferenceReaction
            switch kind { case .like: reaction = .like; case .dislike: reaction = .dislike }
            coordinator.sendReaction(reaction: reaction)
            return true
        }
        cameraObserver.onReaction = { [weak self] kind, id in
            #if DEBUG
            if let self { GuestReactionFixtureActions.trace("Received \(kind.rawValue): valid=\(self.valid()) camera=\(self.cameraAllowed()) active=\(UIApplication.shared.applicationState == .active) sameSource=\(self.cameraSource?.id == self.observedSourceID) ready=\(self.model.canSend) preference=\(self.model.shareCameraReactions) status=\(self.model.cameraStatus)") }
            #endif
            guard let self, self.valid(), self.cameraAllowed(),
                  UIApplication.shared.applicationState == .active,
                  let sourceID = self.observedSourceID, self.cameraSource?.id == sourceID else { return }
            let sent = self.model.send(kind, source: .camera, effectID: id)
            #if DEBUG
            GuestReactionFixtureActions.trace("Forwarded \(kind.rawValue): \(sent)")
            #endif
        }
        model.onPreferenceChanged = { [weak self] in self?.cameraObserver.stop(); self?.refresh() }
        let changes: [AnyPublisher<Void, Never>] = [state.$cameraState.map { _ in () }.eraseToAnyPublisher(),
            state.$isToggleReactionsVisible.map { _ in () }.eraseToAnyPublisher(),
            studio.presenter.objectWillChange.map { _ in () }.eraseToAnyPublisher()]
        Publishers.MergeMany(changes).receive(on: DispatchQueue.main).sink { [weak self] in self?.refresh() }
            .store(in: &subscriptions)
        for name in [GuestCaptureDeviceObserver.changed, UIApplication.didBecomeActiveNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willResignActiveNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopCameraObservation(); self?.setStatus(.paused) }
            })
        }
        refresh()
    }
    func refresh() {
        let available = valid() && state.isToggleReactionsVisible
        let ready = valid() && transportReady()
        if model.available != available { model.available = available }
        if model.ready != ready { model.ready = ready }
        guard valid(), cameraAllowed(), UIApplication.shared.applicationState == .active else {
            stopCameraObservation(); setStatus(.paused); return
        }
        guard let source = cameraSource else {
            stopCameraObservation(); setStatus(hasPublishedCamera ? .unavailable : .off); return
        }
        let device = source.device
        studio.liveCaptureDevice = { GuestCaptureDeviceObserver.currentDevice() }
        observeCapability(device)
        guard #available(iOS 17.0, *), device.canPerformReactionEffects else {
            cameraObserver.stop(); setStatus(.unavailable); return
        }
        setStatus(AVCaptureDevice.reactionEffectGesturesEnabled ? .ready : .systemDisabled)
        // System controls can still perform effects while hand gestures are disabled.
        if model.shareCameraReactions && model.canSend {
            observedSourceID = source.id
            cameraObserver.bind(device, sourceID: source.id)
        } else { cameraObserver.stop(); observedSourceID = nil }
    }
    private var cameraSource: (device: AVCaptureDevice, id: String)? {
        let presenter = studio.presenter
        guard hasPublishedCamera else { return nil }
        if presenter.running {
            if let device = presenter.cameraDevice { return (device, presenter.cameraGeneration.uuidString) }
            if let source = GuestCaptureDeviceObserver.currentSource() {
                return (source.device, "\(presenter.cameraGeneration):\(source.generation)")
            }
        } else if let source = GuestCaptureDeviceObserver.currentSource() {
            return (source.device, source.generation.uuidString)
        }
        return nil
    }
    private var hasPublishedCamera: Bool {
        let presenter = studio.presenter
        return presenter.running ? presenter.includeCamera && presenter.hasCameraFrames && !presenter.cameraHiddenInBackground : state.cameraState == .on
    }
    private func setStatus(_ status: MeetingReactionsModel.CameraStatus) {
        if model.cameraStatus != status { model.cameraStatus = status }
    }
    private func observeCapability(_ device: AVCaptureDevice?) {
        guard capabilityDeviceID != device?.uniqueID else { return }
        capabilityObservation = nil; capabilityDeviceID = device?.uniqueID
        guard #available(iOS 17.0, *), let device else { return }
        let id = device.uniqueID
        capabilityObservation = device.observe(\.canPerformReactionEffects, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard self?.capabilityDeviceID == id else { return }
                self?.refresh()
            }
        }
    }
    private func stopCameraObservation() {
        cameraObserver.stop(); observedSourceID = nil; capabilityObservation = nil; capabilityDeviceID = nil
    }
    func stop() {
        stopCameraObservation(); subscriptions = []
        notifications.forEach(NotificationCenter.default.removeObserver); notifications = []
        model.sender = nil; model.onPreferenceChanged = nil
    }
    deinit { notifications.forEach(NotificationCenter.default.removeObserver) }
}
