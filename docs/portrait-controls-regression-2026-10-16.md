# Guest meeting controls and their presentation host

## Defect

Build 95 could initially mount the interactive surface inside the SDK's full-window SwiftUI hosting view. That view rendered our UIKit children but did not route touches to them. In a live simulator meeting, both the top participant button and bottom Leave button failed window-level hit tests before any rotation. A later rotation could select a different ancestor and restore interaction.

The earlier synthetic layout fixture had only UIKit ancestors, so its geometry and zoom tests did not cover this SDK hosting behavior.

## Fix

The guest engine now explicitly supplies its persistent UIKit meeting container to `CallControls`. The interactive surface mounts there rather than discovering an arbitrary SDK ancestor. It keeps full-window media geometry, safe control insets and the existing overlay lifecycle. SDK subsidiary sheets can still be added above the surface in the same container. Removing the SDK overlay removes the surface, so it cannot block the home page after Leave or recovery.

This change does not modify capture, codecs or audio processing, and requires no polling or delayed interaction workaround.

## Evidence

- The live initial-portrait simulator test failed on both controls before the fix and passed afterward.
- All 28 selected Mac tests passed, including live guest control hit testing, SwiftUI embedding and surface removal, presentation geometry, actions and SDK screen/sheet lifecycle. The live Mac window was wide; portrait interaction is exercised by the simulator.
- All 28 selected simulator unit/integration tests passed. Three UI scenarios passed: privacy and restoration, full-display zoom with pixel assertions, and live Participants/Reactions/Leave interaction before rotation and after returning to portrait. The initial live UI run used the obsolete More label; the corrected selector uses the existing `call.reactions` identifier and passed on rerun.
- Raw results: ignored `.build/portrait-controls/`.

No physical iPhone was used for this follow-up.
