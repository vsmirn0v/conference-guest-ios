import CoreGraphics

/// Undo holds editable geometry and ink, never capture consent, frames or image assets.
public struct PresenterCanvasEdit: Equatable {
    public let strokes: [[CGPoint]]
    public let placement: PresenterPlacement
    public let layout: PresenterScene.Layout
    public let focus: CGPoint
    public let zoom: CGFloat
    public let rotation: Int

    public init(_ scene: PresenterScene) {
        strokes = scene.strokes; placement = scene.placement; layout = scene.layout
        focus = scene.focus; zoom = scene.zoom; rotation = scene.cameraRotation
    }
    public func restore(into scene: inout PresenterScene) {
        scene.strokes = strokes; scene.placement = placement; scene.layout = layout
        scene.focus = focus; scene.zoom = zoom; scene.cameraRotation = rotation
        scene.draftStroke = []
    }
}

/// Local editor magnification only. This value never enters the compositor.
public struct PresenterViewport: Equatable {
    public var zoom: CGFloat = 1
    public var center = CGPoint(x: 0.5, y: 0.5)
    public static let fit = PresenterViewport()
    public init(zoom: CGFloat = 1, center: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        self.zoom = zoom; self.center = center
    }
}
