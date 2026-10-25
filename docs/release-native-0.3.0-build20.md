# Rock’n’Roll Native Guest 0.3.0 (20)

## Changes and acceptance

First separate Apple Silicon native Mac TestFlight beta. Uses the qualified M156 desktop media stack and native meeting workspace: Home/library, calendars/reminders, all four meeting providers, gallery/Focus, sharing/Presenter, guest conversation, device controls and optional existing-schema iCloud sync. Closing the meeting window keeps audio active; Leave tears it down.

Source is `57636335d285b8e092da72ba85e2f15c94ef932f`. All 153 production source hashes and archived artifact hashes match the accepted build. This release does not migrate the iOS engine. The final archive is `.build/native-desktop-parity-r4/RockNRollNativeGuest-0.3.0-20.xcarchive`; its immutable source receipt is `build-evidence-release-0.3.0-20.json` beside it.

Dated acceptance records: [desktop parity](native-mac-feature-parity-2026-10-24.md), [cloud and performance](native-mac-cloud-performance-2026-10-25.md), [live transfer](native-mac-handoff-validation-2026-10-25.md). Normal Mac/iPhone CloudKit transfers and independent incoming/outgoing media, sharing/resizing, reconnect and large-room cases passed. System Dock/app-switcher Handoff remains unverified; Safari control discovery failed too. Physical accessory/acoustic, older macOS and broader provider/OS variants are separate beta limitations. Requires Apple Silicon/macOS 13+, with system source selection on macOS 14+.

## Distribution

App Store Connect app `6826587350`. Mac App Store distribution export and signed installer-package checks passed, with Production CloudKit, production APNs, sandbox and no debugger entitlement. Package SHA-256: `c2dc91ab44770dc3481bffc4c3a4418e596ad720ec357158aa4038d49b7fc3c3`. Upload and Apple processing passed on October 25, 2026. Evidence: `.build/native-release20/`.

User explicitly approved excluding France. The native app availability is 174 territories with France unselected; export compliance records standard third-party encryption and no France distribution. Revisit the declaration before adding France or changing encryption.

Build 20 is Ready to Test in Native Mac Internal (one invited tester). It is assigned to Native Mac Public Beta, with automatic tester notification, and is **Waiting for Review**. The [public TestFlight link](https://testflight.apple.com/join/NnSR6Rqd) exists but cannot accept testers until Apple approves the build. Submission and public link readbacks are retained locally; upload/submission is not a claim of external approval.
