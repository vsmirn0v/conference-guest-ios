import AVFoundation
import Combine
import UIKit

/// The iOS system sheet is not presented by UIKit-on-Mac. macOS owns its
/// menu-bar controls; offer actionable guidance instead of a silent button.
enum SystemMediaSettingsHelp: String, Identifiable {
    case camera, microphone
    var id: String { rawValue }
    var title: String { self == .camera ? L("Camera effects") : L("System microphone settings") }
    var message: String {
        self == .camera
            ? L("While this preview is active, click the green camera icon in the macOS menu bar. Choose Video Effects to change background, lighting or framing. Available effects depend on your camera.")
            : L("While your microphone or private check is active, click the microphone or camera icon in the macOS menu bar. Choose Mic Mode to select Standard, Voice Isolation or Wide Spectrum when available.")
    }
}

enum StudioAudioProfile: String, CaseIterable {
    case conversation, music
    var title: String { self == .conversation ? L("Conversation") : L("Music") }
}

/// Capture for private preview is independent of publication intent.
@MainActor
final class StudioModel: ObservableObject {
    enum AudioControl { case noiseSuppression, fullProcessing }
    @Published private(set) var profile: StudioAudioProfile = .conversation
    @Published private(set) var applying = false
    @Published private(set) var error: String?
    @Published private(set) var active = true
    enum Pane: String, CaseIterable { case camera, sound, presenter }
    enum AudioSection { case sound, devices }
    @Published var audioSection: AudioSection = .sound
    @Published var canvasExpanded = false
    let presenter = PresenterModel()
    let recording = MeetingRecording()
    let microphoneActivity = MicrophoneActivity()
    var reactions: MeetingReactionsModel?
    let soundCheck: PrivateSoundCheck
    @Published var pane: Pane = .camera { didSet { if pane != oldValue { if pane != .presenter { canvasExpanded = false }; refreshPreview(); refreshPresenter(); soundCheck.stop() } } }
    @Published private(set) var presented = false
    @Published private(set) var previewView: UIView?
    @Published private(set) var previewRunning = false
    @Published private(set) var previewLoading = false
    @Published private(set) var previewError: String?
    @Published private(set) var startingVideo = false
    @Published var cameraOn = false { didSet { if cameraOn != oldValue { refreshPreview(); presenter.update(cameraOn: cameraOn, held: held) } } }
    @Published var microphoneOn = false { didSet { if microphoneOn { soundCheck.stop() } } }
    @Published var held = false { didSet { if held != oldValue { soundCheck.stop(); refreshPreview(); presenter.update(cameraOn: cameraOn, held: held) } } }
    @Published private(set) var systemMicrophoneMode = L("Standard")
    @Published private(set) var cameraEffects: [CameraEffectStatus] = []
    @Published private(set) var automaticFramingEnabled = false
    @Published private(set) var automaticFramingSupported = false
    private let framingPolicy: CameraFramingPolicy
    @Published var systemSettingsHelp: SystemMediaSettingsHelp?
    var liveCaptureDevice: (() -> AVCaptureDevice?)?
    @Published private(set) var observedNoiseSuppression: Bool?
    let audioControl: AudioControl
    private(set) var hasSelection = false
    var applyProfile: ((StudioAudioProfile) async throws -> Void)?
    var enableCamera: (() -> Void)?
    var enableMicrophone: (() -> Void)?
    /// Device selection is shared by private preview and the next publication.
    var selectLiveCamera: ((AVCaptureDevice) async throws -> Void)?
    var onCameraSelectionChanged: ((AVCaptureDevice?) -> Void)? {
        didSet { onCameraSelectionChanged?(selectedCameraDevice) }
    }
    @Published private(set) var selectedCameraDevice: AVCaptureDevice?
    @Published private(set) var switchingCamera = false
    @Published private(set) var availableCameraCount = 0
    private var cameraSelectionTask: Task<Void, Never>?
    var canFlipCamera: Bool {
        active && !held && !startingVideo && !switchingCamera && !presenter.running &&
            availableCameraCount > 1 && (!cameraOn || selectLiveCamera != nil)
    }
    var makeLivePreview: (() -> StudioLivePreview?)?
    private let privateCamera: PrivateCameraPreviewing
    private let preferences: UserDefaults?
    private static let profileKey = "studio.audio-profile"
    private var livePreview: StudioLivePreview?
    private var liveCameraIdentity: ObjectIdentifier?
    private var previewTask: Task<Void, Never>?
    private var previewGeneration = UUID()
    private var backgroundObserver: NSObjectProtocol?
    private var cameraDeviceObservers: [NSObjectProtocol] = []
    var openSystemSettings: (AVCaptureDevice.SystemUserInterface) -> Void = {
        AVCaptureDevice.showSystemUserInterface($0)
    }
    private var change: Task<Void, Never>?

    init(audioControl: AudioControl, privateCamera: PrivateCameraPreviewing? = nil, preferences: UserDefaults? = nil, privateMicrophone: PrivateMicrophoneCapturing? = nil, framingPolicy: CameraFramingPolicy? = nil) {
        self.audioControl = audioControl
        soundCheck = PrivateSoundCheck(capture: privateMicrophone)
        self.privateCamera = privateCamera ?? PrivateCameraPreview()
        self.preferences = preferences
        self.framingPolicy = framingPolicy ?? .shared
        automaticFramingEnabled = self.framingPolicy.synchronize()
        let devices = CameraDevices.available()
        availableCameraCount = devices.count
        selectedCameraDevice = CameraDevices.preferred(in: devices)
        presenter.openCameraEffects = { [weak self] in self?.showSystemSettings(.videoEffects) }
        if let raw = preferences?.string(forKey: Self.profileKey), let saved = StudioAudioProfile(rawValue: raw) {
            profile = saved
            hasSelection = true
        }
        for notification in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            cameraDeviceObservers.append(NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshCameraDevices() }
            })
        }
        cameraDeviceObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystemSelection() }
        })
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
    }

    deinit {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        cameraDeviceObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func open(_ pane: Pane) {
        guard active else { return }
        refreshSystemSelection()
        self.pane = pane
        presented = true
        refreshPreview()
        refreshPresenter()
    }

    func close() {
        presented = false
        systemSettingsHelp = nil
        canvasExpanded = false
        soundCheck.stop()
        refreshPreview()
        refreshPresenter()
    }

    private func refreshPresenter() {
        if presented && pane == .presenter && active { presenter.open() } else { presenter.close() }
    }

    private func refreshPreview() {
        previewGeneration = UUID()
        let generation = previewGeneration
        previewTask?.cancel()
        livePreview?.stop(); livePreview = nil
        previewView = nil; previewRunning = false; previewError = nil
        let wanted = presented && pane == .camera && active && !held && !startingVideo && !presenter.running
        previewLoading = wanted
        previewTask = Task { @MainActor [weak self, privateCamera] in
            await privateCamera.stop()
            guard let self, self.previewGeneration == generation, wanted else { return }
            do {
                try Task.checkCancellation()
                if self.cameraOn {
                    self.livePreview = self.makeLivePreview?()
                    self.previewView = self.livePreview?.view
                    if self.previewView == nil { self.previewError = L("Waiting for your camera…") }
                } else {
                    await self.presenter.releaseCamera()
                    guard self.previewGeneration == generation else { return }
                    privateCamera.selectDevice(self.selectedCameraDevice)
                    try await privateCamera.start()
                    try Task.checkCancellation()
                    guard self.previewGeneration == generation else { return }
                    self.previewView = privateCamera.view
                    self.previewRunning = true
                }
            } catch is CancellationError {
            } catch {
                guard self.previewGeneration == generation else { return }
                self.previewError = error.localizedDescription
            }
            guard self.previewGeneration == generation else { return }
            self.previewLoading = false
        }
    }

    /// Release private capture before publishing; renegotiation must retain live previews.
    func releasePrivateCamera() async {
        // Engine publication also enters here from the in-call camera button.
        // Finish a preflight selection before the SDK acquires its device.
        await cameraSelectionTask?.value
        if cameraOn { await privateCamera.stop() }
        else { await releasePreviewCamera() }
        await presenter.releasePrivateCamera()
    }

    func releasePreviewCamera() async {
        previewGeneration = UUID()
        previewTask?.cancel(); previewTask = nil
        previewRunning = false; previewLoading = false; previewView = nil
        livePreview?.stop(); livePreview = nil
        await privateCamera.stop()
    }

    func startVideo() async -> Bool {
        guard active, !held, !startingVideo, !switchingCamera, !cameraOn, let enableCamera else { return false }
        startingVideo = true
        await releasePrivateCamera()
        guard active, !held, presented else { startingVideo = false; return false }
        enableCamera()
        startingVideo = false
        close()
        return true
    }

    func flipCamera() {
        refreshCameraDevices()
        guard canFlipCamera else { return }
        let devices = CameraDevices.available()
        let current = (cameraOn ? liveCaptureDevice?() : nil) ?? selectedCameraDevice
        guard let nextID = CameraDevices.nextID(in: devices.map(\.uniqueID), current: current?.uniqueID),
              let next = devices.first(where: { $0.uniqueID == nextID }) else { return }
        let wasSending = cameraOn
        switchingCamera = true
        previewError = nil
        cameraSelectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if wasSending {
                    try await self.selectLiveCamera?(next)
                } else {
                    await self.releasePreviewCamera()
                }
                try Task.checkCancellation()
                guard self.active, !self.held else { self.switchingCamera = false; return }
                self.selectedCameraDevice = next
                self.onCameraSelectionChanged?(next)
                self.privateCamera.selectDevice(next)
                self.presenter.selectPrivateCamera(next)
                self.switchingCamera = false
                self.liveCameraChanged()
            } catch is CancellationError {
                self.switchingCamera = false
                self.refreshPreview()
            } catch {
                self.switchingCamera = false
                self.refreshPreview()
                self.previewError = L("Camera could not switch: %@", error.localizedDescription)
            }
            self.cameraSelectionTask = nil
        }
    }
    private func refreshCameraDevices() {
        let devices = CameraDevices.available()
        if availableCameraCount != devices.count { availableCameraCount = devices.count }
        let selected = devices.first { $0.uniqueID == selectedCameraDevice?.uniqueID } ?? CameraDevices.preferred(in: devices)
        if selectedCameraDevice?.uniqueID != selected?.uniqueID || selectedCameraDevice?.isConnected == false {
            selectedCameraDevice = selected
            onCameraSelectionChanged?(selected)
        }
    }
    func liveCameraChanged() { refreshPreview(); presenter.liveCameraChanged() }
    /// Camera replacement can occur during recovery without an off/on UI transition.
    func observeLiveCamera(_ identity: ObjectIdentifier?) {
        guard liveCameraIdentity != identity else { return }
        liveCameraIdentity = identity
        liveCameraChanged()
    }

    #if DEBUG
    /// Direct-launch physical checks must not depend on XCTest keeping the app alive.
    func applyTestProfileIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["CONFERENCE_TEST_SOUND_PROFILE"],
              let profile = StudioAudioProfile(rawValue: raw) else { return }
        select(profile)
    }
    #endif

    var systemSettingsAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return active && !held && UIApplication.shared.applicationState == .active
        #endif
    }

    var audioExplanation: String {
        switch audioControl {
        case .noiseSuppression:
            return L("Music reduces noise suppression. Other audio processing is controlled by the meeting.")
        case .fullProcessing:
            return L("Music reduces speech filtering and automatic gain changes, while keeping echo protection. Headphones give the best result.")
        }
    }

    func select(_ next: StudioAudioProfile) {
        guard active, !applying, !held, let applyProfile, next != profile || !hasSelection else { return }
        let previous = profile
        applying = true
        error = nil
        change = Task { @MainActor [weak self] in
            do {
                try await applyProfile(next)
                try Task.checkCancellation()
                guard let self, self.active else { return }
                self.profile = next
                self.hasSelection = true
                self.preferences?.set(next.rawValue, forKey: Self.profileKey)
            } catch is CancellationError {
            } catch {
                guard let self, self.active else { return }
                self.profile = previous
                self.error = L("Sound settings could not update. Try again.")
            }
            self?.applying = false
            self?.change = nil
        }
    }

    func observeNoiseSuppression(_ enabled: Bool) {
        observedNoiseSuppression = enabled
        if !hasSelection && !applying { profile = enabled ? .conversation : .music }
    }

    func reportUpdateFailure() { error = L("Sound settings could not update. Try again.") }

    func refreshSystemSelection() {
        refreshCameraDevices()
        let device = !held && active ? (presenter.cameraDevice ?? (cameraOn ? liveCaptureDevice?() : (previewRunning ? privateCamera.device : nil))) : nil
        let selectedFraming = framingPolicy.synchronize()
        if automaticFramingEnabled != selectedFraming { automaticFramingEnabled = selectedFraming }
        let supportsFraming = (device ?? selectedCameraDevice)?.activeFormat.isCenterStageSupported == true
        if automaticFramingSupported != supportsFraming { automaticFramingSupported = supportsFraming }
        let effects = CameraEffectStatus.read(device: device)
        if effects != cameraEffects { cameraEffects = effects }
        let mode: String
        switch AVCaptureDevice.activeMicrophoneMode {
        case .voiceIsolation: mode = L("Voice Isolation")
        case .wideSpectrum: mode = L("Wide Spectrum")
        default: mode = L("Standard")
        }
        if systemMicrophoneMode != mode { systemMicrophoneMode = mode }
    }

    func setAutomaticFraming(_ enabled: Bool) {
        guard active, !held, automaticFramingSupported else { return }
        automaticFramingEnabled = framingPolicy.setEnabled(enabled)
        refreshSystemSelection()
    }

    func showSystemSettings(_ kind: AVCaptureDevice.SystemUserInterface) {
        guard systemSettingsAvailable, kind == .videoEffects ? (cameraOn || previewRunning || presenter.cameraDevice != nil) : (microphoneOn || soundCheck.capturing) else { return }
        if ProcessInfo.processInfo.isiOSAppOnMac {
            systemSettingsHelp = kind == .videoEffects ? .camera : .microphone
            return
        }
        openSystemSettings(kind)
    }

    func testMicrophone() {
        guard active, presented, pane == .sound, !held, !microphoneOn else { return }
        soundCheck.start(standalone: enableMicrophone == nil)
    }

    func releasePrivateMicrophone() { soundCheck.stop() }

    func end() {
        active = false
        cameraSelectionTask?.cancel(); cameraSelectionTask = nil; switchingCamera = false
        recording.end()
        microphoneActivity.setStatus(.unavailable)
        soundCheck.verifyMuted = nil
        presenter.end()
        change?.cancel(); change = nil
        applying = false
        applyProfile = nil
        enableCamera = nil; enableMicrophone = nil; selectLiveCamera = nil; onCameraSelectionChanged = nil; makeLivePreview = nil; liveCaptureDevice = nil
        close()
    }
}
