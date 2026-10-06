import AVFoundation
import Combine
import UIKit

enum StudioAudioProfile: String, CaseIterable {
    case conversation, music
    var title: String { self == .conversation ? L("Conversation") : L("Music") }
}

/// Meeting-scoped intent. Opening Studio never starts capture or changes mute state.
@MainActor
final class StudioModel: ObservableObject {
    enum AudioControl { case noiseSuppression, fullProcessing }
    @Published private(set) var profile: StudioAudioProfile = .conversation
    @Published private(set) var applying = false
    @Published private(set) var error: String?
    @Published private(set) var active = true
    @Published var cameraOn = false
    @Published var microphoneOn = false
    @Published var held = false
    @Published private(set) var systemMicrophoneMode = L("Standard")
    @Published private(set) var observedNoiseSuppression: Bool?
    let audioControl: AudioControl
    private(set) var hasSelection = false
    var applyProfile: ((StudioAudioProfile) async throws -> Void)?
    var openSystemSettings: (AVCaptureDevice.SystemUserInterface) -> Void = {
        AVCaptureDevice.showSystemUserInterface($0)
    }
    private var change: Task<Void, Never>?

    init(audioControl: AudioControl) { self.audioControl = audioControl }

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
        switch AVCaptureDevice.activeMicrophoneMode {
        case .voiceIsolation: systemMicrophoneMode = L("Voice Isolation")
        case .wideSpectrum: systemMicrophoneMode = L("Wide Spectrum")
        default: systemMicrophoneMode = L("Standard")
        }
    }

    func showSystemSettings(_ kind: AVCaptureDevice.SystemUserInterface) {
        guard systemSettingsAvailable, kind == .videoEffects ? cameraOn : microphoneOn else { return }
        openSystemSettings(kind)
    }

    func end() {
        active = false
        change?.cancel(); change = nil
        applying = false
        applyProfile = nil
    }
}
