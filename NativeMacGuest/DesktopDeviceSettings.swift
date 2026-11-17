import AppKit
import AVFoundation
import Combine
import LiveKitWebRTC
import SwiftUI

@MainActor protocol NativeDesktopPrivateAudioOwner: AnyObject {
    var privateInputLevel: Float? { get }
    func startPrivateCheck() async -> Bool
    func closePrivateCheck() async -> Bool
}
extension GuestSystemAudio: NativeDesktopPrivateAudioOwner {
    func startPrivateCheck() async -> Bool { await startStandalonePrivateInputCheck() }
    func closePrivateCheck() async -> Bool { await shutdown() }
}

/// The prejoin microphone check while the shared owner is pinned: it borrows the shared
/// engine's input (no meeting may be sending meanwhile) instead of a second owner.
@MainActor final class SharedPrivateAudioCheck: NativeDesktopPrivateAudioOwner {
    private let engine: SharedAudioEngine
    init(engine: SharedAudioEngine) { self.engine = engine }
    var privateInputLevel: Float? { engine.guestOwner?.privateInputLevel }
    func startPrivateCheck() async -> Bool {
        guard await engine.beginPrivateCheck() else { return false }
        engine.guestOwner?.setPrivateInputMeterEnabled(true)
        return true
    }
    func closePrivateCheck() async -> Bool {
        engine.guestOwner?.setPrivateInputMeterEnabled(false)
        return await engine.endPrivateCheck()
    }
}

@MainActor final class NativeDesktopDeviceModel: ObservableObject {
    private static weak var activePreview: NativeDesktopDeviceModel?
    let audio = MacAudioDevices(isMac: true)
    @Published var audioSnapshot = MacAudioSnapshot()
    @Published var cameras: [AVCaptureDevice] = []
    @Published var cameraID: String
    @Published var previewTrack: LKRTCVideoTrack?
    @Published var borrowedLiveTrack: LKRTCVideoTrack?
    @Published var previewing = false
    @Published var checkingAudio = false
    @Published var audioLevel: Float = 0
    @Published var error: String?
    private var subscriptions = Set<AnyCancellable>()
    private var preview: GuestCamera?
    private var factory: LKRTCPeerConnectionFactory?
    private var previewTask: Task<Void, Never>?
    private var generation = UUID()
    private var stopping: Task<Bool, Never>?
    private var cleanupFailed = false
    private let cameraOwnerID = UUID()
    private var cameraLease: NativeDesktopCameraLease.Token?
    private var audioOwner: (any NativeDesktopPrivateAudioOwner)?
    private var resumeReadiness: ((Bool) -> Void)?
    private let authorizeAudio: () async throws -> Bool
    private let createAudioOwner: () async throws -> any NativeDesktopPrivateAudioOwner
    private let suspendReadiness: () async throws -> ((Bool) -> Void)
    private var audioTask: Task<Void, Never>?
    private var audioGeneration = UUID()
    private var stopBorrowedAudio: (() async throws -> Void)?
    private var audioStopping: Task<Bool, Never>?
    private var discovery: Task<Void, Never>?
    static func stopPrivatePreview() async -> Bool { await activePreview?.stop() ?? true }
    /// Live camera capture conflicts only with the private camera preview; a
    /// running private microphone check keeps going.
    static func stopPrivateCameraPreview() async -> Bool { await activePreview?.stopCamera() ?? true }
    /// Linear RMS to a -60...0 dBFS meter: speech (about -30...-20 dBFS) fills half
    /// to two thirds of the bar instead of 3-10%.
    static func meterLevel(rms: Float?) -> Float {
        guard let rms, rms.isFinite, rms > 0 else { return 0 }
        return min(1, max(0, (20 * log10(rms) + 60) / 60))
    }
    init(discoverCameras: @escaping @Sendable () -> [AVCaptureDevice] = { AVCaptureDevice.devices(for: .video) },
         authorizeAudio: (() async throws -> Bool)? = nil,
         createAudioOwner: (() async throws -> any NativeDesktopPrivateAudioOwner)? = nil,
         suspendReadiness: (() async throws -> ((Bool) -> Void))? = nil) {
        self.authorizeAudio = authorizeAudio ?? { try await GuestCaptureAuthorization.request(.audio) }
        self.createAudioOwner = createAudioOwner ?? {
            if SharedAudioEngine.enabledAtLaunch {
                return SharedPrivateAudioCheck(engine: SharedAudioEngine.shared)
            }
            // Same native setup as the meeting owner: without its media context the
            // M156 audio engine blocks in start-recording (measured > 8 s, no buffers).
            return try await GuestSystemAudio.create(microphoneEnabled: false, playoutEnabled: false, profile: .saved,
                                                     privateCheckOnly: true, exclusive: true)
        }
        self.suspendReadiness = suspendReadiness ?? {
            if SharedAudioEngine.enabledAtLaunch {
                if SharedAudioEngine.shared.pinnedForProcess || !SharedAudioEngine.shared.hasModule { return { _ in } }
                guard await SharedAudioEngine.shared.suspendIdle() else { throw NativeDesktopRTCError.cleanupFailed }
                return { SharedAudioEngine.shared.resumeIdle(clean: $0) }
            }
            let token = try await NativeDesktopMediaService.shared.suspend()
            return { NativeDesktopMediaService.shared.resume(token, clean: $0) }
        }
        cameraID = UserDefaults.standard.string(forKey: "nativeDesktop.cameraID") ?? ""
        discovery = Task { [weak self] in
            let devices = await Task.detached(priority: .userInitiated, operation: discoverCameras).value
            guard !Task.isCancelled else { return }
            self?.cameras = devices
        }
        audio.$snapshot.sink { [weak self] in self?.audioSnapshot = $0 }.store(in: &subscriptions)
        NativeDesktopCameraLease.shared.$liveTrack.sink { [weak self] in self?.borrowedLiveTrack = $0 }.store(in: &subscriptions)
    }
    func selectCamera(_ id: String) {
        cameraID = id; UserDefaults.standard.set(id, forKey: "nativeDesktop.cameraID")
        if previewing { Task { if await stop() { startPreview() } } }
    }
    func selectAudio(_ id: UInt32, direction: MacAudioDirection) {
        do { try audio.select(id, for: direction) } catch { self.error = error.localizedDescription }
    }
    func startAudioCheck(live: Bool, start: (() async throws -> Void)?, stop: (() async throws -> Void)?, level: (() -> Float?)?) {
        guard !checkingAudio, !cleanupFailed else { return }
        checkingAudio = true; error = nil; let token = UUID(); audioGeneration = token
        audioTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let audioStopping, !(await audioStopping.value) { throw NativeDesktopRTCError.cleanupFailed }
                if let other = Self.activePreview, other !== self, !(await other.stop()) { throw NativeDesktopRTCError.cleanupFailed }
                guard audioGeneration == token, !Task.isCancelled else { return }
                Self.activePreview = self
                let granted = try await authorizeAudio()
                guard granted else { throw GuestSystemAudioError.microphonePermissionRequired }
                guard audioGeneration == token, !Task.isCancelled else { return }
                if live {
                    guard let start, let stop, level != nil else { throw NativeDesktopPrivateAudioError.unavailable }
                    stopBorrowedAudio = stop
                    try await start()
                } else {
                    resumeReadiness = try await suspendReadiness()
                    guard audioGeneration == token, !Task.isCancelled else { return }
                    let owner = try await createAudioOwner()
                    guard audioGeneration == token, !Task.isCancelled else {
                        let clean = await owner.closePrivateCheck()
                        cleanupFailed = cleanupFailed || !clean
                        if !clean { audioOwner = owner }
                        return
                    }
                    audioOwner = owner
                    guard await owner.startPrivateCheck() else { throw GuestSystemAudioError.setupFailedOrTimedOut }
                }
                guard audioGeneration == token, !Task.isCancelled else { return }
                while audioGeneration == token, !Task.isCancelled {
                    audioLevel = Self.meterLevel(rms: audioOwner?.privateInputLevel ?? level?())
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            } catch {
                guard audioGeneration == token else { return }
                self.error = error.localizedDescription; checkingAudio = false; audioLevel = 0
                if let stop = stopBorrowedAudio {
                    stopBorrowedAudio = nil
                    do { try await stop() } catch { cleanupFailed = true; self.error = error.localizedDescription }
                }
                if let owner = audioOwner {
                    audioOwner = nil; let clean = await owner.closePrivateCheck(); cleanupFailed = cleanupFailed || !clean
                    if !clean { audioOwner = owner }
                }
                resumeReadiness?(!cleanupFailed); resumeReadiness = nil
            }
        }
    }
    @discardableResult func stopAudioCheck() async -> Bool {
        if let audioStopping { return await audioStopping.value }
        audioGeneration = UUID(); checkingAudio = false; audioLevel = 0
        let task = audioTask; audioTask = nil; task?.cancel()
        let stopping = Task { [self] () -> Bool in
            await task?.value
            let stop = stopBorrowedAudio; stopBorrowedAudio = nil
            do { try await stop?() } catch { cleanupFailed = true }
            let owner = audioOwner; audioOwner = nil
            let clean = await owner?.closePrivateCheck() ?? true
            cleanupFailed = cleanupFailed || !clean
            if !clean { audioOwner = owner }
            resumeReadiness?(!cleanupFailed); resumeReadiness = nil
            return !cleanupFailed
        }
        audioStopping = stopping
        let clean = await stopping.value
        audioStopping = nil; cleanupFailed = cleanupFailed || !clean
        if !previewing, Self.activePreview === self { Self.activePreview = nil }
        if !clean { error = L("Microphone check could not stop. Quit and reopen the app before joining.") }
        return clean && !cleanupFailed
    }
    static func cameraPreviewErrorDescription(_ error: Error) -> String {
        if let cameraError = error as? GuestCameraError, case .permissionDenied = cameraError {
            return L("Allow camera access in Settings to preview your video.")
        }
        return error.localizedDescription
    }

    func startPreview() {
        guard !previewing, !cleanupFailed else { return }
        previewing = true; error = nil; let token = UUID(); generation = token
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let stopping, !(await stopping.value) { throw NativeDesktopRTCError.cleanupFailed }
                if let other = Self.activePreview, other !== self, !(await other.stop()) { throw NativeDesktopRTCError.cleanupFailed }
                guard generation == token, !Task.isCancelled else { return }
                Self.activePreview = self
                let acquisition = try await NativeDesktopCameraLease.shared.acquirePrivate(owner: cameraOwnerID) { [weak self] in
                    guard let self else { return }
                    guard await self.stop() else { throw NativeDesktopRTCError.cleanupFailed }
                }
                guard generation == token, !Task.isCancelled else {
                    if case .owned(let lease) = acquisition { NativeDesktopCameraLease.shared.release(lease) }
                    return
                }
                switch acquisition {
                case .borrowed(let track): previewTrack = track; return
                case .livePending: return
                case .owned(let lease):
                    guard generation == token, !Task.isCancelled else { NativeDesktopCameraLease.shared.release(lease); return }
                    cameraLease = lease
                }
                let factory = await Task.detached(priority: .userInitiated) {
                    LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory())
                }.value
                guard generation == token else { return }
                self.factory = factory
                let source = factory.videoSource()
                let camera = GuestCamera(source: source, deviceID: cameraID.isEmpty ? nil : cameraID)
                preview = camera
                _ = try await camera.start()
                guard generation == token, !Task.isCancelled,
                      let cameraLease, NativeDesktopCameraLease.shared.isCurrent(cameraLease) else {
                    camera.cancel()
                    do { try await camera.stop() }
                    catch { if let cameraLease { NativeDesktopCameraLease.shared.reportFailedStop(cameraLease) } }
                    return
                }
                previewTrack = factory.videoTrack(with: source, trackId: "private-camera-preview")
            } catch {
                guard generation == token else { return }
                self.error = Self.cameraPreviewErrorDescription(error); await stop()
            }
        }
    }
    @discardableResult func stop() async -> Bool {
        let audioClean = await stopAudioCheck()
        let cameraClean = await stopCamera()
        cleanupFailed = cleanupFailed || !audioClean
        return cameraClean && audioClean && !cleanupFailed
    }
    /// Stops only the private camera preview.
    @discardableResult func stopCamera() async -> Bool {
        if let stopping { return await stopping.value && !cleanupFailed }
        generation = UUID(); previewTask?.cancel(); previewTask = nil
        previewTrack = nil; previewing = false
        let old = preview, oldFactory = factory, lease = cameraLease
        preview = nil; factory = nil; cameraLease = nil; old?.cancel()
        let stop = Task { () -> Bool in
            defer { withExtendedLifetime(oldFactory) {} }
            do { try await old?.stop(); return true } catch { return false }
        }
        stopping = stop
        let clean = await stop.value
        stopping = nil; cleanupFailed = cleanupFailed || !clean
        if let lease {
            if clean { NativeDesktopCameraLease.shared.release(lease) }
            else { NativeDesktopCameraLease.shared.reportFailedStop(lease) }
        }
        if !checkingAudio, Self.activePreview === self { Self.activePreview = nil }
        if !clean { error = L("Camera preview could not stop. Quit and reopen the app before starting camera video.") }
        return clean && !cleanupFailed
    }
    deinit { discovery?.cancel() }
}

struct NativeDesktopDeviceSettings: View {
    var liveTrack: LKRTCVideoTrack?
    var settingsPage = false
    var liveAudioAvailable = false
    var startLiveAudioCheck: (() async throws -> Void)?
    var stopLiveAudioCheck: (() async throws -> Void)?
    var liveAudioLevel: (() -> Float?)?
    @StateObject private var model = NativeDesktopDeviceModel()
    @Environment(\.nativeSettingRevealID) private var revealID
    @State private var audioAdvancedExpanded = false
    @State private var cameraAdvancedExpanded = false
    @AppStorage("nativeDesktop.shareCameraReactions") private var shareCameraReactions = true
    @AppStorage(NativeDesktopJoinReadinessPolicy.microphoneKey) private var microphoneReadiness = ""
    @AppStorage(NativeDesktopJoinReadinessPolicy.cameraKey) private var cameraReadiness = ""
    @AppStorage(GuestAudioProfile.preferenceKey) private var profile = GuestAudioProfile.speech.rawValue
    @AppStorage(NativeDesktopMeetingModel.keepMicrophoneWarmKey) private var keepMicrophoneWarm = false
    @AppStorage(NativeDesktopHeadsetMute.Platform.enabledKey) private var headsetMute = false
    @AppStorage(NativeDesktopHeadsetMute.Platform.disabledReasonKey) private var headsetMuteDisabledReason = ""
    private var cameraIsLive: Bool { liveTrack != nil || model.borrowedLiveTrack != nil }

    var body: some View {
        Form {
            Section(L("Audio devices")) {
                audioDevicePicker(L("Microphone"), direction: .input, id: "settings.microphone")
                audioDevicePicker(L("Output"), direction: .output, id: "settings.output")
                Text(L("Device choices follow the Mac’s system audio routes.")).font(.caption).foregroundStyle(.secondary)
                privateCheckButton(model.checkingAudio ? L("Stop microphone check") : L("Check microphone privately"),
                                   id: "settings.microphone-test") {
                    if model.checkingAudio { Task { await model.stopAudioCheck() } }
                    else { model.startAudioCheck(live: liveAudioAvailable, start: startLiveAudioCheck, stop: stopLiveAudioCheck, level: liveAudioLevel) }
                }
                if model.checkingAudio {
                    ProgressView(value: Double(model.audioLevel), total: 1).accessibilityLabel(L("Microphone level"))
                    Text(L("Checking uses the meeting’s microphone when connected. Your mute setting stays unchanged. No recording is saved.")).font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup(L("Advanced audio settings"), isExpanded: $audioAdvancedExpanded) {
                settingsPicker(L("Audio profile"), selection: $profile,
                               choices: [GuestAudioProfile.speech.rawValue, GuestAudioProfile.music.rawValue],
                               titleForChoice: { $0 == GuestAudioProfile.speech.rawValue ? L("Speech") : L("Music") },
                               id: "settings.audio-profile")
                Text(L("Speech uses echo cancellation, noise suppression and automatic gain. Music keeps software echo cancellation and removes noise suppression and automatic gain; room noise and level changes are more audible. Applies to the next meeting.")).font(.caption).foregroundStyle(.secondary)
                settingsPicker(L("Microphone readiness"), selection: Binding(
                    get: { NativeDesktopJoinReadinessPolicy.current().microphone },
                    set: { microphoneReadiness = $0.rawValue }),
                               choices: NativeDesktopMediaReadinessMode.allCases, titleForChoice: { $0.title },
                               id: "settings.mic-readiness", accessibilityID: "settings.microphoneReadiness.control")
                Text(L("Prepares the muted microphone while the app is active with a visible window, so native Guest meetings can reuse it for faster unmuting and headset controls. Muted audio is never sent. Uses extra energy. Bluetooth headsets may switch to call audio quality. Preparation stops shortly after the app becomes inactive. Power changes do not interrupt an active meeting.")).font(.caption).foregroundStyle(.secondary)
                Text(L("Low Power Mode prevents automatic microphone and camera preparation. Preparation uses existing permission. Defaults apply to native Guest meetings; explicit microphone choices also apply to supported headset controls in other meetings.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("Camera")) {
                settingsPicker(L("Camera"), selection: Binding(get: { model.cameraID }, set: { model.selectCamera($0) }),
                               choices: [""] + model.cameras.map(\.uniqueID),
                               titleForChoice: { id in
                                   id.isEmpty ? L("Automatic") : model.cameras.first { $0.uniqueID == id }?.localizedName ?? id
                               }, id: "settings.camera", fallbackFor: cameraIsLive ? ["settings.camera-test"] : [])
                if let track = liveTrack ?? model.borrowedLiveTrack ?? model.previewTrack {
                    NativeDesktopVideoView(track: track, mirrored: true).aspectRatio(16/9, contentMode: .fit).frame(maxHeight: 250).clipShape(RoundedRectangle(cornerRadius: 12))
                } else if settingsPage {
                    VStack(spacing: 8) {
                        if model.previewing { ProgressView() }
                        else { Image(systemName: "video.slash").font(.title2) }
                        Text(model.previewing ? L("Preparing…") : L("Camera is off"))
                    }.foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                }
                if !cameraIsLive {
                    privateCheckButton(model.previewing ? L("Stop private preview") : L("Check camera privately"),
                                       id: "settings.camera-test") {
                        if model.previewing { Task { await model.stop() } } else { model.startPreview() }
                    }
                }
                Text(cameraIsLive
                     ? L("This is your live meeting camera.")
                     : L("This preview is never sent to a meeting. System camera effects use the camera’s native orientation."))
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(L("Advanced camera settings"), isExpanded: $cameraAdvancedExpanded) {
                if settingsPage {
                    NativeSettingsSwitch(title: L("Share camera reactions"), isOn: $shareCameraReactions, id: "settings.camera-reactions")
                } else {
                    Toggle(L("Share camera reactions"), isOn: $shareCameraReactions)
                        .nativeSettingAnchor("settings.camera-reactions", nativeControlFocus: true)
                }
                Text(L("System heart, thumbs and celebration effects also send matching meeting reactions when your camera is shared.")).font(.caption).foregroundStyle(.secondary)
                settingsPicker(L("Camera readiness"), selection: Binding(
                    get: { NativeDesktopJoinReadinessPolicy.current().camera },
                    set: { cameraReadiness = $0.rawValue }),
                               choices: NativeDesktopMediaReadinessMode.allCases, titleForChoice: { $0.title },
                               id: "settings.camera-readiness")
                Text(L("Prepares camera information while the app is active. Briefly prepares the camera privately after joining, then stops it. No frames are shared. Uses extra energy and may briefly light the camera indicator. Skipped in Audio only view.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if settingsPage {
                Section(L("Meetings")) {
                    NativeSettingsSwitch(title: L("Keep the microphone ready in every meeting (experimental)"),
                                         isOn: $keepMicrophoneWarm, id: "settings.mic-warm")
                    Text(L("Moving your microphone between meetings skips restarting the device. Meetings you leave the microphone in stay muted, but macOS keeps showing the microphone indicator while you are in any meeting."))
                        .font(.caption).foregroundStyle(.secondary)
                    NativeSettingsSwitch(title: L("Mute with AirPods and headset buttons"), isOn: Binding(
                        get: { headsetMute }, set: { on in
                            headsetMute = on
                            if on { headsetMuteDisabledReason = "" }
                        }), id: "settings.headset")
                    Text(L("Pressing the stem or the headset button mutes or unmutes your microphone in the meeting that holds it. On some macOS versions turning this on makes the system audio service stop responding when a meeting starts; the app then turns it off again. Applies to meetings joined after turning it on."))
                        .font(.caption).foregroundStyle(.secondary)
                    if !headsetMute && !headsetMuteDisabledReason.isEmpty {
                        Text(L("Turned off after the system audio service stopped responding: %@.", headsetMuteDisabledReason))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
        }.nativeSettingsReveal().modifier(NativeDesktopDeviceFormStyle(settingsPage: settingsPage))
            .onDisappear { Task { await model.stop() } }
            .onChange(of: liveTrack != nil) { if $0 { Task { await model.stopCamera() } } }
            .onAppear { expandForReveal(revealID) }
            .onChange(of: revealID) { expandForReveal($0) }
    }
    private func expandForReveal(_ id: String?) {
        if ["settings.audio-profile", "settings.mic-readiness"].contains(id ?? "") { audioAdvancedExpanded = true }
        if ["settings.camera-reactions", "settings.camera-readiness"].contains(id ?? "") { cameraAdvancedExpanded = true }
    }

    private func audioDevicePicker(_ title: String, direction: MacAudioDirection, id: String) -> some View {
        let devices = model.audioSnapshot.devices(for: direction)
        let selection = Binding(
            get: { model.audioSnapshot.selectedID(for: direction) },
            set: { model.selectAudio($0, direction: direction) }
        )
        let choices = (selection.wrappedValue == 0 ? [UInt32(0)] : []) + devices.map(\.id)
        return settingsPicker(title, selection: selection, choices: choices, titleForChoice: { id in
            id == 0 ? L("System default") : devices.first { $0.id == id }?.name ?? String(id)
        }, id: id)
    }

    @ViewBuilder private func settingsPicker<Value: Hashable>(_ title: String, selection: Binding<Value>,
                                                               choices: [Value], titleForChoice: @escaping (Value) -> String,
                                                               id: String, fallbackFor: Set<String> = [],
                                                               accessibilityID: String? = nil) -> some View {
        if settingsPage {
            NativeSettingsPopup(title: title, selection: selection, choices: choices, titleForChoice: titleForChoice,
                                id: id, fallbackFor: fallbackFor, accessibilityID: accessibilityID)
        } else {
            Picker(title, selection: selection) {
                ForEach(choices, id: \.self) { Text(titleForChoice($0)).tag($0) }
            }
        }
    }

    @ViewBuilder private func privateCheckButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        if settingsPage {
            VStack(alignment: .leading, spacing: 6) {
                NativeSettingsButton(title: title, id: id, action: action)
                Label(L("Only you"), systemImage: "lock").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            HStack {
                Button(title, action: action)
                Spacer()
                Label(L("Only you"), systemImage: "lock").foregroundStyle(.secondary)
            }
        }
    }
}

private struct NativeDesktopDeviceFormStyle: ViewModifier {
    let settingsPage: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if settingsPage { content.formStyle(.grouped) }
        else { content }
    }
}

struct NativeDesktopVideoView: NSViewRepresentable {
    let track: LKRTCVideoTrack
    var mirrored = false
    var crop: CGRect?
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    var textFrame: NativeDesktopTextFrame? = nil
    var textSourceID: String? = nil
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let host = NativeDesktopVideoHost(); host.wantsLayer = true; host.layer?.backgroundColor = NSColor.black.cgColor
        host.onVisibilityChanged = { [weak coordinator = context.coordinator, weak host] in
            guard let host else { return }; coordinator?.refreshVisibility(host: host)
        }
        context.coordinator.bind(track: track, mirrored: mirrored, crop: crop, zoom: zoom, pan: pan, host: host)
        bindTextCapture(context.coordinator)
        return host
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.bind(track: track, mirrored: mirrored, crop: crop, zoom: zoom, pan: pan, host: view)
        bindTextCapture(context.coordinator)
    }
    private func bindTextCapture(_ coordinator: Coordinator) {
        guard let textFrame, let textSourceID else { return }
        textFrame.provider = .init(sourceID: textSourceID, capture: { [weak coordinator, weak expectedTrack = track, expectedCrop = crop, expectedMirrored = mirrored] in
            guard let coordinator, let expectedTrack else { return nil }
            return await coordinator.snapshotImage(expectedTrack: expectedTrack, expectedCrop: expectedCrop, expectedMirrored: expectedMirrored)
        })
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        (view as? NativeDesktopVideoHost)?.stopObserving(); coordinator.detach()
    }
    @MainActor final class Coordinator {
        var track: LKRTCVideoTrack?
        var mirrored = false
        var sink: CompanionVideoSink?
        private var crop: CGRect?
        private var zoom: CGFloat = 1
        private var pan = CGSize.zero
        func snapshotImage(expectedTrack: LKRTCVideoTrack, expectedCrop: CGRect?, expectedMirrored: Bool) async -> CGImage? {
            guard track === expectedTrack, crop == expectedCrop, mirrored == expectedMirrored else { return nil }
            return await sink?.snapshotImage(expectedCrop: expectedCrop)
        }
        func bind(track: LKRTCVideoTrack, mirrored: Bool, crop: CGRect?, zoom: CGFloat, pan: CGSize, host: NSView) {
            if self.track !== track || self.mirrored != mirrored {
                retireRenderer(); self.track = track; self.mirrored = mirrored
            }
            self.crop = crop; self.zoom = zoom; self.pan = pan
            refreshVisibility(host: host)
        }
        func refreshVisibility(host: NSView) {
            guard let window = host.window, window.isVisible, !window.isMiniaturized,
                  window.occlusionState.contains(.visible), !host.isHiddenOrHasHiddenAncestor,
                  let track else { retireRenderer(); return }
            if sink == nil {
                let sink = CompanionVideoSink(mirrored: mirrored); self.sink = sink
#if DEBUG
                sink.trackIDForTesting = track.trackId
#endif
                sink.view.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(sink.view)
                NSLayoutConstraint.activate([sink.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    sink.view.trailingAnchor.constraint(equalTo: host.trailingAnchor), sink.view.topAnchor.constraint(equalTo: host.topAnchor),
                    sink.view.bottomAnchor.constraint(equalTo: host.bottomAnchor)])
                track.add(sink)
            }
            sink?.setPresentation(crop: crop, zoom: zoom, pan: pan)
        }
        private func retireRenderer() {
            sink?.stop()
            if let sink { track?.remove(sink); sink.view.removeFromSuperview() }
            sink = nil
        }
        func detach() { retireRenderer(); track = nil }
    }
}

/// A retained editor may outlive its visible window. Suspend only its display
/// sink, preserving private preview, Presenter scene and any outgoing track.
@MainActor final class NativeDesktopVideoHost: NSView {
    var onVisibilityChanged: (() -> Void)?
    private var observations: [NSObjectProtocol] = []
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observations.forEach(NotificationCenter.default.removeObserver); observations = []
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.onVisibilityChanged?()
                })
            }
        }
        onVisibilityChanged?()
    }
    func stopObserving() {
        onVisibilityChanged = nil
        observations.forEach(NotificationCenter.default.removeObserver); observations = []
    }
    deinit { observations.forEach(NotificationCenter.default.removeObserver) }
}
