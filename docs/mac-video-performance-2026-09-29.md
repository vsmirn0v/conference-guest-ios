# Mac video performance, 29 September 2026

The test used Rock’n’Roll 1.0.0 (17), running as an iPhone app on an Apple silicon Mac with macOS 27. Both clients joined the same two-participant guest meeting and displayed incoming and outgoing camera video. The desktop reference client was measured as a group of its main, renderer, GPU, plugin, and utility processes. CPU percentages are fractions of one logical core; samples are short observations, not energy measurements.

| State | Rock’n’Roll CPU | Reference client CPU |
| --- | ---: | ---: |
| Initial active video samples | 149–207% | About 40–60% across processes |
| Later active video samples | 69–109% | About 45–65% across processes |
| Rock’n’Roll camera off, meeting retained | 17–19% | Not compared |

Rock’n’Roll’s physical footprint was 406 MB during one active sample; its observed peak was 684 MB. The reference client’s processes occupied roughly 700–800 MB in `top` during the same meeting. Those memory figures use different accounting methods and include potentially shared pages, so they do not establish a memory advantage for either app. Comparing only the reference client’s main process would omit most of its work.

The camera-off result identifies outgoing camera capture and encoding as the dominant source of Rock’n’Roll’s extra CPU in this test. It does not isolate capture, format conversion, and encoding individually. A 12-second stack sample placed little time on Rock’n’Roll’s corrected incoming-frame conversion; much more activity appeared in the SDK’s WebRTC encoder and macOS camera pipeline. The bundled SDK’s public settings expose no camera resolution, frame-rate, codec, or encoder selection.

A prototype stopped drawing the SDK’s video surface on every frame while the corrected display layer covered it. Ten frame tests and the iOS 17.5 color UI test passed. In a 720p, 30 fps iOS 17.5 simulator fixture, median app CPU was about 93% with normal SDK drawing and 97% with the prototype. This did not demonstrate a useful CPU improvement. The prototype was removed; no video behavior or quality setting changed.

The next meaningful optimization requires a supported capture or encoder control from the guest SDK, followed by a matched active-call comparison of frame rate, resolution, codec, CPU, memory, and video quality. A separate Mac media engine is a larger alternative if that control remains unavailable.
