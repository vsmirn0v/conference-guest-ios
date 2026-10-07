import SwiftUI

struct PresenterCanvasEditor: View {
    @ObservedObject var model: PresenterModel
    @Binding var expanded: Bool
    var canShare: Bool
    @State private var viewport = PresenterViewport.fit
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GeometryReader { geometry in
            let docked = expanded && (geometry.size.width > geometry.size.height || sizeClass == .regular)
            let layout = docked ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 8))
            layout {
                // This branch and its single native renderer survive every layout change.
                ZStack {
                    PresenterCanvasSurface(model: model, viewport: $viewport)
                    if model.source == .screen && !model.screenSelected {
                        Button { model.selectScreen() } label: {
                            Label(L("Choose screen"), systemImage: "rectangle.on.rectangle").padding()
                        }.accessibilityIdentifier("presenter.choose-screen")
                    } else if !model.hasPreview { ProgressView().tint(.white) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black, in: RoundedRectangle(cornerRadius: 10))
                    .clipped()
                if docked { dock.frame(width: typeSize.isAccessibilitySize ? 184 : 124) }
                else { bottomTools }
            }.padding(expanded ? 8 : 0)
        }
        .onChange(of: model.source) { _ in viewport = .fit }
    }

    private var status: some View {
        Label(model.running ? L("Live") : L("Only you"), systemImage: model.running ? "dot.radiowaves.left.and.right" : "lock.fill")
            .font(.caption).foregroundStyle(model.running ? Color.orange : Color.secondary)
            .accessibilityIdentifier("presenter.visibility")
    }
    private var done: some View {
        Button { expanded = false } label: {
            Text(L("Done")).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }.accessibilityIdentifier("studio.done")
    }
    private var dock: some View {
        VStack(spacing: 6) {
            done
            status
            // Scroll only when accessibility text needs more room than the short edge.
            ScrollView {
                VStack(spacing: 6) {
                    modes
                    undoRedo
                    more
                    if viewport.zoom > 1.01 { fit }
                }
            }.scrollIndicators(.hidden)
            if canShare { PresenterShareControl(model: model, compact: true) }
        }
    }
    private var bottomTools: some View {
        VStack(spacing: 4) {
            HStack {
                status
                Spacer(minLength: 0)
                if expanded { done.frame(width: 88) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { modes; undoRedo; more; expandButton }
                VStack(spacing: 0) {
                    modes
                    HStack { undoRedo; Spacer(minLength: 0); more; expandButton }
                }
            }
            if expanded {
                HStack {
                    if viewport.zoom > 1.01 { fit }
                    if canShare { PresenterShareControl(model: model) }
                }
            }
        }
    }
    private var modes: some View {
        HStack(spacing: 4) {
            mode(.move, name: "Move", symbol: "arrow.up.and.down.and.arrow.left.and.right")
            mode(.draw, name: "Draw tool", symbol: "pencil.tip")
        }
    }
    private func mode(_ tool: PresenterModel.Tool, name: String, symbol: String) -> some View {
        Button { model.tool = tool } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                Text(L(name)).font(.caption).lineLimit(1).minimumScaleFactor(0.85)
            }.frame(maxWidth: .infinity, minHeight: 48)
                .padding(.horizontal, 3)
                .background(model.tool == tool ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).foregroundStyle(model.tool == tool ? Color.orange : Color.primary)
            .disabled(!model.canCompose)
            .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
            .accessibilityLabel(tool == .move ? L("Move camera") : L("Draw"))
            .accessibilityIdentifier("presenter.tool.\(tool.rawValue)")
    }
    @ViewBuilder private var expandButton: some View {
        if !expanded {
            Button { expanded = true } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44)
            }.accessibilityLabel(L("Expand canvas")).accessibilityIdentifier("presenter.expand")
        }
    }
    private var undoRedo: some View {
        HStack(spacing: 0) {
            Button { model.undoCanvasEdit() } label: { Image(systemName: "arrow.uturn.backward").frame(minWidth: 44, minHeight: 44) }
                .disabled(!model.canUndoEdit).accessibilityLabel(L("Undo")).accessibilityIdentifier("presenter.undo")
            Button { model.redoCanvasEdit() } label: { Image(systemName: "arrow.uturn.forward").frame(minWidth: 44, minHeight: 44) }
                .disabled(!model.canRedoEdit).accessibilityLabel(L("Redo")).accessibilityIdentifier("presenter.redo")
        }
    }
    private var fit: some View {
        Button { viewport = .fit } label: {
            Label(L("Fit canvas"), systemImage: "arrow.down.right.and.arrow.up.left").font(.caption).frame(minHeight: 44)
        }.accessibilityIdentifier("presenter.fit")
    }
    private var more: some View {
        Menu {
            Button { viewport = .fit } label: { Label(L("Fit canvas"), systemImage: "arrow.down.right.and.arrow.up.left") }
            Button { viewport.zoom = min(4, viewport.zoom * 1.5) } label: { Label(L("Zoom in"), systemImage: "plus.magnifyingglass") }
                .disabled(viewport.zoom >= 4)
            Button {
                let zoom = max(1, viewport.zoom / 1.5)
                viewport = zoom == 1 ? .fit : PresenterViewport(zoom: zoom, center: viewport.center)
            } label: { Label(L("Zoom out"), systemImage: "minus.magnifyingglass") }
                .disabled(viewport.zoom <= 1)
            if model.includeCamera && !model.nativeOverlay {
                Menu(L("Camera layout")) {
                    Picker(L("Camera layout"), selection: Binding(get: { model.scene.layout }, set: { layout in model.editCanvas { $0.layout = layout } })) {
                        Text(L("Camera card")).tag(PresenterScene.Layout.card)
                        Text(L("Person cutout")).tag(PresenterScene.Layout.cutout)
                        Text(L("Instrument close-up")).tag(PresenterScene.Layout.instrument)
                        Text(L("Side by side")).tag(PresenterScene.Layout.beside)
                    }
                    Button(L("Increase camera size")) { model.editCanvas { $0.placement.resize(1.1) } }
                    Button(L("Decrease camera size")) { model.editCanvas { $0.placement.resize(0.9) } }
                    Button(L("Top left")) { place(right: false, bottom: false) }
                    Button(L("Top right")) { place(right: true, bottom: false) }
                    Button(L("Bottom left")) { place(right: false, bottom: true) }
                    Button(L("Bottom right")) { place(right: true, bottom: true) }
                    Button(L("Rotate camera")) { model.editCanvas { $0.cameraRotation = ($0.cameraRotation + 90) % 360 } }
                    Button(L("Automatic camera orientation")) { model.editCanvas { $0.cameraRotation = 0 } }
                }
                if model.scene.layout == .instrument {
                    Button { model.tool = .crop } label: { Label(L("Crop"), systemImage: "crop") }
                    Button(L("Increase crop zoom")) { model.editCanvas { $0.zoom = min(4, $0.zoom * 1.2) } }
                    Button(L("Decrease crop zoom")) { model.editCanvas { $0.zoom = max(1, $0.zoom / 1.2) } }
                }
            }
            Button { model.clearDrawings() } label: { Label(L("Clear drawings"), systemImage: "trash") }
                .disabled(model.scene.strokes.isEmpty).accessibilityIdentifier("presenter.clear")
        } label: {
            Image(systemName: model.tool == .crop ? "crop" : "ellipsis").frame(minWidth: 44, minHeight: 44)
        }.accessibilityLabel(L("Canvas actions")).accessibilityIdentifier("presenter.actions")
    }
    private func place(right: Bool, bottom: Bool) {
        model.editCanvas {
            $0.placement.x = right ? 0.97 - $0.placement.width : 0.03
            $0.placement.y = bottom ? 0.96 - $0.placement.height : 0.04
        }
    }
}
