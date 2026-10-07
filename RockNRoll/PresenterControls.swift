import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import ImagePlayground

struct PresenterControls: View {
    @ObservedObject var model: PresenterModel
    @ObservedObject var recording: MeetingRecording
    @State private var photo: PhotosPickerItem?
    @State private var importTask: Task<Void, Never>?
    @State private var showFile = false
    @State private var showPhoto = false
    @State private var showSource = false
    var body: some View {
        Section(L("Share source")) {
            Button { showSource = true } label: {
                Label(model.source == .screen ? L("Screen or window") : model.scene.image != nil ? L("Image") : L("Blank canvas"),
                      systemImage: model.source == .screen ? "rectangle.on.rectangle" : model.scene.image != nil ? "photo" : "rectangle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.borderless).accessibilityIdentifier("presenter.source")
                .confirmationDialog(L("Share source"), isPresented: $showSource, titleVisibility: .visible) {
                    Button(ProcessInfo.processInfo.isiOSAppOnMac ? L("Screen or window") : L("Screen / other apps")) { model.selectScreen() }
                        .disabled(model.screenPicking)
                    Button(L("Choose slide or background")) { showPhoto = true }
                    Button(L("Blank canvas")) { model.selectCanvas(clearImage: true) }
                }
            if model.source == .screen && !ProcessInfo.processInfo.isiOSAppOnMac {
                Text(L("Camera overlay and drawings aren’t available while sharing other apps. Choose an image or canvas to use Presenter."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        Section {
            Toggle(L("Include my camera"), isOn: $model.includeCamera)
                .disabled(!model.canCompose || model.nativeOverlay).accessibilityIdentifier("presenter.camera")
            if model.nativeOverlay {
                Label(L("macOS Presenter Overlay is active"), systemImage: "person.crop.rectangle")
                Text(L("Move or resize the camera using macOS controls. The app does not add a second camera layer."))
                    .font(.footnote).foregroundStyle(.secondary)
            } else if model.includeCamera {
                Label(model.hasCameraFrames ? L("Camera capture active") : L("Waiting for your camera…"),
                      systemImage: model.hasCameraFrames ? "camera.fill" : "hourglass")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier(model.hasCameraFrames ? "presenter.camera-ready" : "presenter.camera-waiting")
                if model.canFlipCamera {
                    Button { model.flipCamera() } label: { Label(L("Flip camera"), systemImage: "camera.rotate") }
                }
                Button { model.showCameraEffects() } label: { Label(L("Camera effects"), systemImage: "camera.filters") }
                    .disabled(!model.cameraOn && model.cameraDevice == nil)
            }
            if model.cameraOn && !model.running {
                Text(L("This canvas is private. Your separate camera video is already live in the meeting."))
                    .font(.footnote).foregroundStyle(.orange)
            }
            if model.screenSelected {
                Text(L("The screen continues in the background. The app camera layer and drawings return when you reopen the app; macOS manages its own overlay."))
                    .font(.footnote).foregroundStyle(.secondary)
            } else if model.source == .canvas {
                Text(L("Only this composed canvas is shared. Sharing it stops in the background. Your camera becomes part of the canvas when sharing starts."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        Section(L("Background")) {
            Button { showFile = true } label: { Label(L("Open image file"), systemImage: "doc") }
                .fileImporter(isPresented: $showFile, allowedContentTypes: [.image]) { result in
                    switch result {
                    case .success(let url): importFile(url)
                    case .failure(let error): model.reportImportError(error.localizedDescription)
                    }
                }
            if #available(iOS 18.1, *) { AppleBackgroundControl(model: model) }
            if model.scene.image != nil { Button(L("Remove image")) { model.scene.image = nil; photo = nil } }
            if model.source == .canvas {
                Picker(L("Scene"), selection: $model.scene.backdrop) {
                    Text(L("Dark")).tag(PresenterScene.Backdrop.dark)
                    Text(L("Warm")).tag(PresenterScene.Backdrop.warm)
                    Text(L("Stage glow")).tag(PresenterScene.Backdrop.stage)
                }.accessibilityIdentifier("presenter.scene")
            }
            if let error = model.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("presenter.error") }
        }
        RecordingControls(model: recording)
        .photosPicker(isPresented: $showPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { item in
            importTask?.cancel()
            importTask = Task {
                do { if let data = try await item?.loadTransferable(type: Data.self), !Task.isCancelled { await model.loadImage(data) } }
                catch { if !Task.isCancelled { model.reportImportError(error.localizedDescription) } }
            }
        }
        .onDisappear { importTask?.cancel(); model.scene.draftStroke = [] }
    }
    private func importFile(_ url: URL) {
        importTask?.cancel()
        importTask = Task {
            do { await model.loadImage(try await Task.detached(priority: .userInitiated) {
                let allowed = url.startAccessingSecurityScopedResource()
                defer { if allowed { url.stopAccessingSecurityScopedResource() } }
                return try Data(contentsOf: url, options: .mappedIfSafe)
            }.value) } catch { if !Task.isCancelled { model.reportImportError(error.localizedDescription) } }
        }
    }
}

struct PresenterCanvasEditor: View {
    @ObservedObject var model: PresenterModel
    @Binding var expanded: Bool
    @State private var dragOrigin: PresenterPlacement?
    @State private var pinchOrigin: PresenterPlacement?
    var body: some View {
        VStack(spacing: 8) {
            Label(model.running ? L("Shared with jam") : L("Preview · Only you"), systemImage: model.running ? "rectangle.on.rectangle" : "lock.fill")
                .font(.caption)
            if model.source == .screen && !model.screenSelected {
                Button { model.selectScreen() } label: {
                    Label(L("Choose screen"), systemImage: "rectangle.on.rectangle")
                        .frame(maxWidth: .infinity, minHeight: expanded ? 180 : 100)
                }.accessibilityIdentifier("presenter.choose-screen")
            } else {
                GeometryReader { geometry in
                    let width = min(geometry.size.width, geometry.size.height * model.aspectRatio)
                    preview.frame(width: width, height: width / model.aspectRatio)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(minHeight: expanded ? 0 : 130)
            }
            tools
        }.padding(expanded ? 8 : 0)
    }
    private var tools: some View {
        VStack(spacing: 0) {
        HStack(spacing: 4) {
            Picker(L("Canvas tool"), selection: $model.tool) {
                Text(L("Move camera")).tag(PresenterModel.Tool.move)
                if model.scene.layout == .instrument { Text(L("Crop")).tag(PresenterModel.Tool.crop) }
                Text(L("Draw")).tag(PresenterModel.Tool.draw)
            }.pickerStyle(.segmented).disabled(!model.canCompose)
                .accessibilityIdentifier(expanded ? "presenter.expanded-tools" : "presenter.tools")
            if model.includeCamera && !model.nativeOverlay {
                Menu {
                    Picker(L("Camera layout"), selection: $model.scene.layout) {
                        Text(L("Camera card")).tag(PresenterScene.Layout.card)
                        Text(L("Person cutout")).tag(PresenterScene.Layout.cutout)
                        Text(L("Instrument close-up")).tag(PresenterScene.Layout.instrument)
                        Text(L("Side by side")).tag(PresenterScene.Layout.beside)
                    }
                    Button(L("Increase camera size")) { model.scene.placement.resize(1.1); model.savePlacement() }
                    Button(L("Decrease camera size")) { model.scene.placement.resize(0.9); model.savePlacement() }
                    Button(L("Top left")) { place(right: false, bottom: false) }
                    Button(L("Top right")) { place(right: true, bottom: false) }
                    Button(L("Bottom left")) { place(right: false, bottom: true) }
                    Button(L("Bottom right")) { place(right: true, bottom: true) }
                    Button(L("Rotate camera")) { model.scene.cameraRotation = (model.scene.cameraRotation + 90) % 360 }
                    Button(L("Automatic camera orientation")) { model.scene.cameraRotation = 0 }
                } label: { Image(systemName: "person.crop.rectangle").frame(width: 44, height: 44) }
                    .accessibilityLabel(L("Camera layout")).accessibilityIdentifier("presenter.layout")
            }
            Button { expanded.toggle() } label: {
                Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .frame(width: 44, height: 44)
            }.accessibilityLabel(expanded ? L("Fit canvas") : L("Expand canvas")).accessibilityIdentifier("presenter.expand")
        }
        if model.tool == .draw || !model.scene.strokes.isEmpty || model.canRedoDrawing {
            HStack {
                Button { model.undoDrawing() } label: { Label(L("Undo"), systemImage: "arrow.uturn.backward") }
                    .disabled(!model.canUndoDrawing).accessibilityIdentifier("presenter.undo")
                Spacer(minLength: 0)
                Button { model.redoDrawing() } label: { Label(L("Redo"), systemImage: "arrow.uturn.forward") }
                    .disabled(!model.canRedoDrawing).accessibilityIdentifier("presenter.redo")
                Spacer(minLength: 0)
                Button { model.clearDrawings() } label: { Label(L("Clear"), systemImage: "trash") }
                    .disabled(model.scene.strokes.isEmpty).accessibilityIdentifier("presenter.clear")
            }.font(.subheadline).frame(minHeight: 44)
        }
        }
    }
    private var preview: some View {
        ZStack {
            StudioPreviewSurface(view: model.preview, onAttach: { [weak model] in model?.restorePreview() })
            GeometryReader { geometry in
                if model.tool == .draw || model.tool == .crop {
                    Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let point = CGPoint(x: min(1, max(0, value.location.x / max(1, geometry.size.width))),
                                                y: min(1, max(0, value.location.y / max(1, geometry.size.height))))
                            if model.tool == .draw {
                                if model.scene.draftStroke.count < 512 { model.scene.draftStroke.append(point) }
                            } else { model.scene.focus = point }
                        }
                        .onEnded { _ in
                            if model.tool == .draw {
                                let draft = model.scene.draftStroke; model.scene.draftStroke = []; model.appendAnnotation(draft)
                            }
                        })
                } else if model.includeCamera && !model.nativeOverlay && model.scene.layout != .beside {
                    let place = model.scene.placement
                    RoundedRectangle(cornerRadius: 8).strokeBorder(.orange, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(.clear).contentShape(Rectangle())
                        .frame(width: place.width * geometry.size.width, height: place.height * geometry.size.height)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption).padding(8)
                                .background(.orange, in: Circle()).foregroundStyle(.black)
                                .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                                    if dragOrigin == nil { dragOrigin = place }
                                    if var origin = dragOrigin {
                                        let factor = max(0.2, 1 + value.translation.width / max(1, origin.width * geometry.size.width))
                                        origin.width *= factor; origin.height *= factor; origin.clamp()
                                        model.scene.placement = origin
                                    }
                                }.onEnded { _ in dragOrigin = nil; model.savePlacement() })
                        }
                        .position(x: (place.x + place.width / 2) * geometry.size.width,
                                  y: (place.y + place.height / 2) * geometry.size.height)
                        .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                            if dragOrigin == nil { dragOrigin = place }
                            if var origin = dragOrigin {
                                origin.x += value.translation.width / max(1, geometry.size.width)
                                origin.y += value.translation.height / max(1, geometry.size.height)
                                origin.clamp(); model.scene.placement = origin
                            }
                        }.onEnded { _ in dragOrigin = nil; model.savePlacement() })
                        .simultaneousGesture(MagnificationGesture().onChanged { value in
                            if pinchOrigin == nil { pinchOrigin = place }
                            if var origin = pinchOrigin { origin.resize(value); model.scene.placement = origin }
                        }.onEnded { _ in pinchOrigin = nil; model.savePlacement() })
                        .accessibilityLabel(L("Move camera"))
                        .accessibilityHint(L("Drag to move. Pinch or drag the corner to resize."))
                        .accessibilityAdjustableAction { direction in
                            model.scene.placement.resize(direction == .increment ? 1.1 : 0.9); model.savePlacement()
                        }.accessibilityIdentifier("presenter.camera-layer")
                }
            }
            if !model.hasPreview { ProgressView().tint(.white) }
        }.aspectRatio(model.aspectRatio, contentMode: .fit).background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier("presenter.preview")
    }
    private func place(right: Bool, bottom: Bool) {
        model.scene.placement.x = right ? 0.97 - model.scene.placement.width : 0.03
        model.scene.placement.y = bottom ? 0.96 - model.scene.placement.height : 0.04
        model.savePlacement()
    }
}

struct RecordingControls: View {
    @ObservedObject var model: MeetingRecording
    @State private var confirm = false
    var body: some View {
        Section(L("Recording")) {
            Button {
                if model.canStop { model.requestStop() } else { confirm = true }
            } label: {
                Label(model.isRecording ? L("Stop recording") : L("Record meeting"), systemImage: "record.circle")
            }.disabled(!model.canStart && !model.canStop)
                .accessibilityIdentifier("meeting.recording-action")
            if model.state == .starting || model.state == .stopping { ProgressView(L("Waiting for meeting service…")) }
            if model.state == .unavailable { Text(L("Recording is unavailable in this meeting.")) }
            Text(L("Recordings are stored by the meeting service. The organizer manages access and downloads on the meeting website."))
                .font(.footnote).foregroundStyle(.secondary)
            if let error = model.error { Text(error).foregroundStyle(.red) }
        }.confirmationDialog(L("Record this meeting?"), isPresented: $confirm, titleVisibility: .visible) {
            Button(L("Start recording")) { model.requestStart() }
        } message: { Text(L("The meeting service will record participants and shared content. Make sure everyone knows before starting.")) }
    }
}

@available(iOS 18.1, *)
private struct AppleBackgroundControl: View {
    @ObservedObject var model: PresenterModel
    @Environment(\.supportsImagePlayground) private var supported
    var body: some View {
        if supported && ImagePlaygroundViewController.isAvailable {
            AppleBackgroundButton(model: model).frame(height: 44)
        } else {
            Label(L("Apple image generation is unavailable on this device."), systemImage: "sparkles")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

@available(iOS 18.1, *)
private struct AppleBackgroundButton: UIViewRepresentable {
    let model: PresenterModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.title = L("Create background with Apple"); config.image = UIImage(systemName: "sparkles"); config.imagePadding = 8
        config.contentInsets = .zero; button.configuration = config; button.contentHorizontalAlignment = .leading
        button.addAction(UIAction { [weak button, weak coordinator = context.coordinator] _ in
            guard let button else { return }; coordinator?.present(from: button)
        }, for: .touchUpInside)
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) {}
    @MainActor
    final class Coordinator: NSObject, ImagePlaygroundViewController.Delegate {
        private let model: PresenterModel
        init(model: PresenterModel) { self.model = model }
        func present(from view: UIView) {
            guard ImagePlaygroundViewController.isAvailable else { model.reportImportError(L("Apple image generation is unavailable on this device.")); return }
            var responder: UIResponder? = view
            while let current = responder, !(current is UIViewController) { responder = current.next }
            guard let presenter = responder as? UIViewController, presenter.presentedViewController == nil else { return }
            let controller = ImagePlaygroundViewController()
            controller.delegate = self
            controller.modalPresentationStyle = .fullScreen
            presenter.present(controller, animated: true)
        }
        func imagePlaygroundViewController(_ controller: ImagePlaygroundViewController, didCreateImageAt url: URL) {
            Task { @MainActor [model] in
                do {
                    let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url, options: .mappedIfSafe) }.value
                    await model.loadImage(data)
                } catch { model.reportImportError(error.localizedDescription) }
                controller.dismiss(animated: true) { model.restorePreview() }
            }
        }
        func imagePlaygroundViewControllerDidCancel(_ controller: ImagePlaygroundViewController) {
            controller.dismiss(animated: true) { [model] in model.restorePreview() }
        }
    }
}

struct PresenterShareControl: View {
    @ObservedObject var model: PresenterModel
    var body: some View {
        Button {
            if model.running { model.stop() } else if model.source == .screen && !model.screenSelected { model.selectScreen() } else { Task { await model.start() } }
        } label: {
            HStack {
                if model.starting || model.stopping { ProgressView() }
                Label(model.running ? L("Stop sharing") : model.source == .screen && !model.screenSelected ? L("Choose screen") : L("Start sharing"),
                      systemImage: model.running ? "stop.circle" : "rectangle.on.rectangle")
            }.frame(maxWidth: .infinity, minHeight: 36)
        }.buttonStyle(.borderedProminent)
            .tint(model.running ? .red : .orange)
            .disabled(!model.available || (!model.running && ((!model.hasPreview && model.source != .screen) || model.screenPicking)) || model.starting || model.stopping)
            .accessibilityIdentifier(model.running ? "presenter.stop" : "presenter.start")
    }
}
