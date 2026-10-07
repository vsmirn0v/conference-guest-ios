import SwiftUI
import XCTest
@testable import RockNRoll

@MainActor
final class PresenterCanvasTests: XCTestCase {
    private func makeModel() -> PresenterModel {
        let suite = "presenter-canvas-tests-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        addTeardownBlock { preferences.removePersistentDomain(forName: suite) }
        return PresenterModel(observeLifecycle: false, preferences: preferences)
    }
    func testUndoTreatsWholeCameraGestureAsOneEditAndPreservesPrivacy() {
        let model = makeModel()
        defer { model.end() }
        let original = model.scene.placement
        model.beginCanvasEdit()
        for i in 0..<100 { model.scene.placement.x = CGFloat(i) / 200 }
        model.scene.placement.resize(0.8)
        let moved = model.scene.placement
        model.commitCanvasEdit()
        model.undoCanvasEdit()
        XCTAssertEqual(model.scene.placement, original)
        XCTAssertFalse(model.canUndoEdit)
        model.redoCanvasEdit()
        XCTAssertEqual(model.scene.placement, moved)
        XCTAssertFalse(model.running); XCTAssertFalse(model.includeCamera)
    }
    func testMixedDrawingAndGeometryHistoryKeepsOrderAndClearingIsReversible() {
        let model = makeModel()
        defer { model.end() }
        let original = model.scene.placement
        let line = [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.7, y: 0.6)]
        model.appendAnnotation(line)
        model.editCanvas { $0.placement.x = 0.1; $0.layout = .instrument; $0.focus.x = 0.2; $0.zoom = 2 }
        model.clearDrawings()
        model.undoCanvasEdit(); XCTAssertEqual(model.scene.strokes, [line])
        model.undoCanvasEdit(); XCTAssertEqual(model.scene.placement, original)
        XCTAssertEqual(model.scene.layout, .card); XCTAssertEqual(model.scene.zoom, 1)
        model.undoCanvasEdit(); XCTAssertTrue(model.scene.strokes.isEmpty)
        model.redoCanvasEdit(); model.redoCanvasEdit(); model.redoCanvasEdit()
        XCTAssertEqual(model.scene.placement.x, 0.1); XCTAssertTrue(model.scene.strokes.isEmpty)
        XCTAssertFalse(model.canRedoEdit)
    }
    func testCancelledAndUnchangedEditsDoNotDestroyRedoOrCreateUndo() {
        let model = makeModel()
        defer { model.end() }
        model.editCanvas { $0.placement.x = 0.1 }; model.undoCanvasEdit()
        let original = model.scene
        model.beginCanvasEdit(); model.scene.placement.x = 0.3
        model.scene.draftStroke = [.zero]; model.cancelCanvasEdit()
        XCTAssertEqual(model.scene, original)
        model.beginCanvasEdit(); model.commitCanvasEdit()
        XCTAssertFalse(model.canUndoEdit); XCTAssertTrue(model.canRedoEdit)
        model.editCanvas { $0.cameraRotation = 90 }
        XCTAssertFalse(model.canRedoEdit)
    }
    func testUndoDoesNotRestoreLiveCameraActivityOrHoldOldBackgrounds() {
        let model = makeModel()
        defer { model.end() }
        model.editCanvas { $0.placement.x = 0.1 }
        model.scene.speaking = true; model.scene.backdrop = .warm
        model.undoCanvasEdit()
        XCTAssertTrue(model.scene.speaking); XCTAssertEqual(model.scene.backdrop, .warm)
    }
    func testHistoryIsBoundedAndEndsWithTheMeeting() {
        let model = makeModel()
        for i in 0..<50 { model.editCanvas { $0.placement.x = CGFloat(i) / 100 } }
        var count = 0
        while model.canUndoEdit { model.undoCanvasEdit(); count += 1 }
        XCTAssertEqual(count, 32)
        model.end(); XCTAssertFalse(model.canUndoEdit); XCTAssertFalse(model.canRedoEdit)
    }
    func testWorkspaceZoomAndRotationDoNotChangeSharedSceneOrDuplicateRenderer() {
        let model = makeModel()
        defer { model.end() }
        let surface = PresenterCanvasScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 330))
        surface.configure(model: model, viewport: .fit); surface.layoutIfNeeded()
        let parent = model.preview.superview
        let original = model.scene
        surface.configure(model: model, viewport: PresenterViewport(zoom: 2, center: CGPoint(x: 0.6, y: 0.4)))
        surface.layoutIfNeeded()
        XCTAssertEqual(surface.zoomScale, 2)
        let center = surface.viewport.center
        surface.frame.size = CGSize(width: 300, height: 500); surface.layoutIfNeeded()
        XCTAssertEqual(surface.zoomScale, 2)
        XCTAssertEqual(surface.viewport.center.x, center.x, accuracy: 0.001)
        XCTAssertTrue(model.preview.superview === parent)
        XCTAssertEqual(model.scene, original)
        surface.configure(model: model, viewport: .fit); surface.layoutIfNeeded()
        XCTAssertEqual(surface.zoomScale, 1)
        XCTAssertEqual(surface.viewport.center.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(surface.viewport.center.y, 0.5, accuracy: 0.001)
        XCTAssertFalse(model.canUndoEdit)
    }
    func testExpandedLayoutUsesOneSurfaceAndKeepsToolsOutsideItsBounds() {
        let model = makeModel()
        defer { model.end() }
        model.selectCanvas()
        let host = UIHostingController(rootView: PresenterCanvasEditor(model: model, expanded: .constant(true), canShare: true))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 667, height: 375))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = CGRect(x: 0, y: 0, width: 667, height: 375)
        host.view.layoutIfNeeded()
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let surfaces = descendants(host.view).compactMap { $0 as? PresenterCanvasScrollView }
        XCTAssertEqual(surfaces.count, 1)
        let safe = host.view.safeAreaInsets
        XCTAssertEqual(surfaces.first?.bounds.height ?? 0,
                       host.view.bounds.height - safe.top - safe.bottom - 16, accuracy: 1)
        XCTAssertEqual(surfaces.first?.bounds.width ?? 0,
                       host.view.bounds.width - safe.left - safe.right - 16 - 12 - 124, accuracy: 1)
    }
}
