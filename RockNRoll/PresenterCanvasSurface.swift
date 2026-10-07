import SwiftUI
import UIKit

struct PresenterCanvasSurface: UIViewRepresentable {
    @ObservedObject var model: PresenterModel
    @Binding var viewport: PresenterViewport
    func makeUIView(context: Context) -> PresenterCanvasScrollView { PresenterCanvasScrollView() }
    func updateUIView(_ view: PresenterCanvasScrollView, context: Context) {
        view.onViewportChange = { viewport = $0 }
        view.configure(model: model, viewport: viewport)
    }
    static func dismantleUIView(_ view: PresenterCanvasScrollView, coordinator: ()) { view.cancelEditing() }
}

/// UIScrollView owns two-finger navigation; the editor owns one-finger edits.
/// Zoom transforms the existing display surface, not its rendered/shared pixels.
final class PresenterCanvasScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let canvas = UIView()
    private let selection = CAShapeLayer()
    private let guides = CAShapeLayer()
    private let handle = PresenterResizeHandle(image: UIImage(systemName: "arrow.up.left.and.arrow.down.right"))
    private weak var model: PresenterModel?
    private var previousSize = CGSize.zero
    private var ratio: CGFloat = 16 / 9
    private var layingOut = false
    private var requested: PresenterViewport?
    private(set) var viewport = PresenterViewport.fit
    var onViewportChange: ((PresenterViewport) -> Void)?
    private var originalPlacement: PresenterPlacement?
    private var editingTool: PresenterModel.Tool?
    private var resizing = false
    private var snapX = false, snapY = false
    private var handleScale: CGFloat = 0
    private lazy var edit = UIPanGestureRecognizer(target: self, action: #selector(editCanvas(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self; minimumZoomScale = 1; maximumZoomScale = 4
        bouncesZoom = false; showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never; delaysContentTouches = false
        panGestureRecognizer.minimumNumberOfTouches = 2
        addSubview(canvas); canvas.clipsToBounds = true; canvas.backgroundColor = .black
        canvas.accessibilityIdentifier = "presenter.composition"
        canvas.layer.addSublayer(selection); canvas.layer.addSublayer(guides)
        selection.fillColor = UIColor.clear.cgColor; selection.strokeColor = UIColor.systemOrange.cgColor
        guides.fillColor = UIColor.clear.cgColor; guides.strokeColor = UIColor.systemOrange.cgColor
        handle.backgroundColor = .systemOrange; handle.tintColor = .black; handle.contentMode = .center
        handle.isAccessibilityElement = true; handle.accessibilityTraits = .adjustable
        handle.accessibilityLabel = L("Resize camera"); handle.accessibilityIdentifier = "presenter.resize"
        handle.resize = { [weak self] factor in self?.model?.editCanvas { $0.placement.resize(factor) } }
        canvas.addSubview(handle)
        edit.minimumNumberOfTouches = 1; edit.maximumNumberOfTouches = 1; edit.delegate = self
        canvas.addGestureRecognizer(edit)
        accessibilityIdentifier = "presenter.preview"
        accessibilityLabel = L("Canvas")
        accessibilityHint = L("Pinch to zoom the workspace. Use two fingers to pan.")
    }
    required init?(coder: NSCoder) { nil }

    func configure(model: PresenterModel, viewport: PresenterViewport) {
        self.model = model
        if model.preview.superview !== canvas {
            canvas.insertSubview(model.preview, at: 0)
        }
        model.preview.frame = canvas.bounds
        if ratio != model.aspectRatio { ratio = model.aspectRatio; previousSize = .zero }
        if editingTool != nil && (editingTool != model.tool || !model.canCompose) { cancelEditing() }
        if requested != viewport {
            requested = viewport; self.viewport = viewport
            if !bounds.isEmpty { applyViewport() }
        }
        setNeedsLayout(); updateSelection()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { model?.restorePreview() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard !layingOut, bounds.width > 0, bounds.height > 0 else { return }
        if previousSize != bounds.size {
            cancelEditing()
            layingOut = true
            let stored = viewport
            setZoomScale(1, animated: false)
            let width = min(bounds.width, bounds.height * ratio)
            canvas.frame = CGRect(origin: .zero, size: CGSize(width: width, height: width / ratio))
            model?.preview.frame = canvas.bounds
            contentSize = canvas.bounds.size
            previousSize = bounds.size; viewport = stored
            layingOut = false; applyViewport(); model?.restorePreview()
        }
        updateSelection()
    }
    private func applyViewport() {
        guard !canvas.bounds.isEmpty else { return }
        layingOut = true
        let zoom = viewport.zoom.isFinite ? min(4, max(1, viewport.zoom)) : 1
        setZoomScale(zoom, animated: false)
        centerCanvas()
        let size = contentSize
        let center = CGPoint(x: viewport.center.x.isFinite ? viewport.center.x : 0.5,
                             y: viewport.center.y.isFinite ? viewport.center.y : 0.5)
        contentOffset = CGPoint(
            x: min(max(-contentInset.left, center.x * size.width - bounds.width / 2), max(-contentInset.left, size.width - bounds.width + contentInset.right)),
            y: min(max(-contentInset.top, center.y * size.height - bounds.height / 2), max(-contentInset.top, size.height - bounds.height + contentInset.bottom)))
        layingOut = false; captureViewport(); updateSelection()
    }
    private func centerCanvas() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }
    private func captureViewport() {
        guard !layingOut, contentSize.width > 0, contentSize.height > 0 else { return }
        viewport = PresenterViewport(zoom: zoomScale, center: CGPoint(
            x: (contentOffset.x + bounds.width / 2) / contentSize.width,
            y: (contentOffset.y + bounds.height / 2) / contentSize.height))
        accessibilityValue = String(format: "%.0f%%", zoomScale * 100)
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { cancelEditing() }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard !layingOut else { return }
        layingOut = true; centerCanvas(); layingOut = false
        captureViewport(); updateSelection()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { captureViewport() }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { reportViewport() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { reportViewport() } }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { reportViewport() }
    private func reportViewport() { captureViewport(); onViewportChange?(viewport) }

    private var movable: Bool {
        guard let model else { return false }
        return model.canCompose && model.includeCamera && !model.nativeOverlay && model.scene.layout != .beside
    }
    private var cameraRect: CGRect {
        guard let place = model?.scene.placement else { return .zero }
        return CGRect(x: place.x * canvas.bounds.width, y: place.y * canvas.bounds.height,
                      width: place.width * canvas.bounds.width, height: place.height * canvas.bounds.height)
    }
    private func updateSelection() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let visible = movable && model?.tool == .move
        selection.isHidden = !visible; handle.isHidden = !visible
        let rect = cameraRect, scale = max(1, zoomScale)
        selection.path = UIBezierPath(roundedRect: rect, cornerRadius: 8 / scale).cgPath
        selection.lineWidth = 2 / scale; selection.lineDashPattern = [6 / scale, 4 / scale].map { NSNumber(value: Double($0)) }
        // Constant on-screen touch target, also at 4x workspace magnification.
        handle.frame = CGRect(x: rect.maxX - 44 / scale, y: rect.maxY - 44 / scale, width: 44 / scale, height: 44 / scale)
        handle.layer.cornerRadius = 22 / scale
        if handleScale != scale {
            handleScale = scale
            handle.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15 / scale))
        }
        let path = UIBezierPath()
        if snapX { path.move(to: CGPoint(x: canvas.bounds.midX, y: 0)); path.addLine(to: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.height)) }
        if snapY { path.move(to: CGPoint(x: 0, y: canvas.bounds.midY)); path.addLine(to: CGPoint(x: canvas.bounds.width, y: canvas.bounds.midY)) }
        guides.path = path.cgPath; guides.lineWidth = 1 / scale
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === edit else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        guard let model, model.canCompose, !isZooming else { return false }
        if model.tool == .move { return movable && cameraRect.contains(editStartPoint(edit)) }
        return model.tool == .draw || (model.tool == .crop && movable && model.scene.layout == .instrument)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other === pinchGestureRecognizer || other === panGestureRecognizer
    }
    @objc private func editCanvas(_ gesture: UIPanGestureRecognizer) {
        guard let model, !canvas.bounds.isEmpty else { return }
        let location = gesture.location(in: canvas)
        let point = CGPoint(x: min(1, max(0, location.x / canvas.bounds.width)), y: min(1, max(0, location.y / canvas.bounds.height)))
        switch gesture.state {
        case .began:
            editingTool = model.tool; originalPlacement = model.scene.placement
            resizing = model.tool == .move && handle.frame.contains(editStartPoint(gesture))
            model.beginCanvasEdit()
            if model.tool == .draw { model.scene.draftStroke = [point] }
        case .changed:
            guard editingTool != nil else { return }
            switch editingTool {
            case .draw:
                if model.scene.draftStroke.count < 512 { model.scene.draftStroke.append(point) }
            case .crop: model.scene.focus = point
            case .move:
                guard var place = originalPlacement else { return }
                let delta = gesture.translation(in: canvas)
                if resizing {
                    let factor = max(0.2, 1 + delta.x / max(1, place.width * canvas.bounds.width))
                    place.width *= factor; place.height *= factor
                } else {
                    place.x += delta.x / canvas.bounds.width; place.y += delta.y / canvas.bounds.height
                    snapX = abs(place.x + place.width / 2 - 0.5) < 6 / (canvas.bounds.width * zoomScale)
                    snapY = abs(place.y + place.height / 2 - 0.5) < 6 / (canvas.bounds.height * zoomScale)
                    if snapX { place.x = 0.5 - place.width / 2 }
                    if snapY { place.y = 0.5 - place.height / 2 }
                }
                place.clamp(); model.scene.placement = place; updateSelection()
            case .none: break
            }
        case .ended:
            guard editingTool != nil else { return }
            if editingTool == .draw {
                let points = model.scene.draftStroke; model.scene.draftStroke = []; model.appendAnnotation(points)
            }
            model.commitCanvasEdit(); finishEditing()
        case .cancelled, .failed: cancelEditing()
        default: break
        }
    }
    func cancelEditing() {
        guard editingTool != nil else { return }
        model?.cancelCanvasEdit(); finishEditing()
    }
    private func finishEditing() {
        editingTool = nil; originalPlacement = nil; snapX = false; snapY = false; updateSelection()
    }
    private func editStartPoint(_ gesture: UIPanGestureRecognizer) -> CGPoint {
        let point = gesture.location(in: canvas), delta = gesture.translation(in: canvas)
        return CGPoint(x: point.x - delta.x, y: point.y - delta.y)
    }
}

private final class PresenterResizeHandle: UIImageView {
    var resize: ((CGFloat) -> Void)?
    override func accessibilityIncrement() { resize?(1.1) }
    override func accessibilityDecrement() { resize?(0.9) }
}
