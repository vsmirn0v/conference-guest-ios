import AppKit
import ConferenceCore
import SwiftUI

@MainActor final class NativeDesktopMeetingWindow: NSObject, NSWindowDelegate {
    private let model: NativeDesktopMeetingModel
    private let continuation: MeetingContinuationCoordinator?
    private let window: NSWindow
    private var mini: NSPanel?
    init(model: NativeDesktopMeetingModel, continuation: MeetingContinuationCoordinator? = nil) {
        self.model = model
        self.continuation = continuation
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = model.title; window.minSize = NSSize(width: 740, height: 520)
        window.isReleasedWhenClosed = false; window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden; window.delegate = self
        window.setFrameAutosaveName("nativeDesktop.meeting"); window.center()
    }
    var isKeyWindow: Bool { window.isKeyWindow || mini?.isKeyWindow == true }
    private func mountMeeting() {
        if !(window.contentView is NSHostingView<NativeDesktopMeetingView>) { window.contentView = NSHostingView(rootView: NativeDesktopMeetingView(model: model, onMini: { [weak self] in self?.showMini() }, continuation: continuation)) }
    }
    func show() {
        mini?.orderOut(nil); mini?.contentView = nil
        if window.isMiniaturized { window.deminiaturize(nil) }
        mountMeeting(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        synchronizePresentation()
    }
    func close() { model.setMediaVisible(false); mini?.close(); mini = nil; window.orderOut(nil); window.contentView = nil }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); sender.contentView = nil; synchronizePresentation(); return false }
    func windowWillMiniaturize(_ notification: Notification) {
        model.setMediaPresentation(.hidden)
    }
    func windowDidMiniaturize(_ notification: Notification) { synchronizePresentation() }
    func windowDidDeminiaturize(_ notification: Notification) { synchronizePresentation() }
    func windowDidChangeOcclusionState(_ notification: Notification) { synchronizePresentation() }
    private func synchronizePresentation() {
        let mainVisible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        let miniVisible = mini.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        if miniVisible {
            if !(mini?.contentView is NSHostingView<NativeDesktopMiniMeeting>) {
                mini?.contentView = NSHostingView(rootView: NativeDesktopMiniMeeting(model: model, onRestore: { [weak self] in self?.show() }))
            }
        }
        // Keep editor/zoom state through occlusion. Only the media subtree is
        // unmounted; destroying the shell would close a private Presenter draft.
        if mainVisible { mountMeeting() }
        model.setMediaPresentation(mainVisible ? .meeting : miniVisible ? .floating : .hidden)
    }
    func showMini() {
        if mini == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 270),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.delegate = self; panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.isReleasedWhenClosed = false
            panel.title = model.title; panel.minSize = NSSize(width: 280, height: 210)
            panel.contentView = NSHostingView(rootView: NativeDesktopMiniMeeting(model: model, onRestore: { [weak self] in self?.show() }))
            panel.center(); mini = panel
        }
        if !(mini?.contentView is NSHostingView<NativeDesktopMiniMeeting>) { mini?.contentView = NSHostingView(rootView: NativeDesktopMiniMeeting(model: model, onRestore: { [weak self] in self?.show() })) }
        mini?.orderFrontRegardless(); window.orderOut(nil)
        synchronizePresentation()
    }
}

struct NativeDesktopMeetingView: View {
    @ObservedObject var model: NativeDesktopMeetingModel
    let onMini: () -> Void
    var continuation: MeetingContinuationCoordinator? = nil
    @State private var reactionsOpen = false
    @State private var shareOpen = false
    @State private var soundOpen = false
    @StateObject private var focusedViewport = NativeDesktopVideoViewport()
    @StateObject private var textFrame = NativeDesktopTextFrame()
    @StateObject private var textSelection = NativeDesktopSharedText()
    private var textSourceID: String? { model.focusedVideo.flatMap { $0.source == .screen ? $0.id : nil } }
    private func updateTextSource() {
        textSelection.updateSource(id: textSourceID, name: model.focusedVideo.map { name($0.participantID) } ?? "", frame: textFrame)
    }
    var body: some View {
        VStack(spacing: 0) {
        if let continuation { NativeDesktopContinuationStatus(coordinator: continuation) }
        GeometryReader { geometry in
        // Side panels float over the stage: the control bar stays centred on the
        // window, so opening Chat or Share never moves Mic, Video or Leave.
        let docked = geometry.size.width >= 1040 ? model.panel : nil
        let reserved: CGFloat = docked == nil ? 0 : Self.panelWidth + 14
        ZStack(alignment: .topTrailing) {
            ZStack {
                Color.black
                if model.mediaPresentation == .meeting { media.padding(.leading, 14).padding(.trailing, 14 + reserved)
                    .padding(.top, (model.controlsHidden ? 12 : 70) + (model.isSharingLive ? 48 : 0))
                    .padding(.bottom, model.controlsHidden ? 12 : (model.showsFocus ? 90 : 160))
                }
                if textSelection.isOpen { NativeDesktopSharedTextView(model: textSelection, meetingTools: AnyView(viewAndMoreMenus)) }
                VStack(spacing: 0) {
                    if !model.controlsHidden && !textSelection.isOpen { header.padding(.horizontal, 18).padding(.top, 10) }
                    if model.isSharingLive && !textSelection.isOpen { shareBanner.padding(.top, 8).padding(.trailing, reserved) }
                    if !textSelection.isOpen { HStack { reactionOverlay; Spacer() }.padding(.leading, 22).padding(.top, 12) }
                    Spacer(minLength: 0)
                    if !model.controlsHidden { controls.padding(.bottom, 18) }
                }
                if model.controlsHidden {
                    VStack { Spacer(); Button(L("Show controls")) { model.controlsHidden = false }.buttonStyle(.bordered).padding() }
                }
            }.foregroundStyle(.white)
            if let docked {
                inspector(docked).frame(width: Self.panelWidth)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
                    .padding(.trailing, 14).padding(.top, model.controlsHidden ? 12 : 64)
                    .padding(.bottom, model.controlsHidden ? 12 : 150)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }.animation(.easeOut(duration: 0.18), value: docked)
        .sheet(isPresented: Binding(get: { geometry.size.width < 1040 && model.panel != nil }, set: { if !$0 { model.panel = nil } })) {
            if let panel = model.panel { inspector(panel).frame(width: 380, height: 560) }
        }
        }
        }
        .onChange(of: textSourceID) { _ in updateTextSource() }
        .onChange(of: model.snapshot.phase) { phase in if phase == .left || phase == .leaving || phase == .failed { textSelection.close() } }
        .onDisappear { textSelection.close() }
        .alert(L("Meeting"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L("OK")) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private static let panelWidth: CGFloat = 320
    private var shareBanner: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Text(L("You’re sharing")).font(.callout.bold())
            Text(model.shareSourceTitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            if let start = model.shareStartedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(Self.elapsed(since: start, now: context.date)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Divider().frame(height: 16)
            if model.presenterSharing {
                Menu(L("Change…")) {
                    Button(L("Screen or window…")) { model.quickShare() }
                    Button(L("Slides or image…")) { Task { await chooseShareImage() } }
                }.menuStyle(.borderlessButton).fixedSize().disabled(model.quickSharePending)
                Button(L("Studio")) { model.panel = .presenter }.buttonStyle(.plain)
            }
            Button(L("Stop sharing")) { Task { await model.endShare() } }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
                .accessibilityIdentifier("share.stop")
        }.padding(.horizontal, 14).padding(.vertical, 8).nativeMeetingChrome()
            .accessibilityElement(children: .contain).accessibilityLabel(L("You’re sharing"))
    }
    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    private func chooseShareImage() async {
        do { if let data = try await NativeDesktopPresenterImagePicker.choose() { model.quickShare(image: data) } }
        catch { model.error = error.localizedDescription }
    }
    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                if model.guestFeatures.transcriptionStatus == .active { Image(systemName: "text.bubble.fill").foregroundStyle(.orange).help(L("Meeting transcription is on")) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title).font(.headline).lineLimit(1)
                    Text(model.connected ? L("%d participants", model.participants.count) : L(model.snapshot.phase.rawValue.capitalized)).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 16).padding(.vertical, 10).nativeMeetingChrome()
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                iconButton("person.2", L("Participants")) { togglePanel(.participants) }
                iconButton("bubble.left", L("Conversation")) { togglePanel(.conversation) }
                iconButton("pip.enter", L("Mini meeting"), action: onMini)
            }.padding(6).nativeMeetingChrome()
        }
    }
    private var controls: some View {
        VStack(spacing: 10) {
            if !textSelection.isOpen { HStack(spacing: 8) {
                if textSourceID != nil {
                    iconButton("text.viewfinder", L("Select text")) { model.controlsHidden = false; updateTextSource(); textSelection.open(zoom: focusedViewport.zoom, pan: focusedViewport.pan, viewportSize: focusedViewport.size) }
                        .accessibilityIdentifier("Select shared text")
                    Divider().frame(height: 18)
                }
                if model.galleryPages > 1 && !model.showsFocus {
                    Button { model.galleryPage = max(0, model.galleryPage - 1) } label: { Image(systemName: "chevron.left") }.disabled(model.galleryPage == 0)
                    Text("\(model.galleryPage + 1) / \(model.galleryPages)").font(.caption).monospacedDigit()
                    Button { model.galleryPage = min(model.galleryPages - 1, model.galleryPage + 1) } label: { Image(systemName: "chevron.right") }.disabled(model.galleryPage == model.galleryPages - 1)
                    Divider().frame(height: 18)
                }
                viewAndMoreMenus
            }.buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 10).nativeMeetingChrome() }
            HStack(spacing: 4) {
                controlButton(model.snapshot.microphoneOn ? "mic.fill" : "mic.slash", L("Mic"), selected: model.snapshot.microphoneOn, pending: model.microphoneStarting) { model.toggleMicrophone() }
                    .help(model.microphoneStarting ? L("Starting microphone. Click to cancel.") : L("Mute or unmute (Space or ⇧⌘M)"))
                    .contextMenu { Button(L("Audio settings")) { model.panel = .studio } }
                controlButton(model.snapshot.cameraOn ? "video.fill" : "video.slash", L("Video"), selected: model.snapshot.cameraOn, pending: model.cameraStarting) { model.toggleCamera() }
                    .help(model.cameraStarting ? L("Starting camera. Click to cancel.") : L("Video"))
                    .contextMenu { Button(L("Camera settings")) { model.panel = .studio } }
                if model.isSharingLive || model.sharingPending {
                    controlButton("stop.circle.fill", L("Stop share"), selected: false, destructive: true) { Task { await model.endShare() } }
                        .help(L("Stop sharing")).accessibilityIdentifier("share.control-stop")
                } else {
                    controlButton("rectangle.on.rectangle", L("Share"), selected: shareOpen, pending: model.quickSharePending) { shareOpen.toggle() }
                        .accessibilityIdentifier("share.control")
                        .popover(isPresented: $shareOpen, arrowEdge: .top) {
                            NativeDesktopSharePopover(model: model, chooseImage: { Task { await chooseShareImage() } }, close: { shareOpen = false })
                        }
                }
                controlButton(model.soundSymbol, L("Sound"), selected: model.snapshot.playoutOn) { model.togglePlayout() }
                    .help(L("Meeting sound on or off. Use the arrow for meeting volume."))
                    .overlay(alignment: .topTrailing) {
                        Button { soundOpen.toggle() } label: {
                            Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(L("Meeting volume")).accessibilityLabel(L("Meeting volume"))
                            .popover(isPresented: $soundOpen, arrowEdge: .top) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(L("Meeting volume")).font(.headline)
                                    NativeDesktopMeetingVolume(model: model)
                                    Text(L("Only this meeting. Your Mac volume doesn’t change.")).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }.padding(16).frame(width: 280)
                            }
                    }
                    .contextMenu { Button(L("Meeting volume")) { soundOpen = true } }
                controlButton("face.smiling", L("Reactions"), selected: reactionsOpen) { reactionsOpen.toggle() }
                    .disabled(!model.canReact).popover(isPresented: $reactionsOpen, arrowEdge: .bottom) { reactionPicker }
                Divider().frame(height: 34).padding(.horizontal, 6)
                controlButton("phone.down.fill", L("Leave"), selected: false, destructive: true) { Task { await model.onLeave?() } }
            }.padding(8).nativeMeetingChrome()
        }
    }
    private var viewMenuTitle: String {
        switch model.display {
        case .all: L(model.viewMode.rawValue)
        case .screenShares, .audioOnly: model.display.title + " · " + L(model.viewMode.rawValue)
        }
    }
    private var viewMenuSymbol: String {
        model.display != .all ? model.display.symbol : model.showsFocus ? "rectangle.inset.filled" : "square.grid.2x2"
    }
    private var viewAndMoreMenus: some View {
        Group {
                Menu {
                    Picker(L("Show"), selection: $model.display) {
                        ForEach(model.availableDisplays, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }.pickerStyle(.inline)
                    Picker(L("Layout"), selection: $model.viewMode) {
                        ForEach(NativeDesktopMeetingModel.ViewMode.allCases, id: \.self) { Text(L($0.rawValue)).tag($0) }
                    }.pickerStyle(.inline)
                    if model.display != .audioOnly {
                        ForEach(model.participants.filter { $0.sharing == true }) { person in
                            Button(L("Screen · %@", person.name)) { model.focus(participantID: person.id, source: .screen) }
                        }
                    }
                    if model.pinnedID != nil { Button(L("Unpin")) { model.unpin() } }
                } label: { Label(viewMenuTitle, systemImage: viewMenuSymbol) }
                Divider().frame(height: 18)
                Menu {
                    Button(L("Participants")) { togglePanel(.participants) }
                    Button(L("Conversation")) { togglePanel(.conversation) }
                    Button(L("Mini meeting"), action: onMini)
                    Button(L("Camera & sound")) { togglePanel(.studio) }
                    Button(L("Presenter studio")) { togglePanel(.presenter) }
                    Button(L("Reconnect")) { model.reconnect() }
                    Button(L("Copy invitation")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.invitation.absoluteString, forType: .string) }
                    Button(L("Hide controls")) { model.controlsHidden = true }
                } label: { Label(L("More"), systemImage: "ellipsis") }
        }
    }
    /// Show modes only reduce received media; tiles, speaking state and layouts stay.
    @ViewBuilder private var media: some View {
        VStack(spacing: 8) {
            if let caption = displayCaption {
                Label(caption, systemImage: model.display.symbol).font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 6).background(.white.opacity(0.08), in: Capsule())
            }
            mediaContent
        }
    }
    private var displayCaption: String? {
        switch model.display {
        case .all: nil
        case .audioOnly: L("Audio only")
        case .screenShares: model.videoParticipants.isEmpty ? L("No screen share is live. Audio continues.") : nil
        }
    }
    private var focusFilmstrip: some View {
        HStack(spacing: 8) {
            ForEach(model.participants.prefix(6)) { person in
                Button { model.focus(participantID: person.id, source: .camera) } label: {
                    HStack(spacing: 6) { Image(systemName: person.microphoneOn == true ? "mic.fill" : "mic.slash"); Text(person.name).lineLimit(1) }.font(.caption).padding(9)
                }.buttonStyle(.bordered).frame(maxWidth: 170)
            }
        }
    }
    @ViewBuilder private var mediaContent: some View {
        if model.showsFocus, let focused = model.focusedVideo {
            VStack(spacing: 10) {
                NativeDesktopZoomVideo(video: focused, name: name(focused.participantID), viewport: focusedViewport,
                    textFrame: textFrame, selectText: { model.controlsHidden = false; updateTextSource(); textSelection.open(zoom: focusedViewport.zoom, pan: focusedViewport.pan, viewportSize: focusedViewport.size) })
                focusFilmstrip
            }
        } else if model.showsFocus, let focusedID = model.focusedParticipantID,
                  let person = model.participants.first(where: { $0.id == focusedID }),
                  model.display != .all || (person.cameraOn != true && person.sharing != true) {
            // No video is expected here: keep the person, mic and speaking state in focus.
            VStack(spacing: 10) { participantTile(person, compact: false); focusFilmstrip }
        } else if model.showsFocus, let focusedID = model.focusedParticipantID {
            VStack(spacing: 16) { ProgressView(); Text(L("Waiting for stream…")); Text(name(focusedID)).foregroundStyle(.secondary) }
        } else if !model.participants.isEmpty {
            GeometryReader { geometry in
                let columns = geometry.size.width < 850 ? 2 : 3
                let rows = max(1, Int(ceil(Double(model.galleryParticipants.count) / Double(columns))))
                let height = max(70, (geometry.size.height - CGFloat(rows - 1) * 10) / CGFloat(rows))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
                    ForEach(model.galleryParticipants) { person in participantTile(person, compact: height < 150).frame(height: height) }
                }
            }
        } else {
            VStack(spacing: 16) {
                if let camera = model.localCamera { NativeDesktopVideoView(track: camera, mirrored: true) }
                else { Image(systemName: "person.2").font(.system(size: 48)).foregroundStyle(.secondary) }
                Text(model.connected ? L("You’re connected. Waiting for others.") : L("Connecting…")).font(.title3)
            }
        }
    }
    private func participantTile(_ person: NativeDesktopParticipant, compact: Bool) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color(white: 0.11)
            if person.isLocal, let track = model.localCamera { NativeDesktopVideoView(track: track, mirrored: true) }
            else if let video = model.visibleVideos.first(where: {
                $0.participantID == person.id && $0.source == (model.display == .screenShares ? .screen : .camera)
            }) {
                NativeDesktopVideoView(track: video.track, crop: video.crop)
            } else {
                VStack(spacing: 12) {
                    Text(initials(person.name)).font(compact ? .body : .title).padding(compact ? 8 : 15).background(.white.opacity(0.08), in: Circle())
                    if !compact { Text(person.name).font(.headline).lineLimit(2).multilineTextAlignment(.center) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 7) {
                Text(person.name).lineLimit(1); Spacer(minLength: 4)
                if !person.isLocal, model.participantVolume(person.id) != 1 { NativeDesktopParticipantVolumeBadge(level: model.participantVolume(person.id)) }
                if person.microphoneOn == false { Image(systemName: "mic.slash").accessibilityLabel(L("Microphone off")) }
                else if person.speaking == true { NativeDesktopLevelMeter(level: person.isLocal ? model.snapshot.microphoneLevel ?? 0 : 0.7) }
            }.font(.caption).padding(10).background(.black.opacity(0.45))
        }.clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(person.speaking == true ? Color.green : Color.white.opacity(0.12), lineWidth: person.speaking == true ? 2 : 1))
        .contextMenu {
            Button(L("Focus camera")) { model.focus(participantID: person.id, source: .camera) }
            if person.sharing == true { Button(L("Focus screen")) { model.focus(participantID: person.id, source: .screen) } }
            if !person.isLocal && model.supportsParticipantVolume { participantVolumeMenu(person) }
        }
    }
    @ViewBuilder private func participantVolumeMenu(_ person: NativeDesktopParticipant) -> some View {
        let level = model.participantVolume(person.id)
        Divider()
        Button(level == 0 ? L("Unmute for me") : L("Mute for me")) { model.setParticipantVolume(level == 0 ? 1 : 0, participantID: person.id) }
        Menu(L("Volume for me")) {
            ForEach([0.25, 0.5, 1, 1.5, 2], id: \.self) { preset in
                Button { model.setParticipantVolume(preset, participantID: person.id) } label: {
                    let title = "\(Int(preset * 100))%"
                    if level == preset { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        }
    }
    private func name(_ id: String) -> String { model.participants.first { $0.id == id }?.name ?? L("Participant") }
    private func initials(_ name: String) -> String { name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
    private var reactionOverlay: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.floatingReactions) { event in
                HStack { Text(event.kind.emoji).font(.title); Text(event.displayName ?? L("Participant")).font(.caption) }
                    .padding(.horizontal, 12).padding(.vertical, 6).background(.ultraThinMaterial, in: Capsule()).transition(.move(edge: .leading).combined(with: .opacity))
            }
        }.animation(.easeOut(duration: 0.2), value: model.floatingReactions.map(\.id)).allowsHitTesting(false)
    }
    private var reactionPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(52)), count: 4), spacing: 8) {
            ForEach(MeetingReaction.allCases, id: \.self) { kind in
                Button { model.sendReaction(kind) } label: { Text(kind.emoji).font(.system(size: 28)).frame(width: 48, height: 48) }.buttonStyle(.plain).help(kind.title)
            }
        }.padding(14)
    }
    @ViewBuilder private func inspector(_ panel: NativeDesktopMeetingModel.Panel) -> some View {
        VStack(spacing: 0) {
            HStack { Text(panel == .presenter ? L("Presenter studio") : L(panel.rawValue)).font(.headline); Spacer(); Button { model.panel = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(L("Close")) }.padding(18)
            Divider()
            switch panel {
            case .participants:
                List(model.participants) { person in
                    HStack {
                        Text(person.name).lineLimit(2); Spacer()
                        if person.microphoneOn == false { Image(systemName: "mic.slash") }
                        if person.sharing == true { Image(systemName: "rectangle.on.rectangle") }
                        if !person.isLocal && model.supportsParticipantVolume { NativeDesktopParticipantVolumeButton(model: model, person: person) }
                    }
                }.listStyle(.plain)
            case .conversation: NativeDesktopConversationView(model: model, chat: model.chat)
            case .studio: NativeDesktopDeviceSettings(liveTrack: model.localCamera,
                liveAudioAvailable: true,
                startLiveAudioCheck: { try await model.engine.startPrivateAudioCheck() },
                stopLiveAudioCheck: { try await model.engine.stopPrivateAudioCheck() },
                liveAudioLevel: { model.engine.privateAudioLevel })
            case .presenter: NativeDesktopPresenterView(model: model)
            }
        }
    }
    private func togglePanel(_ panel: NativeDesktopMeetingModel.Panel) { model.panel = model.panel == panel ? nil : panel }
    private func iconButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 32, height: 30) }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
    private func controlButton(_ symbol: String, _ title: String, selected: Bool, destructive: Bool = false, pending: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.title3).opacity(pending ? 0 : 1)
                    .overlay { if pending { ProgressView().controlSize(.small) } }
                Text(pending ? L("Starting…") : title).font(.caption)
            }
                .foregroundStyle(destructive ? Color.red : selected ? .orange : .primary).frame(width: 66, height: 48).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(pending ? L("Starting…") : "")
            .disabled(!model.connected && title != L("Leave"))
    }
}

private struct NativeDesktopContinuationStatus: View {
    @ObservedObject var coordinator: MeetingContinuationCoordinator
    var body: some View {
        if let status = coordinator.status {
            HStack(spacing: 12) {
                Text(status).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                if coordinator.needsManualResume { Button(L("Resume here")) { coordinator.resumeHere() } }
                if coordinator.moving { Button(coordinator.moveActionTitle) { coordinator.cancel() } }
            }.padding(12).background(.regularMaterial)
        }
    }
}

struct NativeDesktopLevelMeter: View {
    let level: Float
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<4) { index in
                Capsule().fill(level > Float(index) * 0.08 ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 3, height: CGFloat(5 + index * 3))
            }
        }.accessibilityLabel(L("Microphone level")).accessibilityValue(String(Int(max(0, min(1, level)) * 100)))
    }
}

final class NativeDesktopVideoViewport: ObservableObject {
    @Published var zoom: CGFloat = 1
    var savedZoom: CGFloat = 1
    @Published var pan = CGSize.zero
    var savedPan = CGSize.zero
    var size = CGSize.zero
    private var sourceID: String?
    private var participantID: String?
    func select(participant: String, source: NativeDesktopVideoSource) {
        guard participantID != participant || sourceID != source.rawValue else { return }
        participantID = participant; sourceID = source.rawValue
        zoom = 1; savedZoom = 1; pan = .zero; savedPan = .zero
    }
}

struct NativeDesktopZoomVideo: View {
    let video: NativeDesktopExternalVideo
    let name: String
    @ObservedObject var viewport: NativeDesktopVideoViewport
    var textFrame: NativeDesktopTextFrame? = nil
    var selectText: (() -> Void)? = nil
    private var zoom: CGFloat { get { viewport.zoom } nonmutating set { viewport.zoom = newValue } }
    private var savedZoom: CGFloat { get { viewport.savedZoom } nonmutating set { viewport.savedZoom = newValue } }
    private var pan: CGSize { get { viewport.pan } nonmutating set { viewport.pan = newValue } }
    private var savedPan: CGSize { get { viewport.savedPan } nonmutating set { viewport.savedPan = newValue } }
    var body: some View {
        GeometryReader { geometry in
            NativeDesktopVideoView(track: video.track, crop: video.crop, zoom: zoom, pan: pan, textFrame: textFrame, textSourceID: video.id)
                .contentShape(Rectangle())
                .onAppear { viewport.size = geometry.size }
                .onChange(of: geometry.size) { viewport.size = $0 }
                .gesture(MagnificationGesture().onChanged { zoom = min(8, max(1, savedZoom * $0)) }.onEnded { _ in savedZoom = zoom; if zoom == 1 { pan = .zero; savedPan = .zero } })
                .simultaneousGesture(DragGesture().onChanged { value in
                    guard zoom > 1 else { return }
                    pan = CGSize(width: min(1, max(-1, savedPan.width + value.translation.width / max(1, geometry.size.width / 2))),
                                 height: min(1, max(-1, savedPan.height + value.translation.height / max(1, geometry.size.height / 2))))
                }.onEnded { _ in savedPan = pan })
                .overlay(alignment: .bottomLeading) { Text(name + (video.source == .screen ? " · " + L("Screen") : "")).font(.caption).lineLimit(1).frame(maxWidth: max(80, min(400, geometry.size.width - 140)), alignment: .leading).padding(8).background(.black.opacity(0.5), in: Capsule()).padding(10) }
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 12) {
                        Button { zoom = 1; savedZoom = 1; pan = .zero; savedPan = .zero } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }.help(L("Fit to screen"))
                        Button { zoom = min(8, zoom + 0.5); savedZoom = zoom } label: { Image(systemName: "plus.magnifyingglass") }.help(L("Zoom in"))
                    }.buttonStyle(.plain).padding(12).nativeMeetingChrome().padding(10)
                }
        }.clipShape(RoundedRectangle(cornerRadius: 14))
            .contextMenu { if video.source == .screen, let selectText { Button(L("Select text"), action: selectText) } }
            .onAppear { viewport.select(participant: video.participantID, source: video.source) }
            .onChange(of: video.participantID) { _ in viewport.select(participant: video.participantID, source: video.source) }
            .onChange(of: video.source.rawValue) { _ in viewport.select(participant: video.participantID, source: video.source) }
    }
}

struct NativeDesktopConversationView: View {
    @ObservedObject var model: NativeDesktopMeetingModel
    @ObservedObject var chat: ChatStore
    private enum TimelineRow: Identifiable {
        case message(ChatEntry), reaction(MeetingReactionEvent)
        var id: String { switch self { case .message(let item): "chat-" + item.id; case .reaction(let item): "reaction-" + item.id } }
        var date: Date { switch self { case .message(let item): item.sentAt; case .reaction(let item): item.timestamp } }
    }
    private var timeline: [TimelineRow] {
        (chat.items.map(TimelineRow.message) + chat.reactionHistory.events.map(TimelineRow.reaction)).sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
        }
    }
    @State private var tab = 0
    var body: some View {
        VStack(spacing: 0) {
            Picker(L("Conversation"), selection: $tab) { Text(L("Chat")).tag(0); Text(L("Live text")).tag(1); Text(L("Catch up")).tag(2) }.pickerStyle(.segmented).labelsHidden().padding(12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if tab == 0 {
                            if model.guestFeatures.chatHasMore { Button(L("Earlier messages")) { model.loadMoreChat() } }
                            ForEach(timeline) { row in
                                switch row {
                                case .message(let item):
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack { Text(item.sender).font(.caption.bold()); Spacer(); Text(item.sentAt, style: .time).font(.caption2).foregroundStyle(.secondary) }
                                        Text(item.text).textSelection(.enabled)
                                        if item.delivery == .failed { Button(L("Retry")) { chat.retry(item.id) }.font(.caption) }
                                    }
                                case .reaction(let event):
                                    HStack { Text(event.kind.emoji).font(.title2); Text(event.displayName ?? L("Participant")); Spacer(); Text(event.timestamp, style: .time).font(.caption2).foregroundStyle(.secondary) }
                                }
                            }
                            if let reason = chat.unavailableReason { Text(reason).foregroundStyle(.secondary).font(.callout) }
                        } else if tab == 2 {
                            if let warning = model.catchUp.persistenceWarning { Text(warning).foregroundStyle(.orange) }
                            if model.catchUp.timeline.intervals.isEmpty { Text(L("No missed intervals recorded in this meeting.")).foregroundStyle(.secondary) }
                            ForEach(model.catchUp.timeline.intervals) { interval in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(interval.start, style: .time).font(.headline)
                                    Text(interval.isOngoing ? L("Audio interruption in progress") : L("While meeting audio was unavailable")).font(.caption).foregroundStyle(.secondary)
                                    let lines = model.catchUp.timeline.transcript(during: interval)
                                    if lines.isEmpty { Text(L("No transcript is available for this interval.")).foregroundStyle(.secondary) }
                                    ForEach(lines) { line in
                                        Text((line.speaker.map { $0 + ": " } ?? "") + line.text).textSelection(.enabled)
                                    }
                                    Button(L("Mark reviewed")) { model.catchUp.markReviewed(interval.id) }.font(.caption)
                                }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                            }
                        } else {
                            if model.guestFeatures.transcriptHasMore { Button(L("Earlier transcript")) { model.loadMoreTranscript() } }
                            if model.transcript.isEmpty { Text(L("Transcript appears here when the meeting service provides it.")).foregroundStyle(.secondary) }
                            ForEach(model.transcript.suffix(tab == 2 ? 40 : 1000)) { line in
                                VStack(alignment: .leading, spacing: 4) { Text(line.participantName).font(.caption.bold()); Text(line.text).textSelection(.enabled) }
                            }
                            if model.guestFeatures.permissions.canManageTranscript {
                                Button(model.guestFeatures.transcriptionStatus == .active ? L("Stop transcription") : L("Start transcription")) { model.setTranscription(model.guestFeatures.transcriptionStatus != .active) }
                            }
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }.padding(16)
                }.onChange(of: chat.items.last?.id) { _ in proxy.scrollTo("latest", anchor: .bottom) }
            }
            if tab == 0 && !chat.isReadOnly {
                Divider()
                HStack {
                    TextField(L("Message"), text: $chat.draft).onSubmit { _ = chat.send(chat.draft) }.disabled(!chat.canSend)
                    Button { _ = chat.send(chat.draft) } label: { Image(systemName: "arrow.up.circle.fill") }.buttonStyle(.plain).disabled(!chat.canSend || chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(14)
            }
        }.onAppear { chat.isConversationOpen = true }.onDisappear { chat.isConversationOpen = false }
    }
}

struct NativeDesktopMiniMeeting: View {
    @ObservedObject var model: NativeDesktopMeetingModel
    let onRestore: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if model.mediaPresentation == .floating, model.display != .audioOnly, let video = model.floatingVideo { NativeDesktopVideoView(track: video.track, crop: video.crop) }
                else if model.mediaPresentation == .floating, model.display == .all, let camera = model.localCamera { NativeDesktopVideoView(track: camera, mirrored: true) }
                else { Text(model.title).foregroundStyle(.white).padding() }
            }
            HStack {
                Button { model.toggleMicrophone() } label: { Image(systemName: model.snapshot.microphoneOn ? "mic.fill" : "mic.slash") }.help(L("Mute or unmute"))
                NativeDesktopLevelMeter(level: model.snapshot.microphoneLevel ?? 0)
                NativeDesktopMeetingVolume(model: model, compact: true).frame(minWidth: 70, maxWidth: 150)
                Spacer(minLength: 4); Button(L("Show meeting"), action: onRestore)
                Button { Task { await model.onLeave?() } } label: { Image(systemName: "phone.down.fill").foregroundStyle(.red) }.help(L("Leave"))
            }.padding(10).background(.ultraThinMaterial)
        }
    }
}

/// App-only meeting level; the speaker button keeps the existing sound on/off intent.
struct NativeDesktopMeetingVolume: View {
    @ObservedObject var model: NativeDesktopMeetingModel
    var compact = false
    private var percent: String { "\(Int((model.meetingVolume * 100).rounded()))%" }
    var body: some View {
        HStack(spacing: 8) {
            Button { model.togglePlayout() } label: { Image(systemName: model.soundSymbol).frame(width: 22) }
                .buttonStyle(.plain).help(model.snapshot.playoutOn ? L("Turn meeting sound off") : L("Turn meeting sound on"))
                .accessibilityLabel(L("Sound")).accessibilityValue(model.snapshot.playoutOn ? L("On") : L("Off"))
            Slider(value: Binding(get: { model.meetingVolume }, set: { model.setMeetingVolume($0, persist: false) }), in: 0...1,
                   onEditingChanged: { editing in if !editing { model.setMeetingVolume(model.meetingVolume) } })
                .controlSize(compact ? .mini : .regular)
                .accessibilityLabel(L("Meeting volume")).accessibilityValue(percent)
                .accessibilityIdentifier("meeting.volume")
            if !compact { Text(percent).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 38, alignment: .trailing) }
        }.opacity(model.snapshot.playoutOn ? 1 : 0.6)
    }
}

/// Two clicks to a live share: Share, then a source. Studio work is optional.
private struct NativeDesktopSharePopover: View {
    @ObservedObject var model: NativeDesktopMeetingModel
    let chooseImage: () -> Void
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Share")).font(.headline).padding(.bottom, 4)
            row("macwindow.on.rectangle", L("Screen or window…"), L("Pick in the macOS picker. Sharing starts right after.")) { close(); model.quickShare() }
                .accessibilityIdentifier("share.quick-screen")
            row("photo.on.rectangle", L("Slides or image…"), L("Share a picture or an exported slide.")) { close(); chooseImage() }
                .accessibilityIdentifier("share.quick-image")
            row("slider.horizontal.below.rectangle", L("Presenter studio…"), L("Draw, arrange your camera and preview privately first.")) { close(); model.panel = .presenter }
                .accessibilityIdentifier("share.studio")
            Divider().padding(.vertical, 6)
            Toggle(L("Include my camera"), isOn: $model.shareIncludesCamera).accessibilityIdentifier("share.include-camera")
            Text(L("Nothing is visible to the meeting until you pick a source.")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(width: 320)
    }
    private func row(_ symbol: String, _ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title3).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }.padding(8).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!model.connected || model.quickSharePending)
    }
}

/// Shown on a tile when the listener changed that speaker's level.
struct NativeDesktopParticipantVolumeBadge: View {
    let level: Double
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: level == 0 ? "speaker.slash.fill" : level < 1 ? "speaker.wave.1.fill" : "speaker.wave.3.fill")
            if level > 0 { Text("\(Int((level * 100).rounded()))%").monospacedDigit() }
        }.foregroundStyle(level == 0 ? Color.orange : Color.secondary)
            .help(level == 0 ? L("Muted for you") : L("Volume for you: %d%%", Int((level * 100).rounded())))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(level == 0 ? L("Muted for you") : L("Volume for you: %d%%", Int((level * 100).rounded())))
    }
}

/// Per-speaker level for this listener only; nothing is sent to the meeting.
struct NativeDesktopParticipantVolumeButton: View {
    @ObservedObject var model: NativeDesktopMeetingModel
    let person: NativeDesktopParticipant
    @State private var open = false
    private var level: Double { model.participantVolume(person.id) }
    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: level == 0 ? "speaker.slash.fill" : level == 1 ? "speaker.wave.2" : "speaker.wave.2.fill")
                .foregroundStyle(level == 0 ? Color.orange : level == 1 ? Color.secondary : Color.accentColor)
        }.buttonStyle(.plain).help(L("Volume for me")).accessibilityLabel(L("Volume for %@", person.name))
            .accessibilityIdentifier("participant.volume.\(person.id)")
            .popover(isPresented: $open, arrowEdge: .leading) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(person.name).font(.headline).lineLimit(1)
                    HStack(spacing: 8) {
                        Slider(value: Binding(get: { level }, set: { model.setParticipantVolume(($0 * 20).rounded() / 20, participantID: person.id) }), in: 0...2)
                            .accessibilityLabel(L("Volume for %@", person.name))
                        Text("\(Int((level * 100).rounded()))%").font(.caption).monospacedDigit().frame(width: 42, alignment: .trailing)
                    }
                    HStack {
                        Button(level == 0 ? L("Unmute for me") : L("Mute for me")) { model.setParticipantVolume(level == 0 ? 1 : 0, participantID: person.id) }
                        Spacer()
                        Button(L("Reset")) { model.setParticipantVolume(1, participantID: person.id) }.disabled(level == 1)
                    }
                    Text(L("Only you hear this change.")).font(.caption).foregroundStyle(.secondary)
                }.padding(16).frame(width: 260)
            }
    }
}
