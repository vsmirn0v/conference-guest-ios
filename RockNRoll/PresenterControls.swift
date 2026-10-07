import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import ImagePlayground

struct PresenterControls: View {
    @ObservedObject var model: PresenterModel
    @ObservedObject var recording: MeetingRecording
    @ObservedObject var images: PresenterImageImport
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
                    Button(L("Choose slide or background")) { images.chooseImage() }
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
            Button { images.showFile = true } label: {
                Label(L("Open image file"), systemImage: "doc").frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.borderless)
                .accessibilityIdentifier("presenter.import-file")
            if #available(iOS 18.1, *) { AppleBackgroundControl(model: model) }
            if model.scene.image != nil {
                Picker(L("Image framing"), selection: $model.scene.imageFraming) {
                    Text(L("Fit entire image")).tag(PresenterScene.ImageFraming.fit)
                    Text(L("Fill canvas")).tag(PresenterScene.ImageFraming.fill)
                }.accessibilityIdentifier("presenter.image-framing")
                Button(L("Remove image")) { model.scene.image = nil; images.photo = nil }
            }
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
        .onDisappear { model.scene.draftStroke = [] }
    }
}

/// Pickers belong to the inspector root, not a lazily mounted Form row.
/// Returning from the system picker cannot destroy its own import operation.
@MainActor
final class PresenterImageImport: ObservableObject {
    @Published var showFile = false
    @Published var showPhoto = false
    @Published var photo: PhotosPickerItem?
    private let model: PresenterModel
    private var operation: Task<Void, Never>?
    init(model: PresenterModel) { self.model = model }
    func chooseImage() {
        if ProcessInfo.processInfo.isiOSAppOnMac { showFile = true } else { showPhoto = true }
    }
    func loadPhoto(_ item: PhotosPickerItem?) {
        operation?.cancel()
        guard let item else { return }
        operation = Task { [model] in
            do {
                if let data = try await item.loadTransferable(type: Data.self), !Task.isCancelled { await model.loadImage(data) }
            } catch { if !Task.isCancelled { model.reportImportError(error.localizedDescription) } }
        }
    }
    func loadFile(_ result: Result<URL, Error>) {
        operation?.cancel()
        operation = Task { [model] in
            do {
                let url = try result.get()
                let data = try await Task.detached(priority: .userInitiated) {
                    let allowed = url.startAccessingSecurityScopedResource()
                    defer { if allowed { url.stopAccessingSecurityScopedResource() } }
                    return try Data(contentsOf: url, options: .mappedIfSafe)
                }.value
                guard !Task.isCancelled else { return }
                await model.loadImage(data)
            } catch is CancellationError {
            } catch let error as CocoaError where error.code == .userCancelled {
            } catch { if !Task.isCancelled { model.reportImportError(error.localizedDescription) } }
        }
    }
    func cancel() { operation?.cancel(); operation = nil }
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
                    await model.loadImage(data, framing: .fill)
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
    var compact = false
    private var title: String {
        model.running ? L("Stop sharing") : model.source == .screen && !model.screenSelected ? L("Choose screen") : L("Start sharing")
    }
    var body: some View {
        Button {
            if model.running { model.stop() } else if model.source == .screen && !model.screenSelected { model.selectScreen() } else { Task { await model.start() } }
        } label: {
            HStack {
                if model.starting || model.stopping { ProgressView() }
                Label(compact ? (model.running ? L("Stop") : L("Share")) : title,
                      systemImage: model.running ? "stop.circle" : "rectangle.on.rectangle")
            }.frame(maxWidth: .infinity, minHeight: 36)
        }.buttonStyle(.borderedProminent)
            .tint(model.running ? .red : .orange)
            .disabled(!model.available || (!model.running && ((!model.hasPreview && model.source != .screen) || model.screenPicking)) || model.starting || model.stopping)
            .accessibilityLabel(title)
            .accessibilityIdentifier(model.running ? "presenter.stop" : "presenter.start")
    }
}
