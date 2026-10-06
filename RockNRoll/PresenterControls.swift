import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import ImagePlayground

struct PresenterControls: View {
    @ObservedObject var model: PresenterModel
    @State private var photo: PhotosPickerItem?
    @State private var drawing = false
    @State private var stroke: [CGPoint] = []
    @State private var importTask: Task<Void, Never>?
    @State private var showFile = false
    var body: some View {
        Section {
            ZStack {
                StudioPreviewSurface(view: model.preview)
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let point = CGPoint(x: min(1, max(0, value.location.x / max(1, geometry.size.width))),
                                                y: min(1, max(0, value.location.y / max(1, geometry.size.height))))
                            if drawing { if stroke.count < 512 { stroke.append(point) } }
                            else if model.scene.layout == .instrument { model.scene.focus = point }
                        }
                        .onEnded { _ in if drawing { model.appendAnnotation(stroke); stroke = [] } },
                        including: drawing || model.scene.layout == .instrument ? .all : .none)
                    Path { path in
                        if let first = stroke.first {
                            path.move(to: CGPoint(x: first.x * geometry.size.width, y: first.y * geometry.size.height))
                            for point in stroke.dropFirst() { path.addLine(to: CGPoint(x: point.x * geometry.size.width, y: point.y * geometry.size.height)) }
                        }
                    }.stroke(.orange, lineWidth: 3).allowsHitTesting(false)
                }
                if !model.hasPreview { ProgressView().tint(.white) }
            }
            .aspectRatio(16 / 9, contentMode: .fit).background(.black).clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("presenter.preview")
            Label(model.running ? L("Shared with jam") : L("Preview · Only you"), systemImage: model.running ? "rectangle.on.rectangle" : "lock.fill")
                .font(.footnote)
            Toggle(L("Include my camera"), isOn: $model.includeCamera).accessibilityIdentifier("presenter.camera")
            if model.includeCamera {
                Label(model.hasCameraFrames ? L("Camera capture active") : L("Waiting for your camera…"),
                      systemImage: model.hasCameraFrames ? "camera.fill" : "hourglass")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier(model.hasCameraFrames ? "presenter.camera-ready" : "presenter.camera-waiting")
                if model.canFlipCamera {
                    Button { model.flipCamera() } label: { Label(L("Flip camera"), systemImage: "camera.rotate") }
                        .accessibilityIdentifier("presenter.flip-camera")
                }
                if ProcessInfo.processInfo.isiOSAppOnMac {
                    // External/Continuity cameras cannot always report their
                    // physical mounting angle to UIKit's rotation coordinator.
                    Button { model.scene.cameraRotation = (model.scene.cameraRotation + 90) % 360 }
                        label: { Label(L("Rotate camera"), systemImage: "rotate.right") }
                        .accessibilityIdentifier("presenter.rotate-camera")
                }
                Button { model.showCameraEffects() } label: { Label(L("Camera effects"), systemImage: "camera.filters") }
                    .disabled(!model.cameraOn && model.cameraDevice == nil)
            }
            Picker(L("Camera layout"), selection: $model.scene.layout) {
                Text(L("Camera card")).tag(PresenterScene.Layout.card)
                Text(L("Person cutout")).tag(PresenterScene.Layout.cutout)
                Text(L("Instrument close-up")).tag(PresenterScene.Layout.instrument)
            }.accessibilityIdentifier("presenter.layout")
            if !model.includeCamera {
                Text(L("Your camera is not included in this canvas.")).font(.footnote).foregroundStyle(.secondary)
            } else if model.scene.layout == .cutout {
                Text(L("Cutout hides the camera background in this canvas. If detection fails, the camera card is omitted. Use Camera card to keep instruments visible."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text(L("Camera preview is private until you share. When sharing starts, this camera appears inside the canvas instead of a separate video tile."))
                .font(.footnote).foregroundStyle(.secondary)
            if model.scene.layout == .instrument {
                Slider(value: $model.scene.zoom, in: 1...4, step: 0.1) { Text(L("Camera magnification")) }
                    .accessibilityIdentifier("presenter.zoom")
                Text(L("Drag on the preview to position the camera close-up.")).font(.footnote).foregroundStyle(.secondary)
            }
        }
        Section(L("Canvas")) {
            PhotosPicker(selection: $photo, matching: .images) { Label(L("Choose slide or background"), systemImage: "photo") }
                .accessibilityIdentifier("presenter.image")
            Button { showFile = true } label: { Label(L("Open image file"), systemImage: "doc") }
                .fileImporter(isPresented: $showFile, allowedContentTypes: [.image]) { result in
                    guard case let .success(url) = result else { return }
                    let allowed = url.startAccessingSecurityScopedResource()
                    defer { if allowed { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url, options: .mappedIfSafe) { model.importImage(data) }
                }
            if #available(iOS 18.1, *) { PresenterImageGeneration(model: model) }
            if model.scene.image != nil {
                Button(L("Remove image")) { model.scene.image = nil; photo = nil }
            }
            Picker(L("Scene"), selection: $model.scene.backdrop) {
                Text(L("Dark")).tag(PresenterScene.Backdrop.dark)
                Text(L("Warm")).tag(PresenterScene.Backdrop.warm)
                Text(L("Stage glow")).tag(PresenterScene.Backdrop.stage)
            }.accessibilityIdentifier("presenter.scene")
            if model.scene.backdrop == .stage && model.scene.image == nil {
                Text(L("The glow follows your speaking indicator. It does not analyse or record audio."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Toggle(L("Draw on canvas"), isOn: $drawing).accessibilityIdentifier("presenter.draw")
            if !model.scene.strokes.isEmpty {
                HStack {
                    Button(L("Undo drawing")) { _ = model.scene.strokes.popLast() }
                    Spacer()
                    Button(L("Clear drawings")) { model.scene.strokes = [] }
                }
            }
        }
        Section {
            Text(L("Presenter shares this canvas, not your other apps. It stops when this app moves to the background. Use regular screen sharing to share other apps."))
                .font(.footnote).foregroundStyle(.secondary)
            if let error = model.error { Text(error).foregroundStyle(.red) }
        }
        .onChange(of: photo) { item in
            importTask?.cancel()
            importTask = Task {
                if let data = try? await item?.loadTransferable(type: Data.self), !Task.isCancelled { model.importImage(data) }
            }
        }
        .onDisappear { importTask?.cancel() }
    }
}

@available(iOS 18.1, *)
private struct PresenterImageGeneration: View {
    @ObservedObject var model: PresenterModel
    @Environment(\.supportsImagePlayground) private var supported
    @State private var show = false
    var body: some View {
        if supported {
            Button { show = true } label: { Label(L("Create background with Apple"), systemImage: "sparkles") }
                .imagePlaygroundSheet(isPresented: $show) { url in
                    if let data = try? Data(contentsOf: url, options: .mappedIfSafe) { model.importImage(data) }
                }
            Text(L("Uses Apple Image Playground. Availability and processing depend on system settings."))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct PresenterShareControl: View {
    @ObservedObject var model: PresenterModel
    var body: some View {
        Button {
            if model.running { model.stop() } else { Task { await model.start() } }
        } label: {
            HStack {
                if model.starting || model.stopping { ProgressView() }
                Label(model.running ? L("Stop Presenter") : L("Share canvas"),
                      systemImage: model.running ? "stop.circle" : "rectangle.on.rectangle")
            }.frame(maxWidth: .infinity, minHeight: 36)
        }.buttonStyle(.borderedProminent)
            .tint(model.running ? .red : .orange)
            .disabled(!model.available || !model.hasPreview || model.starting || model.stopping)
            .accessibilityIdentifier(model.running ? "presenter.stop" : "presenter.start")
    }
}
