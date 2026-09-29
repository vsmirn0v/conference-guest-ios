# TestFlight 0.2.0 (21) — 29 September 2026

Source: `a8c714c` (includes `7939e4b` and `663c00d`). New users have an empty
profile name. The first join presents a name editor and resumes that invitation
only after confirmation. Cancellation leaves the invitation ready; a newer link
replaces the pending invitation without bypassing the editor. Existing names stay
saved. Edited names are applied through the guest coordinator on each join,
with a generation guard against delayed updates from a superseded room.

This release also includes the previously validated hostless-link website
selection, serialized/coalesced video subscriptions, independent rotation
fixtures, compact local sharing previews, and native capture lifecycle fixes.

Validation: 45 unit tests passed on iOS 17.5 and iOS 27. The first-join name
prompt, real community join, and persistence after restart passed on both.
Controls/conversation rotation passed on iOS 27. A real guest meeting opened
from a native handoff requested a name, then rejoined with an edited name in the
same process; its participant list and an independent browser participant both
showed the new name. Simulator tests were sufficient for these profile changes;
no new physical-device test was required. Earlier screen-capture hardware checks
are documented separately; older-device legacy preview and external Mac window
preview coverage remain limited.

The signed archive is
`~/Library/Developer/Xcode/Archives/2026-09-29/RockNRoll-0.2.0-b21.xcarchive`.
The app binary SHA-256 is
`476dd084dee91146ef1248fa9ecfa6827faf2a0376a95c68b468e87784369318`.
The app and both extensions contain `0.2.0 (21)`. Strict signature verification
passed. Xcode reported `Upload succeeded` and `EXPORT SUCCEEDED`; App Store
Connect finished processing successfully. The build was submitted to the internal
and public groups with automatic tester notification enabled. Both group build
pages show **Testing** for `0.2.0 (21)`. The public link remains
[Rock’n’Roll TestFlight](https://testflight.apple.com/join/Hd13C9U3).
The upload repeated existing third-party missing-dSYM warnings, which limit
symbolication of crashes inside those frameworks.

What to Test:
> Improved stability when opening several jams in succession. Fixed profile
> name updates and first-time joining. Improved screen-sharing previews and
> layout behavior.
