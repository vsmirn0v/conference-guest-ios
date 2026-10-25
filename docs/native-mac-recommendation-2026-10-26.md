# Native Mac app recommendation

## Behavior

The iPhone/iPad binary shows a compact, dismissible recommendation immediately below Join only when running as an iOS app on Apple Silicon Mac. Public runtime detection (`ProcessInfo.isiOSAppOnMac`) gates both the Home card and Settings link; iPhone/iPad and the separate native app do not show them.

The card is available on idle Home. Joining, an active/hidden meeting, leaving or a Handoff suppresses it for the current Home lifetime, including after a failed join, so a new row cannot appear under an existing pointer. Dismissal is permanent and device-local. Settings retains the download entry after dismissal. Calendar/continuation/home scroll-anchor behavior remains intact.

Get the Mac app opens https://rock.glowsoft.ru/#download only after an explicit click, cancelling a pending automatic join. It does not install, launch, transfer meetings, detect another installation or dismiss the recommendation. Copy states the native app is recommended, the current app can still be used, Apple Silicon/macOS 13 requirements, and conditional iCloud setup for syncing name and saved invitations. No full-parity or migration promise is made. English and Russian are localized.

No push notification, notification permission, timed reminder, per-release redisplay, background work, network lookup or native distribution update is introduced. Stable/beta choice stays on the official download page. Native Mac build 26 and iOS share/VP9/Live Text behavior remain unchanged.

## Review and validation

Astra 6 xhigh planned the interaction and reviewed implementation twice. Review found asynchronous Home reinsertion after a failed join and a missing surviving-scroll anchor; both were fixed and covered. UI testing also exposed SwiftUI ancestor accessibility identifier propagation; the ancestor identifier was removed so close/download have distinct IDs.

Unit tests cover eligibility, actual runtime gate, local persistence/isolation, explicit fixed URL behavior, preference preservation and the activity suppression latch. UI tests cover placement, dismissal across relaunch, persistent Settings discovery, iPhone absence and Russian accessibility text. Release validation excludes the DEBUG-only isolated UI fixture.

Final test and publication evidence is recorded in the build 111 release note and `.build/release111/`.
