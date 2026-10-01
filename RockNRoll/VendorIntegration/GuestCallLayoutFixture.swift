#if DEBUG
import JazzSDK
import UIKit
import WebRTC

/// Exercises the production stage and controls without live-room timing.
final class GuestCallLayoutFixture: UIViewController {
    private let streams = GuestStreamViews()
    private let processor = GuestVideoFrameProcessor()
    private var controls: CallControls!
    private var renderers: [String: RTCMTLVideoView] = [:]
    private var timer: Timer?
    private var selectedName = ""
    private var views: [String: UIView] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        // A visibly different SDK underlay detects accidental duplicate exposure.
        view.backgroundColor = .systemPurple
        let preview = LocalSharePreview()
        let catchUp = CatchUpStore()
        catchUp.enter(roomKey: "guest-layout-\(UUID().uuidString)")
        controls = CallControls(localPreview: preview, state: nil, coordinator: nil, router: nil,
            catchUp: catchUp, chat: ChatStore(), initialDisplayMode: .all,
            invitationURL: nil, roomIdentifier: "fixture",
            onDisplayMode: { [weak self] mode in self?.streams.displayMode = mode },
            onFloat: {}, onFloatingPreferenceChanged: {}, onLeave: {}, onScreenShare: { _ in },
            onMicrophoneState: { _ in }, onCameraState: { _ in })
        for (id, name, share) in [("share", "Ani’s arrangement", true), ("camera", "Aram", false)] {
            let renderer = RTCMTLVideoView()
            renderers[id] = renderer
            let model = JazzParticipantViewModel(name: name, isAudioOn: true, isVideoOn: !share,
                isPinned: false, isSharingScreen: share, isLocal: false, id: id,
                isDominantSpeaker: false, shouldShowParticipantInfo: true,
                isZoomable: share, watermarkState: .hidden, displayMode: .speaker)
            let tile = streams.makeView(model: model, video: renderer)
            views[id] = tile
            tile.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
            view.addSubview(tile)
        }
        streams.updateActiveMedia(sharing: ["share"], cameras: ["camera"], participants: ["share", "camera"])
        streams.onStagePresentation = { [weak self] in self?.controls.setStagePresentation($0) }
        streams.onPreferredVideo = { [weak self] _, name, _ in self?.selectedName = name }
        controls.onBrowse = { [weak self] in self?.streams.browse($0) }
        controls.onAutomaticView = { [weak self] in self?.streams.useAutomaticView() }
        controls.onPinStage = { [weak self] in self?.streams.toggleSelectedPin() }
        controls.frame = view.bounds
        controls.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controls)
        processor.onSample = { [weak self] sample, _, rotation in self?.controls.showStageFrame(sample, rotation: rotation) }
        processor.setEnabled(true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let width = 320, height = 180
            let buffer = RTCMutableI420Buffer(width: Int32(width), height: Int32(height))
            for row in 0..<height {
                for column in 0..<width {
                    buffer.mutableDataY[row * Int(buffer.strideY) + column] =
                        self.selectedName == "Aram" ? 90 : ((column / 32 + row / 18).isMultiple(of: 2) ? 40 : 170)
                }
            }
            for row in 0..<height / 2 {
                for column in 0..<width / 2 {
                    buffer.mutableDataU[row * Int(buffer.strideU) + column] = 128
                    buffer.mutableDataV[row * Int(buffer.strideV) + column] = 128
                }
            }
            self.processor.submit(RTCVideoFrame(buffer: buffer, rotation: ._0,
                timeStampNs: Int64(Date().timeIntervalSince1970 * 1_000_000_000)))
        }
        streams.refreshSelection()
    }
    deinit { timer?.invalidate(); processor.setEnabled(false) }
}
#endif
