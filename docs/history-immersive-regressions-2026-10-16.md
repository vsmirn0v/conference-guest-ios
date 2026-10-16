# History and immersive screen sharing

## Confirmed defects and fixes

- New history records left `hasBeenJoined` unset, using the legacy representation. A saved-only cloud record with the same timestamp could downgrade the visit and remove an unstarred entry during normalization. New successful visits now explicitly store `true`. A regression failed in both merge directions before the fix and passes afterward. The exact cloud state of the reported room was unavailable, so this establishes a reproducible failure mechanism rather than a confirmed incident reconstruction.
- Calendar and handoff joins discarded the displayed meeting title. Their titles now follow the join through name entry, engine selection and queued replacement, and remain attached to the successful visit. Failed joins still create no visit.
- Hidden-controls media geometry retained safe-area side insets and extra margins. Immersive media now uses the complete window; privacy headers and visible controls retain safe positioning. Guest overlays also escape ancestors that clip to the safe area.

## Verification

- 122 ConferenceCore tests passed, including the new cloud-merge regression.
- 44 selected simulator tests passed: join routing, persisted history, two-replica sync and presentation geometry. Calendar and handoff routes cover all four engines using simulated transports; no live connection to the supplied production room was made.
- Mac: 43 selected tests passed, followed by all eight routing tests after the final name-entry regression was added. An earlier timer-based transient-controls test failed during concurrent test startup and passed in the subsequent full run.
- iPhone 17 Pro Max / iOS 27 simulator: four presentation UI scenarios passed. The strengthened immersive test additionally passed with full-display pixel assertions after rotation and zoom, exercising a clipped safe-area host, fit at startup, both landscape orientations, panning and control restoration.
- Use `XCUIScreen.main.screenshot()` for landscape pixel validation. Cropped application screenshots returned an incorrect portrait-sized region during these runs.

No physical-device check or TestFlight publication was performed for this change.
