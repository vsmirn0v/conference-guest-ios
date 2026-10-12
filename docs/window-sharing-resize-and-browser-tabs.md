# Window resize and browser-tab sharing

## Resize fix

The Mac app's single-window capture configured its dimensions only when the
selection started. ScreenCaptureKit keeps that output surface size when a window
resizes. The app also forwarded its full sample buffer, so an obsolete aspect
ratio could reach both preview and publisher.

Both app-owned capture paths now share a resize controller in
`MacScreenCaptureBridge`: the macOS compatibility path and UIKit capture running
on a Mac. This covers the guest, Telemost and TrueConf screen sources and their
Presenter inputs. The separate LiveKit room capturer already crops each frame to
its content rectangle; it is not replaced by this change.

- Read complete-frame `contentRect`, `scaleFactor` and `contentScale` metadata.
  Source pixels are `contentRect.size * scaleFactor / contentScale`.
- Fit native pixels within 1920×1080, preserve aspect, use even codec dimensions,
  and avoid upscaling small windows. Initial configuration uses the same sizing.
- Coalesce to one newest size with a 350 ms delay and serialize public
  `updateConfiguration:completionHandler:` calls. Keep the same stream/sender.
- Retire scheduled work and completions on Stop or source replacement. Ignore
  blank/idle/minimized samples and invalid geometry. A resize error keeps the
  existing capture rather than ending the meeting.
- Capture/update uses only public macOS selectors through the existing ABI
  adapter because UIKit's declaration marks stream updates unavailable on iOS.
  The phone never loads this macOS framework; no phone window-resize path is added.

Apple explains the fixed output-surface behavior and warns against reallocating
on every resize frame in [Take ScreenCaptureKit to the next level](https://developer.apple.com/videos/play/wwdc2022/10155/).

## Qualification, October 12, 2026

- iOS 27 and iOS 17.5 simulators: 16 selected capture/preview tests on each,
  15 passed and one expected real-Mac-picker skip, no failures. Tests cover
  native scale recovery, aspect/bounds, no upscaling, coalescing, serialized
  updates, stable frames, invalid geometry and retired callbacks.
- Isolated real Mac capture on macOS 27.0.1, using the production resize
  controller and metadata parser: 61 frames; four settled dimensions observed:
  1536×1080 → 762×1080 → 1920×770 → 1100×764. Capture stopped successfully.
- Signed Mac Release build passed. The user's active TestFlight meeting was
  neither relaunched nor joined by the probe. No end-to-end room receiver check
  was repeated in this qualification.
- Evidence is local in `.build/window-resize/`. Initial probe attempts timed
  out at selection, and the consent-free current-process enumeration produced
  no complete frames; only `probe-picker-final.log` is successful live evidence.
- This is a source fix after build 75, not a new TestFlight upload.

## Browser-tab feasibility

The public native picker offers display, application and window selections,
[not a tab selection mode](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpickermode/singlewindow).
Moving a tab to its own browser window is the immediate cross-browser approach.
It includes browser chrome and follows whichever page is displayed in that
window, so changing its tab changes the shared content.

Chrome exposes [tabCapture](https://developer.chrome.com/docs/extensions/reference/api/tabCapture)
to an explicitly invoked extension: a genuine tab video/audio stream, retained
across page navigations. Integrating it requires an optional extension plus an
authenticated local media bridge to the existing publisher. A Chrome stream ID
cannot be consumed directly by the native app.

No equivalent supported Safari tab-stream API was found in Apple's extension
compatibility documentation. Screenshot polling should not be presented as
equivalent tab streaming: it adds permissions/work, sacrifices cadence, and
does not provide the same audio/hidden-tab semantics. Prefer a dedicated window
for Safari; investigate a Chrome extension separately if true isolated tab
sharing is requested. No browser extension or tab-sharing feature is added here.
