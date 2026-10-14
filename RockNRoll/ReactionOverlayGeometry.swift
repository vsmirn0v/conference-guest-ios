import CoreGraphics

enum ReactionOverlayGeometry {
    /// Compact headers can overlay the stage. Reactions start below that
    /// occlusion and inside the final tile area, including navigation/strips.
    static func contentRect(stage: CGRect, header: CGRect, headerVisible: Bool) -> CGRect {
        guard !stage.isEmpty else { return .zero }
        let top = headerVisible && stage.intersects(header) ? max(stage.minY, header.maxY) : stage.minY
        return CGRect(x: stage.minX + 8, y: top + 8, width: max(0, stage.width - 16),
                      height: max(0, stage.maxY - top - 16))
    }
}
