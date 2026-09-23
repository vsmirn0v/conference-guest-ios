# Validation recorded 23 September 2026

The current app is **Conference Guest**, a native SDK client. The earlier embedded-web experiment has been removed. The public vendor SDK is pinned to `salute-developers/jazz-ios-sdk@6d5f92869690fa22bb489a9089aa554d733c6936`; current-cloud interoperability is still unknown.

| Check | Result |
| --- | --- |
| Invite parser | `swift test --package-path ConferenceCore`: 4 passed; manual room validation, custom scheme, owned-domain link and invalid-host rejection. |
| Token broker | `python3 -m unittest discover -s GuestTokenBroker -p 'test_*.py'`: 4 passed; JWT signature, key validation, rate limit, request handling. No live vendor authorization was attempted. |
| iOS Simulator build | Xcode 27.0, `xcodebuild -project ConferenceGuest.xcodeproj -scheme ConferenceGuest -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -quiet build`: passed. |
| iOS device build | Same project with `-destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`: passed. This is an unsigned build, not an iPhone run. |
| Simulator launch | Installed and launched on iPhone 17 / iOS 26.5. Neutral app title and native join form rendered. With no token endpoint, Join was disabled and access-unavailable status was shown. |
| Background/foreground smoke | Opening Safari backgrounded the app; foregrounding it returned the same simulator process ID. No meeting was active, so this is a lifecycle smoke test only. |
| SDK packaging | The pinned package omits `Spench.framework` from its Swift product although the SDK binary loads it. The build script embeds the matching framework; simulator launch succeeds. |

**Not yet demonstrated:** native joining of a live meeting, guest admission across organizers, participant rendering, microphone/camera transmission and mute behavior observed by a second participant, or working Leave semantics. No SDK project key or deployed guest-token service was available for this run.

**Device acceptance remains open:** a real incoming cellular/FaceTime call, X or Instagram playback during a conference, background audio while switching apps or locking the phone, Bluetooth/wired route changes, camera continuity, and interruption recovery. The app requests `.playAndRecord` / `.videoChat` with `.mixWithOthers` once before joining, but the binary SDK may replace that configuration. The SDK's current `JazzSettings` initializer defaults feature flags to `.allDisabled`, including CallKit/PiP support; the app does not yet enable or validate those features. No claim of audio reliability should be made from the current builds.

The next test is a signed iPhone build with a real SDK project key kept solely in the broker, a representative existing meeting, and a second participant. Record whether membership remains intact and mute intent survives every interruption and audio-route scenario in [the implementation plan](implementation-plan.md). The simulator can provide preliminary lifecycle and SDK-state observations after credentials are available, but it cannot replace device acceptance for system audio behavior.
