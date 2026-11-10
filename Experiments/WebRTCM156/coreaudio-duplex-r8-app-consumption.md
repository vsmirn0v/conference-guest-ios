R8 app-only completion consumption follow-up

SDK R8/b70fbdfc stays immutable; no SDK rebuild or default/iOS/DSP change. The DEBUG R6 caller now consumes native status, current intent, owner/permit, deadline and token outcome in one intent-lock critical section. Healthy native0 or-21 with a newer live intent retries the existing four-pass loop under the original deadline. Passive native health snapshots remain outside the lock and only reject. Required native commit must succeed before token/proof caching.

Receipts add nativeDeadlineUptime (the same constant passed on every native attempt), consumptionDecision and consumedIntent. Native status/abortReason are retained unchanged.

Focused construction/default/R6 SystemAudio suites passed against unchanged R8; source patch reconstructs exact bytes without fuzz. Tests exercise pure health/decision logic and a concurrent latch seam, not hardware recovery. Root Host57 still must establish live supersession→same-owner output success without another native Start, continuity/privacy and checked shutdown. Automated checks only; no quality/promotion claim.

Evidence: .build/airpods-transition-startup/r8-app-consumption-followup/build-evidence.json; reviewed revision-2; source/preimages and test logs retained.
