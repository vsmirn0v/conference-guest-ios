# Local camera preview mirroring

Self preview uses a mirror on front-facing cameras and cameras whose position
is unspecified, including Mac cameras. Rear-facing cameras retain the scene's
natural orientation. Incoming video and screen shares are never mirrored.

`CameraPreviewPresentation` supplies the shared policy and image-layer transform.
Reflection follows rotation, so it remains horizontal at 0, 90, 180 and 270 degrees.
Only the image layer changes: captions, controls, dimensions, normalized samples,
encoded ordinary-camera frames remain untouched. No additional frame
conversion, pixel copy or capture session is introduced.

The policy applies to private preview, live Studio preview, local gallery/stage
tiles and self-video PiP. Guest capture-device notifications refresh presentation
even when switching preserves the renderer identity. Jam camera selection refreshes
the call view after changing the capturer while checking the current room again.

## Verification

- Simulator: 69 selected tests, 9 expected hardware/opt-in skips, no failures.
- Mac: 38 selected tests, 2 expected opt-in skips, no failures.
- iVitalii, iOS 27.0.1: four presentation regression tests and one real guest
  camera UI test passed. Private and live front/rear previews produced images;
  switching twice restored the front camera. The test stopped video and left.
- Regression coverage verifies mirror policy, horizontal reflection at every
  frame rotation, unchanged view/image geometry, remote/share exclusions, and
  actual capture-device notification invalidation of stage/gallery/PiP state.
- Read-only architectural review found no remaining blocker. LiveKit's pinned
  renderer composes rotation and reflection in the same order.

Evidence is local under `.build/camera-mirror/`: `simulator-final.xcresult`,
`mac-final.xcresult`, `device-final.xcresult` and exported UI attachments. The first
device UI attempt could not reach an off-screen Flip camera control; the corrected
test scrolls the settings list and passes. Screenshots are not committed.

Background camera qualification predates this presentation-only correction:
see [physical-device findings](background-camera-device-fix-2026-10-10.md).
This pass does not add a physical iPad result or a new interruption/energy claim.

## Presenter camera reflection

Presenter has a separate, persisted Mirror camera image setting, enabled by
default. Its reflection belongs to the camera image inside the composed canvas,
so the preview and published sample agree. Camera rotation precedes reflection.
Instrument framing crops before reflection; person cutout applies its mask before
reflection. Slides, shared screens, background, annotations and placement remain
unchanged. The existing Core Image composition performs the reflection in its
single output render; no second pool, output buffer or segmentation request is
introduced. Native macOS Presenter Overlay remains owned by the system.

Presenter checks passed on Simulator (40 tests) and Mac (36 tests). Coverage
checks all camera layouts, unchanged background/drawing caches, mask reuse and
failure privacy, and preference persistence. Evidence is local under
`.build/presenter-mirror-effects/`.

Ordinary camera publication follows the conventional behavior: self preview is
mirrored while receivers see the natural image. This differs deliberately from
the explicitly selected shared Presenter camera reflection.

## Mac system-effect orientation: unresolved capture-level mismatch

A local-only AVCapture diagnostic reproduced the sideways thumbs-up graphic
before any SDK frame delegate, scaler, renderer or encoder. On the built-in
MacBook Air camera, the wide-view capture plan selected 1080×1920; the native
preview connection requested 90°. Both setting `videoRotationAngle` and setting
the equivalent legacy `videoOrientation` produced the same upright 1920×1080
scene and sideways effect. New reaction intervals were observed through KVO;
both cases delivered frames and image attachments in the final 12.7-second run.

The 1920×1080 sensor-format alternative produced narrow portrait framing after
the orientation correction, so it was rejected. Earlier cells lacking a new
reaction interval were inconclusive and are not counted as successful fixes.
A whole-frame rotation cannot correct an effect's orientation relative to the
scene. No production capture-angle or format changes were made from this probe.

`MacCameraEffectsTests` is an opt-in diagnostic, not an automatic visual
correctness test: its captured attachments require inspection. Run with
`TEST_RUNNER_ROCKNROLL_TEST_MAC_EFFECTS=1` using the Mac destination. It requires
camera permission, keeps evidence local, never opens a meeting or microphone,
and stops capture/restores the selected format. Final evidence:
`.build/presenter-mirror-effects/mac-effects-face.xcresult` and `face-attachments`.

A separate signed native macOS diagnostic captured upright 1280×720 at 24 fps
with the same built-in camera, native DAL device, position unspecified and a
0° connection. Its final capture saved four frames, advanced 161 frames and
stopped in 7.5 seconds. A main-thread reaction request after three seconds of
advancing video produced no observed reaction interval or visible graphic, so
the native path's effects remain inconclusive. Evidence is local at
`.build/presenter-mirror-effects/native-probe/evidence/2026-10-10T14-54-46Z-A0BF5650`.
The diagnostic was unregistered from Launch Services afterward.

Earlier native diagnostic attempts are not acceptance: an explicit team
entitlement required a provisioning profile and prevented startup; it was
removed while preserving the development certificate, team signature, camera
entitlement and hardened runtime. The first launched diagnostic stalled before
its late/main-queue watchdog, and was terminated. The corrected diagnostic arms
an independent process exit and kernel alarm before discovery. Its High preset
also overwrote the requested format; the final run used the native 720p preset
and reapplied cadence after startup. No security protections were bypassed.

A shipping native camera backend would require supported packaging, exclusive
camera ownership, frame transport and per-engine lifecycle validation; existing
in-process Mac bridges do not provide that isolation. No such backend or system
effects correction has been implemented or qualified in the app.

## System-background reproduction, 2026-10-23

The reported lake backdrop is rotated relative to the upright person in raw
AVFoundation output on this Mac (macOS 27.0.1), before any WebRTC delegate,
scaler, renderer or encoder. `isBackgroundReplacementEnabled` and
`isBackgroundReplacementActive` both read true. This is reproduction evidence,
not a corrected effect or a passing visual-orientation regression.

The opt-in `MacCameraEffectsTests.testSystemBackgroundGeometryBeforeRTCProcessing`
compares the selected Mac camera's front/back compatibility aliases, manual
1920×1080/1080×1920 formats, default output orientation and native-preview
orientation. A subsequent matrix uses the managed 720p session preset without
assigning `activeFormat`; a final matrix uses explicit full and 1280×720 output
dimensions with automatic sizing/preview-sized buffers disabled. Captured
images continue to show the mismatch. No meeting or microphone is opened.
Frames remain local and must not be committed.

Public scene-geometry rotation returned `UISceneErrorDomain` 101: the current
windowing mode does not allow programmatic orientation changes. Scene
orientation remained portrait and device orientation unknown. A temporary
Mac-only app-delegate orientation mask also left the scene in portrait.
`UISupportedInterfaceOrientations~mac` was ignored by this Designed-for-iPad
runtime: the resolved unqualified key still contained all four orientations.
Both unsuccessful application changes were removed. Apple's documented
[key qualifiers](https://developer.apple.com/documentation/bundleresources/managing-your-app-s-information-property-list)
do not establish that this compatibility runtime resolves the Mac variant.

Completed, bounded Mac capture diagnostics: `.build/system-background108/landscape-scene.xcresult`,
`landscape-delegate.xcresult`, `landscape-plist.xcresult`, `managed-preset.xcresult`
and `explicit-dimensions.xcresult`; exported raw PNGs are under
`managed-attachments` and `sizing-attachments`. These tests prove advancing
frames and active effects; their image attachments require visual assessment.
The initial broad matrix also encountered an unavailable Continuity Camera;
subsequent runs explicitly restrict discovery to aliases of the selected Mac
camera and pass without that source failure. The first attempt skipped before
camera permission was granted and is not runtime effect evidence.

There is no validated production camera correction from this investigation.
Rotating the composed frame would rotate the person together with the backdrop.
Read-only Astra review agrees that native Mac capture remains a candidate,
requiring supported distribution packaging, active-background/reaction visual
qualification, a single camera owner, bounded frame transport, lifecycle tests
and remote reception before integration. Current Objective-C Mac bridges run
inside the iOS process and do not provide native capture isolation. An in-app
background compositor is another possible product direction, but does not
provide access to the image selected in macOS controls.

### Native macOS candidate, 2026-10-23

The next candidate succeeded as a **capture proof**, using a separately signed
AppKit process rather than the Designed-for-iPad process. With the same built-in
MacBook Air camera, both the person and selected lake background are upright in
unmodified 1280×720 samples. A second run also produced an upright thumbs-up
graphic, with a new reaction interval observed through KVO. Background replacement
was both enabled and active. The native DAL device reports position unspecified;
the output connection and native preview reference are both 0°, unmirrored.

Local evidence (contains camera images; do not commit):

| Run | Advancing frames | Saved images | Capture duration | Result |
| --- | ---: | ---: | ---: | --- |
| `.build/native-mac-camera108/evidence/2026-10-23T10-40-29Z-A7927D27` | 122 | 4 | 9.50 s | Upright person and active background |
| `.build/native-mac-camera108/evidence/2026-10-23T10-42-27Z-69D59F0B` | 170 | 4 | 8.36 s | Upright person, active background and visible thumbs-up |

Both runs restored capture configuration, reported the session stopped and
terminated. The diagnostic bundle was unregistered from Launch Services afterward.
The reproducible local experiment is `Experiments/NativeMacCamera`; it opens no
microphone or meeting and makes no network connection. This is not latency,
energy, encoder, remote-reception or app-lifecycle qualification. The earlier
October 10 native reaction result remains inconclusive; these new images qualify
the effect only in this standalone native process on macOS 27.0.1.

Astra's architecture review found no documented supported route for embedding
this native capture process in the existing iOS IPA. Apple's
[bundle packaging](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle)
describes helper tools/XPC services for macOS products, including Catalyst;
the public SDK marks `xpc_session_create_xpc_service` unavailable for iOS.
A framework loaded into the existing process does not change its compatibility
environment. [Apple DTS](https://developer.apple.com/forums/thread/760198)
also advises building libraries for their actual platform rather than relabeling
a different platform's Mach-O.

The supplied JazzSDK, JazzCore, LibSberCast, SDSoup, JazzScreenShareImpl,
JazzSDKScreenShare and Spench artifacts have only iOS device/simulator slices.
Our replacement guest WebRTC also has only those platforms. LiveKitWebRTC has a
native macOS slice, so a native local encode/decode prototype is possible, but
it does not remove the guest SDK blocker. No production camera correction is
enabled and no beta was published for this experiment.

The smallest further steps are a native WebRTC encode/decode loopback and a
minimal Catalyst capture probe. Retaining the proprietary guest wrappers then
requires vendor-compatible Catalyst/macOS binaries; an independently implemented
guest engine is another, larger route that removes that dependency. If Catalyst capture also
miscomposites, a Catalyst host with a native XPC capture service needs separate
camera/effect ownership and distribution validation. All paths must retain one
camera owner, bounded frame buffering, timestamps/color metadata, drain/cancel
behavior and remote-engine lifecycle regression coverage before release.

### Guest rebuild and official Web/Electron package audit

The earlier `Experiments/GuestSDKRebuild` did not recover/rebuild the whole SDK.
REA/Ghidra identified the old WebRTC audio shutdown behavior; matching open-source
WebRTC was rebuilt with our patches and an Objective-C compatibility boundary.
The pinned proprietary signaling/UI wrappers stayed unchanged. This technique
can provide native Mac WebRTC, but does not by itself port those wrappers.

Inspected the public npm `latest` artifacts for `@salutejs/jazz-sdk-web`,
`jazz-sdk-web-plugins`, `jazz-sdk-electron` and `jazz-sdk-electron-plugins`, all
version `26.11.23` as returned by the registry on this inspection. Tarballs were
downloaded and their SHA-512 integrity verified without installing or running
them. Metadata and extracted files are local under `.build/sdk-mac-feasibility`.
The four archives contain JS, TypeScript declarations, documentation and licenses;
the Web plugins also contain `orbbiegl-jazz.wasm`, data and worker assets for video
effects. None supplies native conferencing frameworks or Catalyst/macOS slices.
The Electron packages wrap Web SDK/Electron APIs; their extra declared dependency
is `systeminformation`. The installed Jazz Mac app is Electron-based; the native
add-ons found are remote-control modules, not a standalone guest SDK.

The official [Web plugins](https://developers.sber.ru/docs/ru/jazz/sdk/web/plugins/overview)
and [Electron integration](https://developers.sber.ru/docs/ru/jazz/sdk/electron/integration)
are useful implementation references, not replacements for missing native
frameworks. The published Web bundle includes Jitsi/XMPP and browser media APIs;
running it in JavaScriptCore would require a substantial browser/WebRTC bridge,
not just loading a JavaScript file. A WebKit/Electron host can supply that runtime,
but would change media ownership and needs separate performance/feature evaluation.

The recommended independent experiment is a narrow guest protocol adapter feeding
our native Mac WebRTC: authorized guest bootstrap, roster, incoming audio/video,
then outgoing camera/audio and sharing. Do not assume standard Jitsi signaling.
Older browser discovery used a different envelope, but the current official Web
package also includes the same `media-in`/`media-out` family observed in the
native SDK. Discover/validate the selected server backend and preserve password,
lobby and authorization behavior. Existing `NativeRTCPeer` is reusable
design/code, but its iOS camera/UI dependencies still need a real Mac port.

Progression gates: receive and publish real media with upright native effects;
then mute ownership, late tracks, reconnect, source replacement and teardown;
then reactions/chat/lobby/presenter parity and CPU/energy comparison. A successful
media prototype is not full SDK replacement qualification. Rebuilding all opaque
frameworks from decompiled output is not the recommended first approach.

Follow-up inspection found `createRtcApiClient` in the published Web bundle:
`rtc:offer`, `rtc:answer`, `rtc:ice`, `rtc:track:add`/`addTrackRequest`, publication
acknowledgment matching by `cid`, mute, subscription and track-setting messages.
The exported `withAnonymousJoin({ userName })` adapts the join request. These are
concrete references for a native adapter; they do not prove a complete native
join or applicability to every server deployment. The bundle contains both this
transport and Jitsi, so actual backend selection remains an acceptance gate.

REA 6.4.0 / Ghidra 12.1.4 was reused for fresh static analysis of the unchanged
JazzCore ARM64 binary, SHA-256
`886013128024ae2a7166957373b90065d06497cd217ddeca54f1b60fe2841d11`.
Evidence is local under `.build/sdk-mac-feasibility/rea-jazzcore-analysis.json`,
`rea-jazzcore-macho.json` and `rea-camera-start-function.json`. The overview
identifies 13,902 procedures. The decompiled `VideoCaptureController::startCapture`
at `0x13989c` references the React Native WebRTC iOS capture controller, selects a
device/format, calls `startCaptureWithDevice:format:fps:completionHandler:` and
waits on a dispatch semaphore. This is a useful recoverable boundary, not a
recovered buildable vendor source tree; decompiler ownership/type warnings remain.

REA's direct artifact/Mach-O inspection does not accept the SDSoup static archive.
Read-only archive inventory identifies 323 object members there, 14 in
JazzScreenShareImpl and 2 in JazzSDKScreenShare. JazzSDK, JazzCore, LibSberCast and
Spench are dynamic Mach-O libraries. Any deeper static-archive analysis must first
extract selected object members into a separate scratch directory. Vendor files
were not modified or executed by this analysis.

### Shipping Presenter audit, 2026-10-23

Person cutout is already the default in `PresenterScene`, introduced by
`2f6500e` for build 103. `PresenterModel` restores a valid saved
`presenter.layout.v1`; missing or unknown values retain cutout. Existing camera
card, cutout, instrument and beside choices are preserved. Camera inclusion and
publication still require their own explicit actions. No preference migration or
forced layout change is needed. The running Mac app's sandbox preference file
was protected by macOS, so its current saved/in-memory selection was not read or
changed by this audit.

The shipping guest Presenter reuses `CameraCapturePreview.frames` when the call
camera is active, including its system effects and capture rotation. Its private
camera instead supplies `PrivateCameraPreview` output. Both enter the same
compositor: rotation applies to the complete camera image, followed by optional
camera reflection and placement. The Presenter canvas, slides and drawings have
no transform that independently rotates a system backdrop. A sideways backdrop
relative to an upright person matches the raw capture mismatch established above;
rotating this input would also rotate the person. No new live Presenter visual
reproduction was run in this audit.

The installed public AVFoundation SDK exposes the application's user-selected
background-replacement state and a device's active state as readonly properties;
it supplies no separate backdrop pixels or per-output background bypass in
`AVCaptureOutput`. A Presenter-only system-background correction has not been
implemented. The standalone native capture result remains a candidate for a
separately packaged native engine/capture owner, with transport, lifecycle and
remote-reception acceptance still required. App-owned Presenter cutout continues
to use its existing Vision mask and privacy-preserving failure behavior.

Focused preference regression coverage now checks the fresh/unknown default and
every saved layout across restart without enabling camera or publication. On Mac,
24 selected model, compositor and guest frame-feed tests passed with no skips or
failures, using synthetic pixels and senders. Evidence:
`.build/presenter-defaults108/mac.xcresult`. This is not a live system-background
orientation acceptance result.
