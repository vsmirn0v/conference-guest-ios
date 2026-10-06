import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import ImagePlayground

struct PresenterControls: View {
    enum Tool: String { case move, crop, draw }
    @ObservedObject var model: PresenterModel
    @State private var photo: PhotosPickerItem?
    @State private var tool: Tool = .move
    @State private var dragOrigin: PresenterPlacement?
    @State private var pinchOrigin: PresenterPlacement?
    @State private var importTask: Task<Void, Never>?
    @State private var showFile = false
    @State private var showPhoto = false
    @State private var expanded = false
    var body: some View {
        Section(L("Share source")) {
            Menu {
                Button { model.selectScreen() } label: {
                    Label(ProcessInfo.processInfo.isiOSAppOnMac ? L("Screen or window") : L("Screen / other apps"), systemImage: "rectangle.on.rectangle")
                }.disabled(model.screenPicking)
                Button { showPhoto = true } label: { Label(L("Choose slide or background"), systemImage: "photo") }
                Button { model.selectCanvas(clearImage: true) } label: { Label(L("Blank canvas"), systemImage: "rectangle") }
            } label: {
                Label(model.screenSelected ? L("Screen or window") : model.scene.image != nil ? L("Image") : L("Blank canvas"),
                      systemImage: model.screenSelected ? "rectangle.on.rectangle" : model.scene.image != nil ? "photo" : "rectangle")
            }.accessibilityIdentifier("presenter.source")
                .photosPicker(isPresented: $showPhoto, selection: $photo, matching: .images)
        }
        Section {
            Label(model.running ? L("Shared with jam") : L("Preview · Only you"), systemImage: model.running ? "rectangle.on.rectangle" : "lock.fill")
                .font(.footnote)
            // One native preview surface has one owner, including while the
            // enlarged editor is open. Two hosts would steal it from each other.
            if expanded { Color.black.aspectRatio(model.aspectRatio, contentMode: .fit) }
            else { preview }
            Button { expanded = true } label: { Label(L("Expand canvas"), systemImage: "arrow.up.left.and.arrow.down.right") }
                .accessibilityIdentifier("presenter.expand")
                .sheet(isPresented: $expanded) {
                    NavigationStack {
                        ScrollView { VStack(spacing: 16) {
                            preview
                            Picker(L("Canvas tool"), selection: $tool) {
                                Text(L("Move camera")).tag(Tool.move)
                                if model.scene.layout == .instrument { Text(L("Crop")).tag(Tool.crop) }
                                Text(L("Draw")).tag(Tool.draw)
                            }.pickerStyle(.segmented)
                            if model.includeCamera && !model.nativeOverlay && model.scene.layout != .beside { placementControls }
                            Label(model.running ? L("Shared with jam") : L("Preview · Only you"), systemImage: model.running ? "rectangle.on.rectangle" : "lock.fill")
                                .font(.footnote)
                            PresenterShareControl(model: model)
                        }.padding() }
                            .navigationTitle(L("Canvas")).navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { expanded = false } } }
                    }.tint(.orange)
                }
            if model.screenPicking { ProgressView(L("Choose content in the system picker…")) }
            if model.cameraOn && !model.running {
                Text(L("This canvas is private. Your separate camera video is already live in the meeting."))
                    .font(.footnote).foregroundStyle(.orange)
            }
            Picker(L("Canvas tool"), selection: $tool) {
                Text(L("Move camera")).tag(Tool.move)
                if model.scene.layout == .instrument { Text(L("Crop")).tag(Tool.crop) }
                Text(L("Draw")).tag(Tool.draw)
            }.pickerStyle(.segmented).accessibilityIdentifier("presenter.tools")
            Toggle(L("Include my camera"), isOn: $model.includeCamera)
                .disabled(model.nativeOverlay).accessibilityIdentifier("presenter.camera")
            if model.nativeOverlay {
                Label(L("macOS Presenter Overlay is active"), systemImage: "person.crop.rectangle")
                    .font(.footnote)
                Text(L("Move or resize the camera using macOS controls. The app does not add a second camera layer."))
                    .font(.footnote).foregroundStyle(.secondary)
            } else if model.includeCamera {
                Label(model.hasCameraFrames ? L("Camera capture active") : L("Waiting for your camera…"),
                      systemImage: model.hasCameraFrames ? "camera.fill" : "hourglass")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier(model.hasCameraFrames ? "presenter.camera-ready" : "presenter.camera-waiting")
                if model.canFlipCamera {
                    Button { model.flipCamera() } label: { Label(L("Flip camera"), systemImage: "camera.rotate") }
                        .accessibilityIdentifier("presenter.flip-camera")
                }
                if ProcessInfo.processInfo.isiOSAppOnMac {
                    Button { model.scene.cameraRotation = (model.scene.cameraRotation + 90) % 360 }
                        label: { Label(L("Rotate camera"), systemImage: "rotate.right") }
                        .accessibilityIdentifier("presenter.rotate-camera")
                }
                Button { model.showCameraEffects() } label: { Label(L("Camera effects"), systemImage: "camera.filters") }
                    .disabled(!model.cameraOn && model.cameraDevice == nil)
                Picker(L("Camera layout"), selection: $model.scene.layout) {
                    Text(L("Camera card")).tag(PresenterScene.Layout.card)
                    Text(L("Person cutout")).tag(PresenterScene.Layout.cutout)
                    Text(L("Instrument close-up")).tag(PresenterScene.Layout.instrument)
                    Text(L("Side by side")).tag(PresenterScene.Layout.beside)
                }.accessibilityIdentifier("presenter.layout")
                if model.scene.layout != .beside { placementControls }
                if model.scene.layout == .instrument {
                    Slider(value: $model.scene.zoom, in: 1...4, step: 0.1) { Text(L("Camera magnification")) }
                        .accessibilityIdentifier("presenter.zoom")
                    Text(L("Select Crop, then drag to frame your instrument. Move camera repositions the layer."))
                        .font(.footnote).foregroundStyle(.secondary)
                } else if model.scene.layout == .cutout {
                    Text(L("Cutout hides the camera background in this canvas. If detection fails, the camera card is omitted. Use Camera card to keep instruments visible."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !ProcessInfo.processInfo.isiOSAppOnMac {
                Text(L("Screen broadcasts continue in other apps. The camera layer and drawings are available on image and blank canvases here."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if model.screenSelected && ProcessInfo.processInfo.isiOSAppOnMac {
                Text(L("For a system-managed camera overlay, enable your camera here, then choose Presenter Overlay in the macOS video menu."))
                    .font(.footnote).foregroundStyle(.secondary)
                Text(L("The screen continues in the background. The app camera layer and drawings return when you reopen the app; macOS manages its own overlay."))
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text(L("Only this composed canvas is shared. Sharing it stops in the background. Your camera becomes part of the canvas when sharing starts."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        Section(L("Canvas")) {
            Button { showFile = true } label: { Label(L("Open image file"), systemImage: "doc") }
                .fileImporter(isPresented: $showFile, allowedContentTypes: [.image]) { result in
                    switch result {
                    case .success(let url): importFile(url)
                    case .failure(let error): model.reportImportError(error.localizedDescription)
                    }
                }
            if #available(iOS 18.1, *) { PresenterImageGeneration(model: model) }
            if model.scene.image != nil {
                Button(L("Remove image")) { model.scene.image = nil; photo = nil }
            }
            if !model.screenSelected {
                Picker(L("Scene"), selection: $model.scene.backdrop) {
                    Text(L("Dark")).tag(PresenterScene.Backdrop.dark)
                    Text(L("Warm")).tag(PresenterScene.Backdrop.warm)
                    Text(L("Stage glow")).tag(PresenterScene.Backdrop.stage)
                }.accessibilityIdentifier("presenter.scene")
            }
            if !model.scene.strokes.isEmpty {
                HStack {
                    Button(L("Undo drawing")) { _ = model.scene.strokes.popLast() }
                    Spacer()
                    Button(L("Clear drawings")) { model.scene.strokes = [] }
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("presenter.error") }
        }
        .onChange(of: photo) { item in
            importTask?.cancel()
            importTask = Task {
                do {
                    if let data = try await item?.loadTransferable(type: Data.self), !Task.isCancelled { await model.loadImage(data) }
                } catch { if !Task.isCancelled { model.reportImportError(error.localizedDescription) } }
            }
        }
        .onDisappear { importTask?.cancel(); model.scene.draftStroke = [] }
        .onChange(of: model.scene.layout) { _ in if tool == .crop && model.scene.layout != .instrument { tool = .move } }
    }

    private var preview: some View {
        ZStack {
            StudioPreviewSurface(view: model.preview)
            GeometryReader { geometry in
                if tool == .draw || tool == .crop {
                    Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let point = CGPoint(x: min(1, max(0, value.location.x / max(1, geometry.size.width))),
                                                y: min(1, max(0, value.location.y / max(1, geometry.size.height))))
                            if tool == .draw {
                                if model.scene.draftStroke.count < 512 { model.scene.draftStroke.append(point) }
                            } else { model.scene.focus = point }
                        }
                        .onEnded { _ in
                            if tool == .draw {
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
    private var placementControls: some View {
        Group {
            Menu(L("Camera position")) {
                Button(L("Top left")) { place(right: false, bottom: false) }
                Button(L("Top right")) { place(right: true, bottom: false) }
                Button(L("Bottom left")) { place(right: false, bottom: true) }
                Button(L("Bottom right")) { place(right: true, bottom: true) }
            }.accessibilityIdentifier("presenter.position")
            Slider(value: Binding(get: { model.scene.placement.width }, set: { value in
                model.scene.placement.resize(value / model.scene.placement.width)
            }), in: 0.12...0.6, onEditingChanged: { if !$0 { model.savePlacement() } }) {
                Text(L("Camera size"))
            }.accessibilityIdentifier("presenter.size")
            Text(L("Drag to move. Pinch or drag the corner to resize."))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func place(right: Bool, bottom: Bool) {
        model.scene.placement.x = right ? 0.97 - model.scene.placement.width : 0.03
        model.scene.placement.y = bottom ? 0.96 - model.scene.placement.height : 0.04
        model.savePlacement()
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

@available(iOS 18.1, *)
private struct PresenterImageGeneration: View {
    @ObservedObject var model: PresenterModel
    @Environment(\.supportsImagePlayground) private var supported
    @State private var show = false
    var body: some View {
        if supported {
            Button { show = true } label: { Label(L("Create background with Apple"), systemImage: "sparkles") }
                .imagePlaygroundSheet(isPresented: $show) { url in
                    Task { do { await model.loadImage(try Data(contentsOf: url, options: .mappedIfSafe)) } catch { model.reportImportError(error.localizedDescription) } }
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
                Label(model.running ? L("Stop sharing") : L("Start sharing"),
                      systemImage: model.running ? "stop.circle" : "rectangle.on.rectangle")
            }.frame(maxWidth: .infinity, minHeight: 36)
        }.buttonStyle(.borderedProminent)
            .tint(model.running ? .red : .orange)
            .disabled(!model.available || (!model.running && (!model.hasPreview || model.screenPicking)) || model.starting || model.stopping)
            .accessibilityIdentifier(model.running ? "presenter.stop" : "presenter.start")
    }
}
