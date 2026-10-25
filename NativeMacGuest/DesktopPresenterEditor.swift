import AppKit
import ConferenceCore
import SwiftUI
import UniformTypeIdentifiers

/// The inspector and expanded editor share one private session and one renderer
/// source; expanding the editor never requests or publishes another capture.
struct NativeDesktopPresenterView: View {
    @ObservedObject var model: NativeDesktopMeetingModel
    var body: some View { NativeDesktopPresenterInspector(session: model.presenter) }
}

private struct NativeDesktopPresenterInspector: View {
    @ObservedObject var session: NativeDesktopPresenterSession
    @State private var expanded = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                NativeDesktopPresenterCanvas(session: session.workspace).aspectRatio(session.aspectRatio, contentMode: .fit)
                    .frame(minHeight: 140).clipShape(RoundedRectangle(cornerRadius: 10))
                NativeDesktopPresenterStatus(session: session)
                Button { expanded = true } label: { Label(L("Open canvas editor"), systemImage: "arrow.up.left.and.arrow.down.right") }
                    .frame(maxWidth: .infinity).accessibilityIdentifier("presenter.expand")
                NativeDesktopPresenterControls(session: session.workspace, owner: session)
                NativeDesktopPresenterPublication(session: session)
                if let error = session.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }.padding(18)
        }
        .task { await session.open() }
        .onDisappear { if !session.isSharing && !session.isPublishing { Task { _ = await session.close() } } }
        .sheet(isPresented: $expanded) { NativeDesktopPresenterEditor(session: session) }
    }
}

struct NativeDesktopPresenterEditor: View {
    @ObservedObject var session: NativeDesktopPresenterSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Share")).font(.title2.bold())
                NativeDesktopPresenterStatus(session: session)
                Spacer()
                Button(L("Done")) { dismiss() }.keyboardShortcut(.escape, modifiers: [])
            }.padding(18)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 12) {
                    NativeDesktopPresenterCanvas(session: session.workspace).frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack {
                        Picker(L("Canvas tool"), selection: Binding(get: { session.workspace.tool }, set: { session.workspace.tool = $0 })) {
                            Label(L("Move camera"), systemImage: "move.3d").tag(NativeDesktopPresenterSession.Tool.move)
                            Label(L("Draw"), systemImage: "pencil.tip").tag(NativeDesktopPresenterSession.Tool.draw)
                            Label(L("Crop"), systemImage: "crop").tag(NativeDesktopPresenterSession.Tool.crop)
                        }.pickerStyle(.segmented).frame(maxWidth: 340)
                        Spacer()
                        Button { session.workspace.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                            .help(L("Undo")).disabled(!session.workspace.canUndo).keyboardShortcut("z", modifiers: .command)
                        Button { session.workspace.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                            .help(L("Redo")).disabled(!session.workspace.canRedo).keyboardShortcut("z", modifiers: [.command, .shift])
                        Button { session.workspace.clearDrawings() } label: { Image(systemName: "trash") }
                            .help(L("Clear drawings")).disabled(session.workspace.scene.strokes.isEmpty)
                    }
                    Text(hint).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    if let error = session.error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
                }.padding(18).frame(maxWidth: .infinity)
                Divider()
                ScrollView { NativeDesktopPresenterControls(session: session.workspace, owner: session).padding(18) }.frame(width: 270)
            }
            Divider()
            HStack { NativeDesktopPresenterPublication(session: session) }.padding(18)
        }.frame(minWidth: 860, idealWidth: 1100, minHeight: 600, idealHeight: 760)
            .onDisappear { session.workspace.cancelEdit() }
    }
    private var hint: String {
        switch session.workspace.tool {
        case .move: return L("Drag the camera frame to move it. Drag its corner to resize.")
        case .draw: return L("Draw directly on the canvas. Undo removes the last stroke.")
        case .crop: return L("Choose Instrument, then drag inside the camera frame to adjust its crop.")
        }
    }
}

private struct NativeDesktopPresenterStatus: View {
    @ObservedObject var session: NativeDesktopPresenterSession
    var body: some View {
        Label(session.contentDraft != nil ? L("Change preview · Not yet shared") : session.isSharing ? L("Live · Visible to meeting") : L("Only you · Private preparation"),
              systemImage: session.isSharing && session.contentDraft == nil ? "dot.radiowaves.left.and.right" : "lock.fill")
            .font(.caption).foregroundStyle(session.isSharing ? Color.orange : Color.secondary)
            .accessibilityIdentifier("presenter.visibility")
    }
}

private struct NativeDesktopPresenterPublication: View {
    @ObservedObject var session: NativeDesktopPresenterSession
    var body: some View {
        HStack {
            if session.isPreparing || session.isPublishing || session.isClosing { ProgressView().controlSize(.small) }
            if session.contentDraft != nil {
                Button(L("Change shared content")) { Task { do { try await session.applyContentChange() } catch { session.reportError(error) } } }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.contentDraft?.canStartSharing != true || session.contentDraft?.cameraPreparing == true || session.applyingContent || session.isClosing)
                    .accessibilityIdentifier("share.apply-content")
                Button(L("Cancel content change")) { Task { await session.cancelContentChange() } }
                    .disabled(session.applyingContent).accessibilityIdentifier("share.cancel-content")
            } else if session.isSharing {
                Button(L("Stop sharing"), role: .destructive) { Task { do { try await session.stopSharing() } catch { session.reportError(error) } } }
                    .disabled(session.isPublishing || session.isClosing)
            } else {
                Button(L("Start sharing")) { Task { do { try await session.startSharing() } catch { session.reportError(error) } } }
                    .buttonStyle(.borderedProminent).disabled(!session.canStartSharing)
                    .accessibilityIdentifier("presenter.start-sharing")
            }
            if !session.isSharing && (session.isPreparing || session.isPublishing) {
                Button(L("Cancel")) { Task { _ = await session.close() } }
            }
        }
    }
}

private struct NativeDesktopPresenterControls: View {
    @ObservedObject var session: NativeDesktopPresenterSession
    @ObservedObject var owner: NativeDesktopPresenterSession
    @State private var advanced = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Content")).font(.headline)
            Menu {
                Button(L("Screen or window…")) { Task { await owner.chooseScreen() } }
                Button(L("Image or slides…")) { Task { await chooseImage() } }
                Button(L("Canvas or background")) { Task { await owner.chooseCanvas() } }
            } label: { Label(session.source == .canvas ? (session.scene.image == nil ? L("Canvas or background") : L("Image or slides")) : L("Screen or window"), systemImage: session.source == .canvas ? "photo" : "rectangle.on.rectangle") }
                .disabled(owner.isPublishing || session.isPreparing || owner.isClosing || owner.applyingContent)
                .accessibilityIdentifier("share.content")
            if owner.contentDraft != nil { Text(L("Your current share continues until you confirm this change.")).font(.caption).foregroundStyle(.secondary) }
            Text(session.source == .canvas ? L("Canvas") : L("Selected screen or window")).font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle(L("Include camera"), isOn: Binding(get: { session.includeCamera }, set: { enabled in Task { await session.setIncludeCamera(enabled) } }))
                .disabled(session.nativeOverlay || session.isClosing || (!session.includeCamera && (session.cameraPreparing || session.isPreparing || session.previewTrack == nil)))
                .accessibilityIdentifier("presenter.include-camera")
            if session.nativeOverlay {
                Label(L("macOS Presenter Overlay is active"), systemImage: "person.crop.rectangle")
                Text(L("Move or resize the camera using macOS controls. The app does not add a second camera layer.")).font(.caption).foregroundStyle(.secondary)
            }
            if session.cameraPreparing { ProgressView(L("Preparing private camera…")).controlSize(.small) }
            Text(owner.contentDraft != nil ? L("Camera and layout changes stay private until you confirm.") : owner.isSharing ? L("Camera and layout changes appear in your live share.") : L("Camera stays private until you start sharing. An already live meeting camera is reused.")).font(.caption).foregroundStyle(.secondary)
            if session.includeCamera && !session.nativeOverlay {
                Picker(L("Camera layout"), selection: Binding(get: { session.scene.layout }, set: { value in session.edit { $0.layout = value } })) {
                    Text(L("Person cutout")).tag(PresenterScene.Layout.cutout)
                    Text(L("Camera card")).tag(PresenterScene.Layout.card)
                    Text(L("Beside content")).tag(PresenterScene.Layout.beside)
                    Text(L("Instrument")).tag(PresenterScene.Layout.instrument)
                }
                Toggle(L("Mirror camera"), isOn: Binding(get: { session.cameraMirrored }, set: { session.cameraMirrored = $0 }))
                HStack {
                    Button(L("Rotate")) { session.edit { $0.cameraRotation = ($0.cameraRotation + 90) % 360 } }
                    Button(L("Reset orientation")) { session.edit { $0.cameraRotation = 0 } }
                }
                if session.scene.layout != .beside {
                    Text(L("Camera size")).font(.caption)
                    HStack {
                        Button { session.edit { $0.placement.resize(0.9) } } label: { Image(systemName: "minus.magnifyingglass") }.help(L("Decrease camera size"))
                        Button { session.edit { $0.placement.resize(1.1) } } label: { Image(systemName: "plus.magnifyingglass") }.help(L("Increase camera size"))
                        Menu(L("Position")) {
                            Button(L("Top left")) { place(right: false, bottom: false) }
                            Button(L("Top right")) { place(right: true, bottom: false) }
                            Button(L("Bottom left")) { place(right: false, bottom: true) }
                            Button(L("Bottom right")) { place(right: true, bottom: true) }
                        }
                    }
                }
                if session.scene.layout == .instrument {
                    Text(L("Crop zoom")).font(.caption)
                    Slider(value: Binding(get: { session.scene.zoom }, set: { session.scene.zoom = $0 }), in: 1...4,
                           onEditingChanged: { if $0 { session.beginEdit() } else { session.commitEdit() } })
                    Button(L("Reset crop")) { session.edit { $0.zoom = 1; $0.focus = CGPoint(x: 0.5, y: 0.5) } }
                }
            }
            Divider()
            Picker(L("Backdrop"), selection: $session.scene.backdrop) {
                Text(L("Dark")).tag(PresenterScene.Backdrop.dark); Text(L("Warm")).tag(PresenterScene.Backdrop.warm); Text(L("Stage")).tag(PresenterScene.Backdrop.stage)
            }
            Button(L("Choose image…")) { Task { await chooseImage() } }
                .disabled(session.isPreparing || session.isClosing || (session.isSharing && session.source == .screen))
            if session.scene.image != nil {
                Picker(L("Image framing"), selection: $session.scene.imageFraming) {
                    Text(L("Fit")).tag(PresenterScene.ImageFraming.fit); Text(L("Fill")).tag(PresenterScene.ImageFraming.fill)
                }.pickerStyle(.segmented)
                Button(L("Remove image")) { session.scene.image = nil }
            }
            DisclosureGroup(isExpanded: $advanced) {
                Picker(L("Encoding"), selection: $owner.encodingPreference) {
                    Text(L("Efficient · Default")).tag(ShareEncodingPreference.efficient)
                    Text(L("Text detail · VP9")).tag(ShareEncodingPreference.textDetail)
                        .disabled(!owner.supportsVP9)
                }
                Text(owner.encodingPreference == .textDetail ? L("May make small text slightly clearer. Uses more CPU and battery.") : L("Uses hardware H.264 when available to save energy."))
                    .font(.caption).foregroundStyle(.secondary)
                if !owner.supportsVP9, let reason = owner.vp9UnavailableReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                if owner.isSharing { Text(L("Encoding changes apply after Stop → Start sharing.")).font(.caption).foregroundStyle(.secondary) }
                if let report = owner.encodingReport { Text(report.summary).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("share.encoding-report") }
            } label: {
                HStack { Text(L("Advanced")); Spacer(); Text(owner.encodingPreference == .efficient ? L("Efficient encoding") : L("VP9 encoding")).foregroundStyle(.secondary).font(.caption) }
            }.accessibilityIdentifier("share.advanced")
            Text(L("Layout, placement and camera mirroring are remembered. Screen access and camera inclusion are requested for each session.")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func place(right: Bool, bottom: Bool) {
        session.edit { $0.placement.x = right ? 0.97 - $0.placement.width : 0.03; $0.placement.y = bottom ? 0.96 - $0.placement.height : 0.04 }
    }
    @MainActor private func chooseImage() async {
        let revision = owner.imageImportRevision
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                guard let size = values.fileSize, size <= 25_000_000 else { throw NativeDesktopPresenterError.invalidImage }
                return try Data(contentsOf: url, options: .mappedIfSafe)
            }.value
            await owner.chooseImage(data, expectedRevision: revision)
        } catch { session.reportError(error) }
    }
}

/// Hit testing uses the same top-left normalized canvas as the compositor,
/// excluding letterboxing. Local editor chrome never enters the video source.
private struct NativeDesktopPresenterCanvas: View {
    @ObservedObject var session: NativeDesktopPresenterSession
    @State private var startingPlacement: PresenterPlacement?
    @State private var startingFocus: CGPoint?
    @State private var points: [CGPoint] = []
    @State private var dragging = false
    var body: some View {
        GeometryReader { geometry in
            let size = Self.fittedSize(geometry.size, aspect: session.aspectRatio)
            ZStack {
                Color.black
                if let track = session.previewTrack { NativeDesktopVideoView(track: track) }
                else { Text(session.isPreparing ? L("Preparing private preview…") : L("Choose content to prepare")).foregroundStyle(.white.opacity(0.7)) }
                Color.clear.contentShape(Rectangle()).gesture(canvasGesture(size))
                if session.includeCamera && !session.nativeOverlay && session.scene.layout != .beside && session.tool != .draw {
                    let placement = session.scene.placement
                    Rectangle().strokeBorder(.orange.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                        .frame(width: placement.width * size.width, height: placement.height * size.height)
                        .position(x: (placement.x + placement.width / 2) * size.width, y: (placement.y + placement.height / 2) * size.height)
                        .allowsHitTesting(false)
                    Circle().fill(.orange).frame(width: 14, height: 14)
                        .position(x: (placement.x + placement.width) * size.width, y: (placement.y + placement.height) * size.height)
                        .highPriorityGesture(resizeGesture(size)).accessibilityLabel(L("Resize camera"))
                }
            }.frame(width: size.width, height: size.height).clipped()
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }.background(.black).accessibilityIdentifier("presenter.canvas")
    }
    static func fittedSize(_ available: CGSize, aspect: CGFloat) -> CGSize {
        guard available.width > 0, available.height > 0, aspect.isFinite, aspect > 0 else { return .zero }
        let width = min(available.width, available.height * aspect); return CGSize(width: width, height: width / aspect)
    }
    private func canvasGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1).onChanged { value in
            guard size.width > 0, size.height > 0 else { return }
            let point = NativeDesktopPresenterSession.normalized(CGPoint(x: value.location.x / size.width, y: value.location.y / size.height))
            if !dragging {
                let start = CGPoint(x: value.startLocation.x / size.width, y: value.startLocation.y / size.height)
                guard session.tool == .draw || (session.includeCamera && session.scene.layout != .beside && session.scene.placement.rect.contains(start)) else { return }
                dragging = true; startingPlacement = session.scene.placement; startingFocus = session.scene.focus; points = []
                session.beginEdit()
            }
            switch session.tool {
            case .draw:
                if points.count < 512 { points.append(point) }; session.scene.draftStroke = points
            case .move:
                if var placement = startingPlacement {
                    placement.x += value.translation.width / size.width; placement.y += value.translation.height / size.height
                    placement.clamp(); session.scene.placement = placement
                }
            case .crop:
                guard session.scene.layout == .instrument, let focus = startingFocus else { return }
                let sign: CGFloat = session.scene.cameraMirrored ? -1 : 1
                session.scene.focus = NativeDesktopPresenterSession.normalized(CGPoint(
                    x: focus.x - sign * value.translation.width / (size.width * session.scene.placement.width * session.scene.zoom),
                    y: focus.y - value.translation.height / (size.height * session.scene.placement.height * session.scene.zoom)))
            }
        }.onEnded { _ in
            guard dragging else { return }; dragging = false
            if session.tool == .draw { session.appendStroke(points) } else { session.commitEdit() }
            startingPlacement = nil; startingFocus = nil; points = []
        }
    }
    private func resizeGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1).onChanged { value in
            if startingPlacement == nil { startingPlacement = session.scene.placement; session.beginEdit() }
            guard var placement = startingPlacement else { return }
            placement.width += value.translation.width / max(1, size.width)
            placement.height += value.translation.height / max(1, size.height)
            placement.clamp(); session.scene.placement = placement
        }.onEnded { _ in startingPlacement = nil; session.commitEdit() }
    }
}
