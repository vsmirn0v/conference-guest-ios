# Rock’n’Roll 0.2.0 (45)

Publishes the efficiency work documented in `release-0.2.0-build44.md` and
`Experiments/AppEfficiency/README.md`, including the Presenter work in `49f5a3f`.
Build 44 was an uploaded candidate; build 45 corrects the initial power-policy
notification so the existing SDK Presenter camera observer remains capped at
12 fps rather than being raised to 15 fps. Optional work slows further under power
or thermal pressure. Owned private Presenter capture retains its qualified 15 fps.

Beta notes: “Improved stability and efficiency, smoother media previews, and fixes
when switching meetings.”

## Validation

The complete regression and physical/live acceptance results are recorded in
`release-0.2.0-build44.md`. Additional final checks:

- iOS 27: 38 targeted checks passed, two opt-in checks skipped. A generated 60 fps
  source confirms that the SDK Presenter observer remains below its prior 12 fps
  cap after observing the power policy and detaches completely when stopped.
  Media demand, source retirement and Presenter regressions also pass.
  `/tmp/rock-energy-cap-final.xcresult`.
- iVitalii live automatic PiP: the browser's moving demo share stays live beyond the
  three-second background grace, returns to the meeting and leaves cleanly.
  `/tmp/rock-energy-live-pip.xcresult`.

No changes to audio processing, outgoing codec settings, iOS 16 minimum, permissions,
opt-in iCloud policy or server configuration. Actual whole-device battery savings
remain unquantified; transcript correction CPU time is about 90% lower in the
matched isolated benchmark.

## Archive

Archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-07/RockNRoll-0.2.0-b45.xcarchive`.
Executable SHA-256: `2be78a3d84e19200716f068817cbd134e7364dc8e8eedb71f386efdfdf582ba8`.
Executable/dSYM UUID: `A93B81FB-38BC-339B-962E-4F813718B90F`.

Distribution readback follows after processing and group assignment.
