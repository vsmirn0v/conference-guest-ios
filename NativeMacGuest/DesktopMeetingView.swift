import AppKit
import Combine
import ConferenceCore
import SwiftUI

/// Hides a window without leaving an empty full-screen Space behind. A
/// full-screen window leaves full screen first; AppKit ignores a toggle during a
/// running transition, so a pending hide waits for it.
@MainActor final class NativeDesktopWindowHider {
#if DEBUG
    private(set) var events: [String] = []
#endif
    private var afterExit: (() -> Void)?
    private var transitioning = false
    private func note(_ event: String) {
#if DEBUG
        events.append(event)
#endif
    }
    func hide(_ window: NSWindow, then action: @escaping () -> Void = {}) {
        note("hide transition=\(transitioning)")
        guard window.styleMask.contains(.fullScreen) else { window.orderOut(nil); action(); return }
        afterExit = { [weak window] in window?.orderOut(nil); action() }
        if !transitioning { window.toggleFullScreen(nil) }
    }
    private func finish() { let action = afterExit; afterExit = nil; action?() }
    func willEnter() { note("willEnter"); transitioning = true }
    func didEnter(_ window: NSWindow) {
        note("didEnter"); transitioning = false
        // A toggle inside this callback is ignored; AppKit finishes the transition first.
        guard afterExit != nil else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, afterExit != nil, !transitioning, window.styleMask.contains(.fullScreen) else { return }
            window.toggleFullScreen(nil)
        }
    }
    func failEnter() { note("failEnter"); transitioning = false; finish() }
    func willExit() { note("willExit"); transitioning = true }
    func didExit() { note("didExit"); transitioning = false; finish() }
    func failExit() { note("failExit"); transitioning = false; finish() }
}

/// A meeting's presentation outside the main window. With a workspace the
/// meeting lives in the main window's detail column until Open in New Window
/// detaches it here; closing that window moves it back. A standalone meeting
/// (no workspace) always uses this window.
@MainActor final class NativeDesktopMeetingWindow: NSObject, NSWindowDelegate {
    private let model: NativeDesktopMeetingModel
    private let continuation: MeetingContinuationCoordinator?
    private let window: NSWindow
    private var mini: NSPanel?
    private weak var workspace: NativeDesktopWorkspace?
    private var titleSubscription: AnyCancellable?
    private let hider = NativeDesktopWindowHider()
    private(set) var detached = false
    init(model: NativeDesktopMeetingModel, continuation: MeetingContinuationCoordinator? = nil, workspace: NativeDesktopWorkspace? = nil) {
        self.model = model
        self.continuation = continuation
        self.workspace = workspace
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = model.title; window.minSize = NSSize(width: 740, height: 520)
        window.isReleasedWhenClosed = false; window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden; window.delegate = self
        // Detached meetings group as native tabs and can be dragged apart.
        window.tabbingIdentifier = "nativeDesktop.meeting"; window.tabbingMode = .preferred
        if !window.setFrameAutosaveName("nativeDesktop.meeting") { window.center() } else { window.center() }
        titleSubscription = model.$title.sink { [weak window = window] in window?.title = $0 }
    }
    /// Shown in the main window rather than in its own window.
    var isEmbedded: Bool { workspace != nil && !detached }
    var isVisible: Bool { window.isVisible || mini?.isVisible == true }
    var isMiniVisible: Bool { mini?.isVisible == true }
    /// Re-shown detached meetings join a visible meeting's tab group explicitly.
    func show(tabbedWith other: NativeDesktopMeetingWindow?) {
        if !isEmbedded, let other, other !== self, !other.isEmbedded, !window.isVisible, other.window.isVisible,
           other.window.tabbingIdentifier == window.tabbingIdentifier, other.window.tabbedWindows?.contains(window) != true {
            other.window.addTabbedWindow(window, ordered: .above)
        }
        show()
    }
    var isKeyWindow: Bool { (!isEmbedded && window.isKeyWindow) || mini?.isKeyWindow == true }
    private func mountMeeting() {
        if !(window.contentView is NSHostingView<NativeDesktopMeetingView>) {
            window.contentView = NSHostingView(rootView: NativeDesktopMeetingView(model: model, onMini: { [weak self] in self?.showMini() },
                continuation: continuation, workspace: workspace,
                onWindowToggle: workspace == nil ? nil : { [weak self] in self?.moveToMainWindow() }))
        }
    }
    func show() {
        mini?.orderOut(nil); mini?.contentView = nil
        if isEmbedded { workspace?.presentEmbedded(model); return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        mountMeeting(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        synchronizePresentation()
    }
    /// Open in New Window: the meeting leaves the main window's detail.
    func detach() {
        guard isEmbedded else { show(); return }
        detached = true; show(); workspace?.meetingDidMove(model)
    }
    /// Closing a detached window returns its meeting to the main window.
    func moveToMainWindow() {
        guard detached, workspace != nil else { return }
        hider.hide(window) { [weak self] in
            guard let self, detached else { return }
            window.contentView = nil; detached = false
            workspace?.presentEmbedded(model)
        }
    }
    func close() {
        model.setMediaVisible(false); mini?.close(); mini = nil
        // orderOut keeps a full-screen window in its Space; closing ends the Space too.
        if window.styleMask.contains(.fullScreen) { window.close() } else { window.orderOut(nil) }
        window.contentView = nil
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === mini {
            mini?.orderOut(nil); mini?.contentView = nil; synchronizePresentation(); workspace?.meetingDidMove(model)
            return false
        }
        if detached && workspace != nil { moveToMainWindow(); return false }
        hider.hide(window) { [weak self] in self?.window.contentView = nil; self?.synchronizePresentation() }
        return false
    }
#if DEBUG
    var fullScreenEventsForTesting: [String] { hider.events }
#endif
    func windowWillEnterFullScreen(_ notification: Notification) { hider.willEnter() }
    func windowDidEnterFullScreen(_ notification: Notification) { hider.didEnter(window) }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { hider.failEnter() }
    func windowWillExitFullScreen(_ notification: Notification) { hider.willExit() }
    func windowDidExitFullScreen(_ notification: Notification) { hider.didExit() }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { hider.failExit() }
    func windowWillMiniaturize(_ notification: Notification) {
        if !isEmbedded { model.setMediaPresentation(.hidden) }
    }
    func windowDidMiniaturize(_ notification: Notification) { synchronizePresentation() }
    func windowDidDeminiaturize(_ notification: Notification) { synchronizePresentation() }
    func windowDidChangeOcclusionState(_ notification: Notification) { synchronizePresentation() }
    private func mountMini() {
        if !(mini?.contentView is NSHostingView<NativeDesktopMiniMeeting>) {
            mini?.contentView = NSHostingView(rootView: NativeDesktopMiniMeeting(model: model, onRestore: { [weak self] in self?.show() }))
        }
    }
    private func synchronizePresentation() {
        if isEmbedded { workspace?.synchronizeMeetingPresentation(); return }
        let mainVisible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        let miniVisible = mini.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        if miniVisible { mountMini() }
        // Keep editor/zoom state through occlusion. Only the media subtree is
        // unmounted; destroying the shell would close a private Presenter draft.
        if mainVisible { mountMeeting() }
        model.setMediaPresentation(mainVisible ? .meeting : miniVisible ? .floating : .hidden)
    }
    /// The workspace decides an embedded meeting's presentation: the selected
    /// meeting in a visible main window renders in full, the browsing preview
    /// and Mini meeting render one floating video, every other meeting is audio only.
    func synchronizeEmbedded(shown: Bool, preview: Bool) {
        guard isEmbedded else { return }
        let miniVisible = mini.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        if miniVisible { mountMini() }
        model.setMediaPresentation(shown ? .meeting : miniVisible || preview ? .floating : .hidden)
    }
    func showMini() {
        if mini == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 270),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.delegate = self; panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.isReleasedWhenClosed = false
            panel.title = model.title; panel.minSize = NSSize(width: 280, height: 210)
            panel.center(); mini = panel
        }
        mountMini()
        mini?.orderFrontRegardless()
        if isEmbedded { workspace?.meetingDidEnterMini(model); return }
        hider.hide(window) { [weak self] in self?.synchronizePresentation() }
    }
}

struct NativeDesktopMeetingView: View {
    @ObservedObject var model: NativeDesktopMeetingModel
    let onMini: () -> Void
    var continuation: MeetingContinuationCoordinator? = nil
    var workspace: NativeDesktopWorkspace? = nil
    /// Open in New Window from the main window, or back to it from a detached window.
    var onWindowToggle: (() -> Void)? = nil
    /// In the main window the toolbar carries the title.
    var embedded = false
    /// One window shows one alert: an embedded meeting defers to the window's own.
    var presentsErrors = true
    @State private var reactionsOpen = false
    @State private var railCollapsed = false
    @State private var chromeVisible = true
    @State private var chromeTask: Task<Void, Never>?
    @State private var immersiveHint = false
    /// Immersive view keeps only the content until the pointer moves.
    private var chromeShown: Bool { !model.immersive || chromeVisible }
    private func revealChrome() {
        guard model.immersive else { return }
        chromeVisible = true; chromeTask?.cancel()
        chromeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { chromeVisible = false }
        }
    }
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
                if model.mediaPresentation == .meeting {
                    let edge: CGFloat = model.immersive ? 0 : 14
                    media.padding(.leading, edge).padding(.trailing, edge + reserved)
                        .padding(.top, model.immersive ? 0 : (model.controlsHidden || embedded ? 12 : 70) + (model.isSharingLive ? 48 : 0))
                        .padding(.bottom, model.immersive ? 0 : model.controlsHidden ? 12 : singleControlRow ? 96 : (model.showsFocus ? 90 : 160))
                }
                if textSelection.isOpen { NativeDesktopSharedTextView(model: textSelection, meetingTools: AnyView(viewAndMoreMenus)) }
                VStack(spacing: 0) {
                    // In the main window the toolbar holds the title, status and meeting buttons.
                    if !model.controlsHidden && !textSelection.isOpen && !embedded && chromeShown { header.padding(.horizontal, 18).padding(.top, 10) }
                    if let workspace, !textSelection.isOpen { NativeDesktopListeningBanner(workspace: workspace, model: model).padding(.top, 8).padding(.trailing, reserved) }
                    if !textSelection.isOpen && !embedded { NativeDesktopTranscriptionBanner(model: model).padding(.top, 8).padding(.trailing, reserved) }
                    if !textSelection.isOpen { NativeDesktopCatchUpCard(model: model).padding(.top, 8).padding(.trailing, reserved) }
                    if model.isSharingLive && !textSelection.isOpen { shareBanner.padding(.top, 8).padding(.trailing, reserved) }
                    if !textSelection.isOpen { HStack { reactionOverlay; Spacer() }.padding(.leading, 22).padding(.top, 12) }
                    Spacer(minLength: 0)
                    if model.immersive && immersiveHint {
                        Text(L("Move the pointer to show controls · Esc to leave immersive view")).font(.callout)
                            .padding(.horizontal, 14).padding(.vertical, 8).background(.black.opacity(0.7), in: Capsule()).padding(.bottom, 22)
                    } else if !model.controlsHidden && chromeShown { controls.padding(.bottom, 18) }
                }
                if model.controlsHidden {
                    VStack { Spacer(); Button(L("Show controls")) { model.controlsHidden = false }.buttonStyle(.bordered).padding() }
                }
            }.foregroundStyle(.white)
            .onContinuousHover { phase in if case .active = phase { revealChrome() } }
            if let docked {
                inspector(docked).frame(width: Self.panelWidth)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
                    .padding(.trailing, 14).padding(.top, model.controlsHidden || embedded ? 12 : 64)
                    .padding(.bottom, model.controlsHidden ? 12 : 150)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }.animation(.easeOut(duration: 0.18), value: docked)
        .sheet(isPresented: Binding(get: { geometry.size.width < 1040 && model.panel != nil }, set: { if !$0 && model.panel != nil { model.panel = nil } })) {
            if let panel = model.panel { inspector(panel).frame(width: 380, height: 560) }
        }
        }
        }
        .onChange(of: textSourceID) { _ in updateTextSource() }
        .onChange(of: model.immersive) { on in
            chromeTask?.cancel(); chromeVisible = !on; immersiveHint = on
            if on { Task { @MainActor in try? await Task.sleep(for: .seconds(3)); immersiveHint = false } }
        }
        .onChange(of: model.showsFocus) { focused in if !focused { model.immersive = false } }
        .onChange(of: model.snapshot.phase) { phase in if phase == .left || phase == .leaving || phase == .failed { textSelection.close() } }
        .onDisappear { textSelection.close() }
        .alert(L("Meeting"), isPresented: Binding(get: { presentsErrors && model.error != nil }, set: { if !$0 && presentsErrors && model.error != nil { model.error = nil } })) {
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
                // In the main window the toolbar carries the title and count.
                if !embedded {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.title).font(.headline).lineLimit(1)
                        Text(model.connected ? L("%ld participants", model.participants.count) : L(model.snapshot.phase.rawValue.capitalized)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, 16).padding(.vertical, 10).nativeMeetingChrome()
                }
                NativeDesktopTranscriptionPill(model: model)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if let workspace { NativeDesktopMeetingsButton(workspace: workspace, current: model) }
                iconButton("person.2", L("Participants")) { togglePanel(.participants) }
                iconButton("bubble.left", L("Conversation")) { togglePanel(.conversation) }
                iconButton("pip.enter", L("Mini meeting"), action: onMini)
                if let onWindowToggle {
                    iconButton(embedded ? "macwindow.on.rectangle" : "sidebar.left",
                               embedded ? L("Open in New Window") : L("Move to Main Window"), action: onWindowToggle)
                }
            }.padding(6).nativeMeetingChrome()
        }
    }
    /// View and More join the control bar unless text selection or paging needs the upper row.
    private var singleControlRow: Bool {
        textSourceID == nil && !(model.galleryPages > 1 && !model.showsFocus)
    }
    private var controls: some View {
        VStack(spacing: 10) {
            if !textSelection.isOpen && !singleControlRow { HStack(spacing: 8) {
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
                if singleControlRow && !textSelection.isOpen {
                    Menu { viewMenuItems } label: { controlLabel(viewMenuSymbol, L("View")) }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help(viewMenuTitle)
                    Menu { moreMenuItems } label: { controlLabel("ellipsis", L("More")) }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                }
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
    private func controlLabel(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 5) { Image(systemName: symbol).font(.title3); Text(title).font(.caption) }
            .foregroundStyle(.primary).frame(width: 66, height: 48).contentShape(Rectangle())
    }
    @ViewBuilder private var viewMenuItems: some View {
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
    }
    @ViewBuilder private var moreMenuItems: some View {
        Button(L("Participants")) { togglePanel(.participants) }
        Button(L("Conversation")) { togglePanel(.conversation) }
        Button(L("Mini meeting"), action: onMini)
        Button(L("Camera & sound")) { togglePanel(.studio) }
        Button(L("Presenter studio")) { togglePanel(.presenter) }
        Button(L("Reconnect")) { model.reconnect() }
        Button(L("Copy invitation")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.invitation.absoluteString, forType: .string) }
        Button(L("Hide controls")) { model.controlsHidden = true }
        if model.showsFocus { Button(model.immersive ? L("Leave immersive view") : L("Immersive view")) { model.immersive.toggle() } }
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
    /// The participants panel already lists everyone; the rail would repeat it.
    private var showsRail: Bool { !model.immersive && !railCollapsed && model.panel != .participants && model.participants.count > 1 }
    /// Beside a focused share or person: who is here, who is talking, one click to focus them.
    @ViewBuilder private var speakerRail: some View {
        if showsRail {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("%ld participants", model.participants.count)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { railCollapsed = true } label: { Image(systemName: "sidebar.right") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Hide speakers")).accessibilityLabel(L("Hide speakers"))
                }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.railParticipants) { person in
                            Button { model.focus(participantID: person.id, source: person.sharing == true && person.cameraOn != true ? .screen : .camera) } label: {
                                participantTile(person, compact: true).frame(height: 112)
                            }.buttonStyle(.plain).help(L("Focus %@", person.name))
                        }
                    }
                }
            }.frame(width: 200)
        }
    }
    @ViewBuilder private var railRestoreButton: some View {
        if railCollapsed && !model.immersive && model.panel != .participants && model.participants.count > 1 {
            Button { railCollapsed = false } label: { Image(systemName: "person.2").frame(width: 30, height: 28) }
                .buttonStyle(.plain).background(.black.opacity(0.6), in: Capsule()).padding(12)
                .help(L("Show speakers")).accessibilityLabel(L("Show speakers"))
        }
    }
    /// Who is talking, on top of the content, so nobody looks away from the share to find out.
    @ViewBuilder private var speakerChip: some View {
        if let speaker = model.activeSpeaker {
            let title = speaker.isLocal ? L("You") : speaker.name
            HStack(spacing: 8) {
                Text(initials(speaker.name)).font(.caption2.bold()).frame(width: 24, height: 24)
                    .background(.white.opacity(0.12), in: Circle()).overlay(Circle().stroke(Color.green, lineWidth: 2))
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                NativeDesktopLevelMeter(level: speaker.isLocal ? model.snapshot.microphoneLevel ?? 0.5 : 0.7)
            }.padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 6)
                .background(.black.opacity(0.7), in: Capsule()).overlay(Capsule().stroke(Color.green.opacity(0.6)))
                .padding(12).accessibilityElement(children: .ignore).accessibilityLabel(L("%@ is speaking", title))
                .animation(.easeOut(duration: 0.15), value: speaker.id)
        }
    }
    @ViewBuilder private var mediaContent: some View {
        if model.showsFocus, let focused = model.focusedVideo {
            HStack(spacing: 10) {
                NativeDesktopZoomVideo(video: focused, name: name(focused.participantID), viewport: focusedViewport,
                    textFrame: textFrame, selectText: { model.controlsHidden = false; updateTextSource(); textSelection.open(zoom: focusedViewport.zoom, pan: focusedViewport.pan, viewportSize: focusedViewport.size) },
                    immersive: model.immersive, onImmersive: { model.immersive.toggle() })
                    .overlay(alignment: .topLeading) { speakerChip }
                    .overlay(alignment: .topTrailing) { railRestoreButton }
                speakerRail
            }
        } else if model.showsFocus, let focusedID = model.focusedParticipantID,
                  let person = model.participants.first(where: { $0.id == focusedID }), !model.focusedVideoExpected {
            // No video is expected here: keep the person, mic and speaking state in focus.
            HStack(spacing: 10) { participantTile(person, compact: false); speakerRail }
        } else if model.showsFocus, let focusedID = model.focusedParticipantID {
            HStack(spacing: 10) {
                VStack(spacing: 16) { ProgressView(); Text(L("Waiting for stream…")); Text(name(focusedID)).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                speakerRail
            }
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
            case .participants: NativeDesktopParticipantsList(model: model)
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
    var immersive = false
    var onImmersive: (() -> Void)? = nil
    private var zoom: CGFloat { get { viewport.zoom } nonmutating set { viewport.zoom = newValue } }
    private func setZoom(_ value: CGFloat) {
        zoom = min(8, max(1, value)); savedZoom = zoom
        if zoom == 1 { pan = .zero; savedPan = .zero }
    }
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
                .onTapGesture(count: 2) { setZoom(zoom > 1 ? 1 : 2) }
                .overlay(alignment: .bottomLeading) {
                    Label(video.source == .screen ? L("%@ is presenting", name) : name, systemImage: video.source == .screen ? "rectangle.on.rectangle" : "video")
                        .font(.caption).lineLimit(1).frame(maxWidth: max(80, min(400, geometry.size.width - 260)), alignment: .leading)
                        .padding(8).background(.black.opacity(0.55), in: Capsule()).padding(10)
                }
                .overlay(alignment: .bottomTrailing) {
                    VStack(alignment: .trailing, spacing: 6) {
                        if zoom > 1 { NativeDesktopZoomIndicator(zoom: zoom, pan: pan, aspect: geometry.size) }
                        HStack(spacing: 4) {
                            Button { setZoom(zoom - 0.5) } label: { Image(systemName: "minus").frame(width: 26, height: 24) }
                                .keyboardShortcut("-", modifiers: .command).disabled(zoom <= 1).help(L("Zoom out")).accessibilityLabel(L("Zoom out"))
                            Button { setZoom(1) } label: { Text(zoom > 1 ? "\(Int((zoom * 100).rounded()))%" : L("Fit")).font(.caption.monospacedDigit()).frame(minWidth: 40) }
                                .help(L("Fit to screen")).accessibilityLabel(L("Fit to screen"))
                            Button { setZoom(zoom + 0.5) } label: { Image(systemName: "plus").frame(width: 26, height: 24) }
                                .keyboardShortcut("=", modifiers: .command).help(L("Zoom in")).accessibilityLabel(L("Zoom in"))
                            if let onImmersive {
                                Divider().frame(height: 16)
                                Button(action: onImmersive) {
                                    Image(systemName: immersive ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").frame(width: 26, height: 24)
                                }.help(immersive ? L("Leave immersive view") : L("Immersive view"))
                                    .accessibilityLabel(immersive ? L("Leave immersive view") : L("Immersive view"))
                            }
                        }.buttonStyle(.plain).padding(.horizontal, 6).padding(.vertical, 4).nativeMeetingChrome()
                    }.padding(10)
                }
        }.clipShape(RoundedRectangle(cornerRadius: immersive ? 0 : 14))
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
    private var tab: Int { model.conversationTab }
    var body: some View {
        VStack(spacing: 0) {
            let unread = model.catchUp.timeline.unreadCount
            Picker(L("Conversation"), selection: $model.conversationTab) {
                Text(L("Chat")).tag(0); Text(L("Live text")).tag(1)
                Text(unread > 0 ? L("Catch up (%ld)", unread) : L("Catch up")).tag(2)
            }.pickerStyle(.segmented).labelsHidden().padding(12)
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
                                    HStack(spacing: 4) {
                                        Text(interval.start, style: .time)
                                        if let end = interval.end { Text("–"); Text(end, style: .time) }
                                    }.font(.headline)
                                    Text(NativeDesktopCatchUpCard.title(interval)).font(.caption).foregroundStyle(.secondary)
                                    let lines = model.catchUp.timeline.transcript(during: interval)
                                    let reactions = model.catchUpReactions(interval)
                                    if lines.isEmpty { Text(L("No transcript is available for this interval.")).foregroundStyle(.secondary) }
                                    ForEach(lines) { line in
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack {
                                                if let speaker = line.speaker { Text(speaker).font(.caption.bold()) }
                                                Spacer()
                                                if let time = line.spokenAt { Text(time, style: .time).font(.caption2).foregroundStyle(.secondary) }
                                            }
                                            Text(line.text).textSelection(.enabled)
                                        }
                                    }
                                    if !reactions.isEmpty {
                                        HStack(spacing: 6) {
                                            ForEach(reactions.suffix(12)) { event in Text(event.kind.emoji).help(event.displayName ?? L("Participant")) }
                                        }.font(.title3).accessibilityLabel(L("%ld reactions", reactions.count))
                                    }
                                    if !interval.isOngoing && !model.catchUp.timeline.isReviewed(interval) {
                                        Button(L("Mark reviewed")) { model.catchUp.markReviewed(interval.id) }.font(.caption)
                                    }
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(model.catchUpFocus == interval.id ? Color.accentColor : .clear, lineWidth: 2))
                                    .id(interval.id)
                            }
                        } else {
                            if model.guestFeatures.transcriptionStatus == .active {
                                HStack(spacing: 8) {
                                    Circle().fill(Color.orange).frame(width: 7, height: 7)
                                    Text(model.transcriptionSince.map { L("Transcription is on since %@", $0.formatted(date: .omitted, time: .shortened)) } ?? L("Meeting transcription is on"))
                                }.font(.caption).foregroundStyle(.orange).padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                            }
                            if model.guestFeatures.transcriptHasMore { Button(L("Earlier transcript")) { model.loadMoreTranscript() } }
                            if model.transcript.isEmpty { Text(L("Transcript appears here when the meeting service provides it.")).foregroundStyle(.secondary) }
                            ForEach(model.liveTextRows()) { row in
                                switch row {
                                case .line(let line, let time):
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(line.participantName).font(.caption.bold()); Spacer()
                                            if let time { Text(time, style: .time).font(.caption2).foregroundStyle(.secondary) }
                                        }
                                        Text(line.text).textSelection(.enabled)
                                    }
                                case .reaction(let event):
                                    HStack(spacing: 6) {
                                        Text(event.kind.emoji)
                                        Text(event.displayName ?? L("Participant")).font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        Text(event.timestamp, style: .time).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            if model.guestFeatures.permissions.canManageTranscript {
                                Button(model.guestFeatures.transcriptionStatus == .active ? L("Stop transcription") : L("Start transcription")) { model.setTranscription(model.guestFeatures.transcriptionStatus != .active) }
                            }
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }.padding(16)
                }.onChange(of: chat.items.last?.id) { _ in proxy.scrollTo("latest", anchor: .bottom) }
                    .onChange(of: model.catchUpFocus) { id in if let id { proxy.scrollTo(id, anchor: .top) } }
                    .onAppear { if tab == 2, let id = model.catchUpFocus { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) } } }
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

/// Shown in a listening meeting while the microphone is live in another one, so
/// the user never talks into the wrong room.
struct NativeDesktopListeningBanner: View {
    @ObservedObject var workspace: NativeDesktopWorkspace
    @ObservedObject var model: NativeDesktopMeetingModel
    var body: some View {
        if workspace.meetings.count > 1, !model.ownsMicrophone, let talk = workspace.talkMeeting, talk !== model, talk.snapshot.microphoneOn {
            HStack(spacing: 10) {
                Image(systemName: "ear").foregroundStyle(.secondary)
                Text(L("Your microphone is on in “%@”. Unmute to talk here instead.", talk.title)).font(.callout).lineLimit(2)
                Button(L("Unmute here")) { model.toggleMicrophone() }.controlSize(.small)
            }.padding(.horizontal, 14).padding(.vertical, 8).nativeMeetingChrome()
        }
    }
}

/// Header entry to every simultaneous meeting: switch, mute, silence or leave.
struct NativeDesktopMeetingsButton: View {
    @ObservedObject var workspace: NativeDesktopWorkspace
    let current: NativeDesktopMeetingModel
    @State private var open = false
    var body: some View {
        if workspace.meetings.count > 1 {
            Button { open.toggle() } label: {
                HStack(spacing: 4) { Image(systemName: "rectangle.stack"); Text("\(workspace.meetings.count)").font(.caption).monospacedDigit() }
                    .frame(height: 30).padding(.horizontal, 6)
            }.buttonStyle(.plain).help(L("Meetings")).accessibilityLabel(L("Meetings: %d", workspace.meetings.count))
                .accessibilityIdentifier("meetings.switcher")
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    NativeDesktopMeetingsPopover(workspace: workspace, current: current, close: { open = false })
                }
        }
    }
}

struct NativeDesktopMeetingsPopover: View {
    @ObservedObject var workspace: NativeDesktopWorkspace
    let current: NativeDesktopMeetingModel
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Meetings")).font(.headline).padding(.bottom, 6)
            ForEach(Array(workspace.meetings.enumerated()), id: \.element.sessionID) { index, model in
                NativeDesktopMeetingRow(workspace: workspace, model: model, index: index, current: model === current, close: close)
            }
            Divider().padding(.vertical, 6)
            Button(L("Leave all meetings…")) { close(); workspace.leaveAllConfirmed() }.buttonStyle(.plain).foregroundStyle(.red)
            Text(L("Your microphone and camera work in one meeting at a time. Use headphones to avoid echo between meetings."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
        }.padding(16).frame(width: 380)
    }
}

private struct NativeDesktopMeetingRow: View {
    let workspace: NativeDesktopWorkspace
    @ObservedObject var model: NativeDesktopMeetingModel
    let index: Int
    let current: Bool
    let close: () -> Void
    @State private var hovering = false
    private var speaking: Bool { model.participants.contains { !$0.isLocal && $0.speaking == true } }
    var body: some View {
        HStack(spacing: 10) {
            // The row itself shows the meeting; its trailing buttons act without switching.
            Button { close(); workspace.showMeeting(model) } label: {
                HStack(spacing: 10) {
                    Circle().fill(model.ownsMicrophone && model.snapshot.microphoneOn ? Color.red : speaking ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.title).font(.body.weight(current ? .semibold : .regular)).lineLimit(1)
                        Text(NativeDesktopWorkspace.statusText(model) + " · " + L("%ld participants", model.participants.count) +
                             (speaking && !model.snapshot.playoutOn ? " · " + L("Someone is speaking") : ""))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help(L("Show meeting") + (index < 9 ? " (⌃⌘\(index + 1))" : ""))
                .accessibilityLabel(L("Show meeting") + ", " + model.title)
            Button { model.toggleMicrophone() } label: {
                Image(systemName: model.ownsMicrophone && model.snapshot.microphoneOn ? "mic.fill" : "mic.slash")
                    .foregroundStyle(model.ownsMicrophone && model.snapshot.microphoneOn ? Color.red : Color.primary)
            }.buttonStyle(.plain).help(model.ownsMicrophone ? L("Mute or unmute") : L("Unmute here"))
            Button { model.togglePlayout() } label: { Image(systemName: model.soundSymbol) }
                .buttonStyle(.plain).help(L("Silence or restore this meeting (⇧⌘S)"))
            Button { Task { _ = await workspace.leave(model) } } label: { Image(systemName: "phone.down.fill").foregroundStyle(.red) }
                .buttonStyle(.plain).help(L("Leave"))
        }.padding(.vertical, 6).padding(.horizontal, 8)
            .background(current ? Color.accentColor.opacity(0.12) : hovering ? Color.primary.opacity(0.06) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .onHover { hovering = $0 }
    }
}

/// A toolbar item in its own glass group. The system glass is its only container:
/// a capsule drawn inside toolbar glass is cut by the group's rounded edge.
struct NativeDesktopStandaloneToolbarItem<Content: View>: ToolbarContent {
    @ViewBuilder let content: () -> Content
    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) { content() }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        } else {
            ToolbarItem(placement: .primaryAction) { content() }
        }
    }
}

/// Transcription is a status people must notice and understand: a labelled
/// pill that explains itself, instead of an unlabelled glyph.
struct NativeDesktopTranscriptionPill: View {
    @ObservedObject var model: NativeDesktopMeetingModel
    /// Toolbar size; the stage header uses the regular size.
    var compact = false
    /// When the toolbar has room, the one-time announcement grows out of the pill.
    var announcesInline = false
    @State private var open = false
    var body: some View {
        if announcesInline, model.transcriptionAnnouncement, model.transcriptionIndicator == .on {
            // Orange marks the status only; the sentence stays in the primary text
            // colour on an opaque material so it reads on any toolbar backdrop.
            // A prominent (filled) button here tints a toolbar item's whole glass.
            HStack(spacing: 8) {
                Circle().fill(Color.orange).frame(width: 7, height: 7)
                Image(systemName: "text.bubble.fill").foregroundStyle(.orange)
                (Text(L("Transcription started.")).bold().foregroundColor(.orange) + Text(" ") +
                 Text(L("What people say, including you, is turned into text.")))
                    .foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
                Button(L("Show live text")) { model.showLiveText() }
                    .buttonStyle(.bordered).controlSize(.small)
                Button { model.dismissTranscriptionAnnouncement() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(L("Dismiss"))
            }.font(.callout).padding(.horizontal, 6).fixedSize()
                .accessibilityElement(children: .contain).accessibilityIdentifier("transcription.announcement")
        } else if let state = model.transcriptionIndicator {
            let tint: Color = state == .on ? .orange : .red
            let title = state == .on ? L("Transcribing") : L("Transcription stopped")
            Button { open.toggle() } label: {
                HStack(spacing: 7) {
                    if state == .on { Circle().fill(tint).frame(width: 7, height: 7) }
                    Image(systemName: state == .on ? "text.bubble.fill" : "exclamationmark.triangle.fill")
                    Text(title).font((compact ? Font.subheadline : .callout).weight(.semibold))
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2.weight(.bold))
                }.foregroundStyle(tint).padding(.horizontal, compact ? 6 : 12).frame(height: compact ? 26 : 32)
                    // In the toolbar the system glass is the capsule; the meeting header draws its own.
                    .background(compact ? Color.clear : tint.opacity(open ? 0.28 : 0.16), in: Capsule())
                    .overlay(Capsule().strokeBorder(compact ? Color.clear : tint.opacity(open ? 0.9 : 0.5)))
                    .contentShape(Capsule())
            }.buttonStyle(.plain).help(L("What transcription means for this meeting"))
                .accessibilityLabel(title).accessibilityHint(L("What transcription means for this meeting"))
                .accessibilityIdentifier("transcription.indicator")
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    NativeDesktopTranscriptionDetails(model: model, close: { open = false })
                }
        }
    }
}

private struct NativeDesktopTranscriptionDetails: View {
    @ObservedObject var model: NativeDesktopMeetingModel
    let close: () -> Void
    var body: some View {
        let failed = model.transcriptionIndicator == .failed, manages = model.guestFeatures.permissions.canManageTranscript
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: failed ? "exclamationmark.triangle.fill" : "text.bubble.fill").font(.title2)
                    .foregroundStyle(failed ? Color.red : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(failed ? L("Transcription stopped unexpectedly") : L("This meeting is being transcribed")).font(.headline)
                    if !failed, let since = model.transcriptionSince {
                        Text(L("On since %@", since.formatted(date: .omitted, time: .shortened))).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if failed {
                Text(L("The meeting service reported an error, so new speech is not being turned into text. Text captured so far stays in Live text."))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label(L("What people say, including you when you unmute, is turned into text by the meeting service."), systemImage: "mic")
                    .fixedSize(horizontal: false, vertical: true)
                Label(L("The meeting service may keep the transcript after the meeting."), systemImage: "doc.text")
                    .fixedSize(horizontal: false, vertical: true)
                if !manages { Text(L("Only the organizer can stop transcription.")).foregroundStyle(.secondary) }
            }
            HStack(spacing: 8) {
                Button(L("Show live text")) { close(); model.showLiveText() }.buttonStyle(.borderedProminent)
                if manages {
                    Button(failed ? L("Restart transcription") : L("Stop transcription"), role: failed ? nil : .destructive) {
                        close(); model.setTranscription(failed)
                    }
                }
            }.padding(.top, 2)
        }.font(.callout).padding(16).frame(width: 340, alignment: .leading)
    }
}

/// Shown once when transcription starts or is found running on join.
struct NativeDesktopTranscriptionBanner: View {
    @ObservedObject var model: NativeDesktopMeetingModel
    var body: some View {
        if model.transcriptionAnnouncement {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble.fill").foregroundStyle(.orange)
                (Text(L("Transcription started.")).bold() + Text(" ") +
                 Text(L("What people say, including you, is turned into text.")).foregroundColor(.secondary))
                    .font(.callout).lineLimit(2)
                Button(L("Show live text")) { model.showLiveText() }.controlSize(.small)
                Button { model.dismissTranscriptionAnnouncement() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(L("Dismiss"))
            }.padding(.horizontal, 14).padding(.vertical, 8).nativeMeetingChrome()
                .accessibilityElement(children: .contain).accessibilityIdentifier("transcription.announcement")
        }
    }
}

/// While sound is off, says live text is being kept; when sound returns, offers
/// what was said in the meantime.
struct NativeDesktopCatchUpCard: View {
    @ObservedObject var model: NativeDesktopMeetingModel
    static func title(_ interval: MissedInterval) -> String {
        let sound = interval.reasons == [.audioInterruption]
        if interval.isOngoing { return sound ? L("Your sound is off") : L("Audio interruption in progress") }
        if sound { return L("While your sound was off") }
        if interval.reasons == [.connection] { return L("While reconnecting") }
        return L("While meeting audio was unavailable")
    }
    var body: some View {
        if let id = model.catchUpOffer, let interval = model.catchUpInterval(id) {
            let lines = model.catchUpLines(id)
            HStack(spacing: 10) {
                Image(systemName: "text.bubble.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(Self.title(interval)).bold()
                        Text(interval.start, style: .time).foregroundStyle(.secondary)
                        if let end = interval.end { Text("–").foregroundStyle(.secondary); Text(end, style: .time).foregroundStyle(.secondary) }
                    }
                    Text(lines.isEmpty ? L("Nothing was transcribed while your sound was off.") : L("%ld lines of live text", lines.count))
                        .foregroundStyle(.secondary)
                }.lineLimit(1)
                if !lines.isEmpty { Button(L("Read what you missed")) { model.showCatchUp(id) }.controlSize(.small) }
                Button { model.dismissCatchUpOffer() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(L("Dismiss"))
            }.font(.callout).padding(.horizontal, 14).padding(.vertical, 8).nativeMeetingChrome()
                .accessibilityElement(children: .contain).accessibilityIdentifier("catchup.offer")
        } else if model.soundOffSavingText {
            Label(L("Sound is off · live text is saved for catch-up"), systemImage: "speaker.slash.fill")
                .font(.callout).padding(.horizontal, 14).padding(.vertical, 7).nativeMeetingChrome()
                .accessibilityIdentifier("catchup.saving")
        }
    }
}

/// A narrow main window shows the announcement as a strip that moves the stage down.
struct NativeDesktopTranscriptionStrip: View {
    @ObservedObject var model: NativeDesktopMeetingModel
    var body: some View {
        if model.transcriptionAnnouncement, model.transcriptionIndicator == .on {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble.fill").foregroundStyle(.orange)
                (Text(L("Transcription started.")).bold().foregroundColor(.orange) + Text(" ") +
                 Text(L("What people say, including you, is turned into text.")))
                    .foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Button(L("Show live text")) { model.showLiveText() }.buttonStyle(.bordered).controlSize(.small)
                Button { model.dismissTranscriptionAnnouncement() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(L("Dismiss"))
            }.font(.callout).padding(.horizontal, 14).frame(height: 40)
                .background(Color.orange.opacity(0.16)).overlay(alignment: .bottom) { Color.orange.opacity(0.35).frame(height: 1) }
                .accessibilityElement(children: .contain).accessibilityIdentifier("transcription.announcement")
        }
    }
}

/// Where a zoomed view sits in the whole picture. Pan moves the image, so the
/// visible region moves the other way.
private struct NativeDesktopZoomIndicator: View {
    let zoom: CGFloat
    let pan: CGSize
    let aspect: CGSize
    var body: some View {
        let width: CGFloat = 120, height = width * max(0.4, min(1.2, aspect.height / max(1, aspect.width)))
        let visible = 1 / max(1, zoom)
        let centerX = 0.5 - pan.width * (1 - visible) / 2, centerY = 0.5 - pan.height * (1 - visible) / 2
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.12))
            RoundedRectangle(cornerRadius: 3).stroke(Color.orange, lineWidth: 2)
                .frame(width: width * visible, height: height * visible)
                .offset(x: width * (centerX - visible / 2), y: height * (centerY - visible / 2))
        }.frame(width: width, height: height).padding(6).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

/// Speaking now first with live levels, then everyone else with when they last spoke.
struct NativeDesktopParticipantsList: View {
    @ObservedObject var model: NativeDesktopMeetingModel
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .short; return formatter
    }()
    var body: some View {
        let speaking = model.participants.filter { $0.speaking == true }
        let others = model.participants.filter { $0.speaking != true }
        List {
            if !speaking.isEmpty { Section(L("Speaking now")) { ForEach(speaking) { row($0) } } }
            Section(L("In meeting")) { ForEach(others) { row($0) } }
        }.listStyle(.plain)
    }
    private func status(_ person: NativeDesktopParticipant) -> String {
        if person.speaking == true { return L("Speaking") }
        var parts: [String] = []
        if person.sharing == true { parts.append(L("Presenting")) }
        if let last = model.lastSpokeAt[person.id] { parts.append(L("Spoke %@", Self.relative.localizedString(for: last, relativeTo: Date()))) }
        else if person.microphoneOn == false { parts.append(L("Muted")) }
        return parts.joined(separator: " · ")
    }
    private func row(_ person: NativeDesktopParticipant) -> some View {
        let speaking = person.speaking == true
        return HStack(spacing: 10) {
            Text(person.name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map(String.init).joined().uppercased())
                .font(.caption.bold()).frame(width: 30, height: 30).background(.quaternary, in: Circle())
                .overlay(Circle().stroke(speaking ? Color.green : .clear, lineWidth: 2))
            VStack(alignment: .leading, spacing: 1) {
                Text(person.isLocal ? L("%@ (you)", person.name) : person.name).lineLimit(1)
                let line = status(person)
                if !line.isEmpty { Text(line).font(.caption).foregroundStyle(speaking ? Color.green : person.sharing == true ? Color.cyan : .secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            if speaking { NativeDesktopLevelMeter(level: person.isLocal ? model.snapshot.microphoneLevel ?? 0.5 : 0.7) }
            else if person.microphoneOn == false { Image(systemName: "mic.slash").foregroundStyle(.secondary).accessibilityLabel(L("Microphone off")) }
            if !person.isLocal && model.supportsParticipantVolume { NativeDesktopParticipantVolumeButton(model: model, person: person) }
        }.padding(.vertical, 2).accessibilityElement(children: .combine)
    }
}
