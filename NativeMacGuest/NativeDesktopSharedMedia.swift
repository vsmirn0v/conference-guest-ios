import AppKit
import AVFoundation
import Combine
import ConferenceCore
import Foundation
import MeetingEngine

/// App activity AND a visible window are required. Menu-bar residency alone
/// cannot start sensors. Camera metadata has no capture and retains its barrier.
@MainActor final class NativeDesktopForegroundMedia {
    static let shared = NativeDesktopForegroundMedia()
    private let power = NativeDesktopPowerMonitor()
    private var subscriptions = Set<AnyCancellable>()
    private var started = false
    private var stopped = false
    private var metadata: Task<Void, Never>?
    private var updateSuspension: (id: UUID, token: NativeDesktopSharedMedia<GuestSystemAudio>.Suspension)?
    private weak var homeWindow: NSWindow?
    private var foregroundWindowVisible: Bool { NSApp.isActive && homeWindow?.isVisible == true && homeWindow?.isMiniaturized == false }
    func setHomeWindow(_ window: NSWindow) {
        homeWindow = window
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }
    func start() {
        guard !started else { return }; started = true
        power.start { [weak self] in self?.refresh() }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.willCloseNotification, UserDefaults.didChangeNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                // Visibility notifications can precede the actual state change.
                DispatchQueue.main.async { self?.refresh() }
            }.store(in: &subscriptions)
        }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in NativeDesktopCameraMetadataPreparation.shared.invalidate(); self?.refresh() }
            }.store(in: &subscriptions)
        }
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }
    func refresh() {
        // Nothing is prepared before launch starts the service (never in tests).
        guard started, !stopped else { return }
        let foreground = foregroundWindowVisible
        let policy = NativeDesktopJoinReadinessPolicy.current(), state = power.snapshot
        let wakeWordEnabled = AssistantVoicePreferences.loadWakeWordEnabled()
        let microphone = policy.microphone.allows(state)
        // With one engine for all meetings, the shared engine itself prepares idle input.
#if DEBUG || NATIVE_LEGACY_AUDIO
        if SharedAudioEngine.enabledAtLaunch {
            // Refresh voice-reply & speech-input state without overriding AssistantSpeechInputCoordinator's wake-listening ownership.
            if !wakeWordEnabled {
                SharedAudioEngine.shared.setAssistantWakeListening(false)
            }
            SharedAudioEngine.shared.setForeground(foreground, microphone: microphone)
        } else {
            NativeDesktopMediaService.shared.setForeground(foreground, microphone: microphone, profile: .saved)
        }
        let mediaBusy = SharedAudioEngine.enabledAtLaunch
            ? (SharedAudioEngine.shared.busy || UniversalMeetingEngine.shared.busy)
            : NativeDesktopMediaService.shared.busy
#else
        // Refresh voice-reply & speech-input state without overriding AssistantSpeechInputCoordinator's wake-listening ownership.
        if !wakeWordEnabled {
            SharedAudioEngine.shared.setAssistantWakeListening(false)
        }
        SharedAudioEngine.shared.setForeground(foreground, microphone: microphone)
        let mediaBusy = SharedAudioEngine.shared.busy || UniversalMeetingEngine.shared.busy
#endif
        guard foreground, !mediaBusy, policy.camera.allows(state), metadata == nil else { return }
        metadata = Task { [weak self] in
            defer { self?.metadata = nil }
            _ = try? await NativeDesktopCameraMetadataPreparation.shared.prepare(eligible: {
#if DEBUG || NATIVE_LEGACY_AUDIO
                let busy = SharedAudioEngine.enabledAtLaunch
                    ? (SharedAudioEngine.shared.busy || UniversalMeetingEngine.shared.busy)
                    : NativeDesktopMediaService.shared.busy
#else
                let busy = SharedAudioEngine.shared.busy || UniversalMeetingEngine.shared.busy
#endif
                return self?.stopped == false && !busy && self?.foregroundWindowVisible == true &&
                    NativeDesktopJoinReadinessPolicy.current().camera.allows(self?.power.snapshot ?? state)
            }, deviceID: UserDefaults.standard.string(forKey: "nativeDesktop.cameraID"))
        }
    }
    func shutdown() async -> Bool {
        stopped = true; subscriptions.removeAll(); power.stop(); metadata?.cancel()
        if let value = updateSuspension {
            NativeDesktopMediaService.shared.resume(value.token, clean: true)
            if SharedAudioEngine.enabledAtLaunch { SharedAudioEngine.shared.resumeIdle(clean: true) }
            updateSuspension = nil
        }
        let sharedClean = SharedAudioEngine.enabledAtLaunch ? await SharedAudioEngine.shared.shutdownIdle() : true
        return await NativeDesktopMediaService.shared.shutdown() && sharedClean
    }
    func prepareForUpdate(_ id: UUID) async -> Bool {
        if let value = updateSuspension { return value.id == id }
        if SharedAudioEngine.enabledAtLaunch && UniversalMeetingEngine.shared.busy { return false }
        do {
            let token = try await NativeDesktopMediaService.shared.suspend()
            if SharedAudioEngine.enabledAtLaunch {
                let idleSuspended = UniversalMeetingEngine.shared.busy ? false : await SharedAudioEngine.shared.suspendIdle()
                if !idleSuspended {
                    NativeDesktopMediaService.shared.resume(token, clean: true)
                    return false
                }
            }
            updateSuspension = (id, token); return true
        } catch { return false }
    }
    func prepareForUpdateIfDrained(_ id: UUID) -> Bool {
        if let value = updateSuspension { return value.id == id }
        if SharedAudioEngine.enabledAtLaunch && UniversalMeetingEngine.shared.busy { return false }
        guard let token = NativeDesktopMediaService.shared.suspendIfDrained() else { return false }
        if SharedAudioEngine.enabledAtLaunch && (UniversalMeetingEngine.shared.busy || !SharedAudioEngine.shared.suspendIdleIfDrained()) {
            NativeDesktopMediaService.shared.resume(token, clean: true)
            return false
        }
        updateSuspension = (id, token); return true
    }
    func cancelUpdatePreparation(_ id: UUID) {
        if let value = updateSuspension, value.id == id {
            NativeDesktopMediaService.shared.resume(value.token, clean: true)
            if SharedAudioEngine.enabledAtLaunch { SharedAudioEngine.shared.resumeIdle(clean: true) }
            updateSuspension = nil
        }
    }
}
