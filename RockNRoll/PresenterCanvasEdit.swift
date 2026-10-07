import CoreGraphics

/// Undo holds editable geometry and ink, never capture consent, frames or image assets.
struct PresenterCanvasEdit: Equatable {
    let strokes: [[CGPoint]]
    let placement: PresenterPlacement
    let layout: PresenterScene.Layout
    let focus: CGPoint
    let zoom: CGFloat
    let rotation: Int

    init(_ scene: PresenterScene) {
        strokes = scene.strokes; placement = scene.placement; layout = scene.layout
        focus = scene.focus; zoom = scene.zoom; rotation = scene.cameraRotation
    }
    func restore(into scene: inout PresenterScene) {
        scene.strokes = strokes; scene.placement = placement; scene.layout = layout
        scene.focus = focus; scene.zoom = zoom; scene.cameraRotation = rotation
        scene.draftStroke = []
    }
}

/// Local editor magnification only. This value never enters the compositor.
struct PresenterViewport: Equatable {
    var zoom: CGFloat = 1
    var center = CGPoint(x: 0.5, y: 0.5)
    static let fit = PresenterViewport()
}
