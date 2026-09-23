**Validation recorded 23 September 2026**

Local source: `vsmirn0v/jazz-ios-client`, generated with XcodeGen 2.46.0. Vendor dependency pinned to `salute-developers/jazz-ios-sdk@6d5f92869690fa22bb489a9089aa554d733c6936`.

**Passed**

| Check | Evidence |
| --- | --- |
| Guest link parser | `swift test --package-path JazzGuestCore`: 5 tests, 0 failures; manual room fields, scheme/owned-domain links, rejected unsupported hosts and non-HTTPS links, and website URL construction. |
| Token broker | `python3 -m unittest discover -s GuestTokenBroker -p 'test_*.py'`: 4 tests, 0 failures; JOSE signature verification, JWK coordinate validation, rate limit and HTTP request/response behavior. |
| iOS Simulator build | Xcode 27.0, `xcodebuild -project JazzGuest.xcodeproj -scheme JazzGuest -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -quiet build`: success. |
| iOS device build | Same project with `-destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`: success after the event-handler changes. This is an unsigned build, not a physical-device run. |
| Simulator launch | Installed and launched the app on iPhone 17 / iOS 26.5. The keyless guest view loaded Jazz's mobile handoff page. |
| Keyless guest prejoin | XCUITest loaded the user-supplied invite in `WKWebView`, chose “Continue in browser”, and found Jazz's guest name field. Screenshot also showed microphone and camera disabled on prejoin; WebKit prompted for microphone permission. This proves the website path reaches prejoin without an SDK key, not that it has joined a live conference. The live invite was passed as a temporary build setting and is absent from source. |
| SDK packaging | First simulator launch failed with a missing `Spench.framework` reported by dyld. The vendor package contains the framework but omits it from its SPM product. The build script now embeds the matching framework; subsequent simulator launch succeeded. |
| URL registration | Opening a `jazzguest://join?url=...` URL in the simulator displayed iOS's “Open in Jazz Guest?” confirmation. Pure link parsing is covered by tests; a full browser-to-join handoff still needs a configured broker and live meeting. |

**Not yet demonstrated**

- Joining a live Jazz meeting, guest admission across organizers, password/lobby behavior and participant rendering. The guest prejoin page loaded with the supplied meeting link, but the Join action was not tested. The native SDK mode still lacks a key.
- Audio/video send state observed by a second participant. Source passes `.allOff`; runtime behavior remains unverified.
- Physical-device background audio, other-app playback, Bluetooth routing, interruption recovery, long-call stability, PiP or camera continuity. An iOS Simulator cannot establish these acceptance results.
- HTTPS Universal Links from an owned domain. No domain or Apple App Site Association file has been selected/configured.
- Signed installation on an iPhone or App Store/TestFlight distribution. The device build was unsigned.

The next meaningful test is a physical iPhone joined to a representative guest-enabled meeting through the keyless web path. Use a second participant to verify incoming and outgoing media, initial mute, Leave semantics, and the interruption matrix in [implementation-plan.md](implementation-plan.md). The native SDK path needs an SDK key kept solely in the broker's environment and should be tested separately.
