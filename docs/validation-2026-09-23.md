# Validation record — 23 September 2026

Build under test: pinned public iOS SDK `salute-developers/jazz-ios-sdk@6d5f92869690fa22bb489a9089aa554d733c6936` (25.3.1020); Xcode 27.0; signed with development team `5V64BP2H3P` on the connected `iVitalii` iPhone. No live invitation password, SDK key or token broker is stored in this repository.

| Check | Observed result |
| --- | --- |
| Anonymous browser trace | `/user/info` returned `authType: ANONYMOUS`; the guest join page fetched room public info and posted a password-bearing anonymous `/preconnect` request. The origin's well-known service document identified its conference backend. This is direct trace evidence for the web flow, not a promise of public protocol stability. |
| Native anonymous authorization | With the pinned SDK, an empty-string `.jazzToken` callback joined the supplied guest-enabled meeting. No account login or SDK project key was needed in this test. |
| Invitation decoding | Passing the URL's encoded `psw` directly as `JazzRoom(decodedPassword:)` crashed in the SDK password coder. Using `JazzSession.shared.handle(url:type:.applink)` decoded it and joined. The crash path is removed. |
| Endpoint derivation | The SDK default host was `jazz.sber.ru`; the invitation origin's well-known document resolved a different backend, `bk.salutejazz.ru`, and the signed app joined through that discovered host. The backend is not hardcoded in app settings. |
| Device build and join | Automatic signing, device build, install and launch succeeded. The native view showed two participant tiles and compact in-call controls. A second browser participant listed the phone with microphone Off and camera Off. The user's later observed microphone-on state resulted from manual enabling on iOS. |
| Native deeplink | A cold `conferenceguest://join?url=…` launch via `devicectl --payload-url` opened the signed app and populated the original HTTPS invitation; the Join screen reported the meeting ready. This did not test Universal Link association. |
| Ordinary background | Opening Safari initially retained two browser participants. After a longer background period with both local streams off, the browser listed only itself. Foregrounding the app restored the phone. This **fails** background membership acceptance. Exact disconnect/rejoin timing was not instrumented. |
| Other-app playback | A temporary, separately signed iOS QA app started 15 seconds of nonmixable audio while the phone was in the conference. The phone initially remained listed, then disappeared from the browser participant list; foregrounding the conference app restored it. No app crash was seen, but uninterrupted membership **failed**. The QA app was uninstalled afterward. This is a controlled competing-audio test, not an X/Instagram test. |
| Audio session | Before join the app requested `.playAndRecord` / `.videoChat` with options 5 (`mixWithOthers` plus Bluetooth HFP). The SDK changed it after join to `.playAndRecord` / `.voiceChat` with options 36 (no mixing). A guarded restoration produced options 37, yet the competing-audio/background disconnect still occurred. |
| CallKit experiment | Enabling the SDK's `isCallKitSupported` flag showed a system call UI stuck at “Connection…” and the browser never saw the phone join. The experiment was removed from the working configuration. |
| Packaging | The SDK package omits `Spench.framework` from its product although the binary loads it. The build script embeds the matching framework; simulator and device launch succeeded. |

The original unsigned simulator/device builds and simulator join-screen launch passed before this device run. After the latest edits, the signed device build passed and `ConferenceCore` passed all four unit tests with the full Xcode developer directory selected. `git diff --check` passed.

**Not yet accepted:** actual audibility of remote speech on the phone, camera/mic uplink verified from a second endpoint after intentional enabling, real-device Leave behavior, incoming cellular/FaceTime interruption, X/Instagram audio, lock-screen duration, Bluetooth/wired route switching, owned-domain Universal Links and cross-organizer guest policy. A second endpoint is essential for those checks.

The browser meeting was left and the temporary competing-audio QA app was uninstalled after testing. The failed background cases are the next engineering gate; `UIBackgroundModes=audio` and restoring `.mixWithOthers` are not by themselves a passing implementation.
