import AppKit
import AVFoundation
import Combine
import LiveKitWebRTC
import SwiftUI

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
    private var audioOwner: GuestSystemAudio?
    private var audioTask: Task<Void, Never>?
    private var audioGeneration = UUID()
    private var stopBorrowedAudio: (() async throws -> Void)?
    private var audioStopping: Task<Bool, Never>?
    static func stopPrivatePreview() async -> Bool { await activePreview?.stop() ?? true }
    init() {
        cameraID = UserDefaults.standard.string(forKey: "nativeDesktop.cameraID") ?? ""
        cameras = AVCaptureDevice.devices(for: .video)
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
                let granted: Bool
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: granted = true
                case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .audio)
                default: granted = false
                }
                guard granted else { throw GuestSystemAudioError.microphonePermissionRequired }
                guard audioGeneration == token, !Task.isCancelled else { return }
                if live {
                    guard let start, let stop, level != nil else { throw NativeDesktopPrivateAudioError.unavailable }
                    stopBorrowedAudio = stop
                    try await start()
                } else {
                    let owner = try await GuestSystemAudio.create(microphoneEnabled: false, playoutEnabled: false,
                                                                 profile: .saved, privateCheckOnly: true)
                    guard audioGeneration == token, !Task.isCancelled else { _ = await owner.shutdown(); return }
                    audioOwner = owner
                    guard await owner.startStandalonePrivateInputCheck() else { throw GuestSystemAudioError.setupFailedOrTimedOut }
                }
                guard audioGeneration == token, !Task.isCancelled else { return }
                while audioGeneration == token, !Task.isCancelled {
                    audioLevel = min(1, max(0, audioOwner?.privateInputLevel ?? level?() ?? 0))
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
                    audioOwner = nil; let clean = await owner.shutdown(); cleanupFailed = cleanupFailed || !clean
                }
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
            do { try await stop?() } catch { return false }
            let owner = audioOwner; audioOwner = nil
            return await owner?.shutdown() ?? true
        }
        audioStopping = stopping
        let clean = await stopping.value
        audioStopping = nil; cleanupFailed = cleanupFailed || !clean
        if !previewing, Self.activePreview === self { Self.activePreview = nil }
        if !clean { error = L("Microphone check could not stop. Quit and reopen the app before joining.") }
        return clean && !cleanupFailed
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
                self.error = error.localizedDescription; await stop()
            }
        }
    }
    @discardableResult func stop() async -> Bool {
        let audioClean = await stopAudioCheck()
        if let stopping { let cameraClean = await stopping.value; return cameraClean && audioClean && !cleanupFailed }
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
        stopping = nil; cleanupFailed = cleanupFailed || !clean || !audioClean
        if let lease {
            if clean { NativeDesktopCameraLease.shared.release(lease) }
            else { NativeDesktopCameraLease.shared.reportFailedStop(lease) }
        }
        if Self.activePreview === self { Self.activePreview = nil }
        if !clean { error = L("Camera preview could not stop. Quit and reopen the app before starting camera video.") }
        return clean && audioClean && !cleanupFailed
    }
}

struct NativeDesktopDeviceSettings: View {
    var liveTrack: LKRTCVideoTrack?
    var liveAudioAvailable = false
    var startLiveAudioCheck: (() async throws -> Void)?
    var stopLiveAudioCheck: (() async throws -> Void)?
    var liveAudioLevel: (() -> Float?)?
    @StateObject private var model = NativeDesktopDeviceModel()
    @AppStorage("nativeDesktop.shareCameraReactions") private var shareCameraReactions = true
    @AppStorage("nativeDesktop.headsetMuteControls") private var headsetReady = false
    @AppStorage(GuestAudioProfile.preferenceKey) private var profile = GuestAudioProfile.speech.rawValue
    var body: some View {
        Form {
            Section(L("Audio devices")) {
                Picker(L("Audio profile"), selection: $profile) {
                    Text(L("Speech")).tag(GuestAudioProfile.speech.rawValue)
                    Text(L("Music")).tag(GuestAudioProfile.music.rawValue)
                }
                Text(L("Speech uses echo cancellation, noise suppression and automatic gain. Music keeps software echo cancellation and removes noise suppression and automatic gain; room noise and level changes are more audible. Applies to the next meeting.")).font(.caption).foregroundStyle(.secondary)
                Picker(L("Microphone"), selection: Binding(get: { model.audioSnapshot.inputID }, set: { model.selectAudio($0, direction: .input) })) {
                    if model.audioSnapshot.inputID == 0 { Text(L("System default")).tag(UInt32(0)) }
                    ForEach(model.audioSnapshot.devices(for: .input), id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker(L("Output"), selection: Binding(get: { model.audioSnapshot.outputID }, set: { model.selectAudio($0, direction: .output) })) {
                    if model.audioSnapshot.outputID == 0 { Text(L("System default")).tag(UInt32(0)) }
                    ForEach(model.audioSnapshot.devices(for: .output), id: \.id) { Text($0.name).tag($0.id) }
                }
                Toggle(L("Headset mute controls from the first gesture"), isOn: $headsetReady)
                Text(L("Keeps the microphone ready while muted so AirPods can unmute. Muted audio is never sent. Applies to the next meeting.")).font(.caption).foregroundStyle(.secondary)
                Text(L("Device choices follow the Mac’s system audio routes.")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(model.checkingAudio ? L("Stop microphone check") : L("Check microphone privately")) {
                        if model.checkingAudio { Task { await model.stopAudioCheck() } }
                        else { model.startAudioCheck(live: liveAudioAvailable, start: startLiveAudioCheck, stop: stopLiveAudioCheck, level: liveAudioLevel) }
                    }
                    Spacer(); Label(L("Only you"), systemImage: "lock").foregroundStyle(.secondary)
                }
                if model.checkingAudio {
                    ProgressView(value: Double(model.audioLevel), total: 1).accessibilityLabel(L("Microphone level"))
                    Text(L("Checking uses the meeting’s microphone when connected. Your mute setting stays unchanged. No recording is saved.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("Camera")) {
                Toggle(L("Share camera reactions"), isOn: $shareCameraReactions)
                Text(L("System heart, thumbs and celebration effects also send matching meeting reactions when your camera is shared.")).font(.caption).foregroundStyle(.secondary)
                Picker(L("Camera"), selection: Binding(get: { model.cameraID }, set: { model.selectCamera($0) })) {
                    Text(L("Automatic")).tag("")
                    ForEach(model.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                if let track = liveTrack ?? model.borrowedLiveTrack ?? model.previewTrack {
                    NativeDesktopVideoView(track: track, mirrored: true).aspectRatio(16/9, contentMode: .fit).frame(maxHeight: 250).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if liveTrack == nil && model.borrowedLiveTrack == nil { HStack {
                    Button(model.previewing ? L("Stop private preview") : L("Check camera privately")) {
                        if model.previewing { Task { await model.stop() } } else { model.startPreview() }
                    }
                    Spacer(); Label(L("Only you"), systemImage: "lock").foregroundStyle(.secondary)
                } }
                Text(L("This preview is never sent to a meeting. System camera effects use the camera’s native orientation.")).font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
        }.onDisappear { Task { await model.stop() } }
            .onChange(of: liveTrack != nil) { if $0 { Task { await model.stop() } } }
    }
}

struct NativeDesktopVideoView: NSViewRepresentable {
    let track: LKRTCVideoTrack
    var mirrored = false
    var crop: CGRect?
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let host = NativeDesktopVideoHost(); host.wantsLayer = true; host.layer?.backgroundColor = NSColor.black.cgColor
        host.onVisibilityChanged = { [weak coordinator = context.coordinator, weak host] in
            guard let host else { return }; coordinator?.refreshVisibility(host: host)
        }
        context.coordinator.bind(track: track, mirrored: mirrored, crop: crop, zoom: zoom, pan: pan, host: host)
        return host
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.bind(track: track, mirrored: mirrored, crop: crop, zoom: zoom, pan: pan, host: view)
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
