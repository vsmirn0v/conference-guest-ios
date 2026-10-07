# Presenter canvas workspace

Expanded landscape, iPad and Mac layouts reserve a side dock for editing and sharing. Portrait puts tools below the canvas. Expanded mode removes the navigation bar and the inspector's separate sharing footer; Done returns to the inspector without stopping a share. The dock keeps private/live status and Share/Stop separate from editing actions, with English and Russian labels.

Move and Draw are explicit modes. Move drags the camera, with center alignment guides and a corner resize handle. The handle supports VoiceOver adjustment; camera layout, size, position, orientation and instrument cropping remain accessible in the actions menu. Clear drawings is undoable. Gesture edits, camera menu changes and drawings share a bounded 32-step undo/redo history. Interrupted and unchanged gestures do not consume history or discard redo.

Pinch zooms only the local workspace (1–4x); two fingers pan. Zoom In/Out in the actions menu provide mouse and VoiceOver alternatives. Fit returns to the complete composition. Neither viewport zoom nor selection controls enter the shared pixels. Rotation preserves zoom and the visible center where the new viewport's bounds allow it. A cancelled gesture restores the pre-gesture composition.

## Implementation boundaries

- `PresenterCanvasEditor` uses adaptive SwiftUI layout while retaining the same `PresenterCanvasSurface` identity.
- `PresenterCanvasScrollView` hosts the existing sample-buffer view once, delegates workspace navigation to UIScrollView, and draws selection controls in local layers. No extra video capture, compositor, thumbnail, or rendering timer is introduced.
- `PresenterCanvasEdit` captures only editable geometry and committed strokes. It excludes camera consent, live speech state, capture buffers, image assets and sharing lifecycle.
- Expanded and regular inspectors use the same share action and state checks. iPhone whole-device broadcast restrictions, recording, and media processing remain unchanged.

## Regression checks

`PresenterCanvasTests` covers mixed edit history, cancelled gestures, bounded storage, privacy boundaries, renderer ownership, workspace zoom isolation and layout dimensions. `PresenterUITests` exercises camera movement/resizing, drawing, Clear/Undo, pinch, Fit, rotation, expand/collapse, and Done during sharing in both languages using a capture-free guest fixture.

Validated on 2026-10-07:

- Mac: 54 focused Presenter, compositor, workflow and localization checks passed (`/tmp/rock-canvas-workspace-mac-final.xcresult`). The final layout/localization refinements passed all 13 focused checks (`/tmp/rock-canvas-workspace-mac-polish.xcresult`).
- iPhone SE, iOS 17.5 Simulator: both English and Russian full interaction flows passed (`/tmp/rock-canvas-workspace-se17-v2.xcresult`). Final Russian label and menu-zoom qualification, plus canvas/localization checks: 14 passed (`/tmp/rock-canvas-workspace-se17-final.xcresult`). Earlier compositor/workflow checks also passed: 38 total (`/tmp/rock-canvas-workspace-se17.xcresult`, whose early UI failures were subsequently fixed).
- iPhone 18 Pro, iOS 27 Simulator: the full camera/drawing/zoom/rotation/share interaction flow passed (`/tmp/rock-canvas-workspace-sim27-final.xcresult`). Its layout unit test initially assumed no system safe-area inset; the corrected test and final localization/layout checks all passed (13, `/tmp/rock-canvas-workspace-sim27-polish.xcresult`). The other 53 selected unit checks passed in the original run.
- Visual inspection: the small-screen Russian drawing label fits on one line; controls remain outside the canvas. Done has a full 44-point hit area. Final image: `/Users/v.smirnov/docs/work/canvas-landscape-design/implemented-landscape-ru.png`.

These are layout, gesture and composition/lifecycle checks, using capture-free UI fixtures. No physical-device or live-conference session was required or performed for this change. The existing media transport and hardware capture implementation were not modified. No TestFlight upload is part of this change.
