import AVFoundation
import Combine
import UIKit

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
    enum Pane: String, CaseIterable { case camera, sound }
    @Published var pane: Pane = .camera { didSet { if pane != oldValue { refreshPreview() } } }
    @Published private(set) var presented = false
    @Published private(set) var previewView: UIView?
    @Published private(set) var previewRunning = false
    @Published private(set) var previewLoading = false
    @Published private(set) var previewError: String?
    @Published private(set) var startingVideo = false
    @Published var cameraOn = false { didSet { if cameraOn != oldValue { refreshPreview() } } }
    @Published var microphoneOn = false
    @Published var held = false { didSet { if held != oldValue { refreshPreview() } } }
    @Published private(set) var systemMicrophoneMode = L("Standard")
    @Published private(set) var observedNoiseSuppression: Bool?
    let audioControl: AudioControl
    private(set) var hasSelection = false
    var applyProfile: ((StudioAudioProfile) async throws -> Void)?
    var enableCamera: (() -> Void)?
    var enableMicrophone: (() -> Void)?
    var flipLiveCamera: (() -> Void)?
    var makeLivePreview: (() -> StudioLivePreview?)?
    private let privateCamera: PrivateCameraPreviewing
    private let preferences: UserDefaults?
    private static let profileKey = "studio.audio-profile"
    private var livePreview: StudioLivePreview?
    private var previewTask: Task<Void, Never>?
    private var previewGeneration = UUID()
    private var backgroundObserver: NSObjectProtocol?
    var openSystemSettings: (AVCaptureDevice.SystemUserInterface) -> Void = {
        AVCaptureDevice.showSystemUserInterface($0)
    }
    private var change: Task<Void, Never>?

    init(audioControl: AudioControl, privateCamera: PrivateCameraPreviewing? = nil, preferences: UserDefaults? = nil) {
        self.audioControl = audioControl
        self.privateCamera = privateCamera ?? PrivateCameraPreview()
        self.preferences = preferences
        if let raw = preferences?.string(forKey: Self.profileKey), let saved = StudioAudioProfile(rawValue: raw) {
            profile = saved
            hasSelection = true
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
    }

    deinit { if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) } }

    func open(_ pane: Pane) {
        guard active else { return }
        self.pane = pane
        presented = true
        refreshPreview()
    }

    func close() {
        presented = false
        refreshPreview()
    }

    private func refreshPreview() {
        previewGeneration = UUID()
        let generation = previewGeneration
        previewTask?.cancel()
        livePreview?.stop(); livePreview = nil
        previewView = nil; previewRunning = false; previewError = nil
        let wanted = presented && pane == .camera && active && !held && !startingVideo
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

    /// Every publishing entry point awaits camera release, including a short toolbar tap.
    func releasePrivateCamera() async {
        previewGeneration = UUID()
        previewTask?.cancel(); previewTask = nil
        previewRunning = false; previewLoading = false; previewView = nil
        livePreview?.stop(); livePreview = nil
        await privateCamera.stop()
    }

    func startVideo() async -> Bool {
        guard active, !held, !startingVideo, !cameraOn, let enableCamera else { return false }
        startingVideo = true
        await releasePrivateCamera()
        guard active, !held, presented else { startingVideo = false; return false }
        enableCamera()
        startingVideo = false
        close()
        return true
    }

    func flipCamera() {
        guard active, !held, cameraOn else { return }
        flipLiveCamera?()
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
        let mode: String
        switch AVCaptureDevice.activeMicrophoneMode {
        case .voiceIsolation: mode = L("Voice Isolation")
        case .wideSpectrum: mode = L("Wide Spectrum")
        default: mode = L("Standard")
        }
        if systemMicrophoneMode != mode { systemMicrophoneMode = mode }
    }

    func showSystemSettings(_ kind: AVCaptureDevice.SystemUserInterface) {
        guard systemSettingsAvailable, kind == .videoEffects ? (cameraOn || previewRunning) : microphoneOn else { return }
        openSystemSettings(kind)
    }

    func end() {
        active = false
        change?.cancel(); change = nil
        applying = false
        applyProfile = nil
        enableCamera = nil; enableMicrophone = nil; flipLiveCamera = nil; makeLivePreview = nil
        close()
    }
}
