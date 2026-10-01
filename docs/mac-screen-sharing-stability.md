# Mac screen-sharing suspension termination — 2 October 2026

## Evidence and cause

Both user reports from 1 October, at 22:15 and 22:52, were system terminations
(`EXC_CRASH / SIGKILL`, RunningBoard `0xdead10cc`) rather than a thrown exception.
The unified log explicitly identifies a shared lock in Metal's shader-cache
`com.apple.metal/archiveUsage.db/lock.mdb` when the UIKit app was suspended.
The main thread was idle, not crashing in the capture callback.

An isolated Mac thumbnail fixture opened the same cache when using Core Image,
including with `useSoftwareRenderer`. A fixture without pixel conversion did not.
VideoToolbox plus a bounded Core Graphics bitmap conversion avoids that cache in
the isolated fixture. The live guest SDK also opens Metal's cache: replacing the
thumbnail alone reproduced the same suspension termination in about 90 seconds.

macOS's Report button saved local crash reports in DiagnosticReports (including
its Retired folder). It does not open an in-app support ticket. Whether the
system also uploaded those reports to Apple was not verified.

## Changes

- Own a public Foundation activity token while a Mac meeting joins. If no media
  engine was initialized, reaching idle ends it. Once media initializes, the
  framework-owned graphics cache survives Leave and has no supported teardown
  API in this runtime: a shared process-lifetime guard prevents App Nap while
  those cache locks remain. It allows idle system sleep and is not acquired on
  iPhone/iPad. It is a workaround for UIKit-on-Mac suspension, not a background
  task loop, silent audio track, or global system preference.
- Clear per-meeting stream and title subscriptions at teardown. This releases
  our references but alone does not close the framework-owned shader cache.
- The iOS SDK marks the macOS `NSProcessInfo` methods unavailable. The Mac-only
  bridge checks runtime availability and uses their documented Objective-C ABI;
  it calls no private API. This is specific to the existing Designed-for-iPad
  runtime and does not create a Catalyst/AppKit port.
- Convert Mac confidence thumbnails through VideoToolbox/Core Graphics instead
  of retaining a Core Image context. Keep the existing 640-pixel bound, two-fps
  throttle, color space and rotation, and don't retain the full capture buffer.
  Incoming video, outgoing encoding, iPhone/iPad previews and ReplayKit are
  unchanged.

The SDK's SQLite file logger separately triggered a resource report for heavy
disk writes (about 34 GB over 4.8 hours, no enforcement action). Symbolication
identifies `SqliteFileLogger.logMessage`/`SqliteDatabase.insert`; it was not the
lock named by RunningBoard. That SDK logging issue is not changed in this fix.

## Validation

Final runtime, simulator and release results are recorded in the build 31
release note. Evidence logs and result bundles are local under `/tmp/rock-crash*`
and `/tmp/rock-share-activity-mac.log`.

Build 30 was uploaded before the post-Leave soak exposed the remaining system
termination. It is superseded by build 31 and must not be assigned to testers.
