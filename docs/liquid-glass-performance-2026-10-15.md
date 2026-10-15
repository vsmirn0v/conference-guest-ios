# Liquid Glass qualification measurements

Build 92, MacBook Air, macOS 27.0.1, Xcode/iOS SDK 27. Native regular
`UIGlassEffect` versus the same binary with the DEBUG launch-only opaque
backing. Media defaults and frame rates are unchanged.

## Matched visible scene

Each launch mounts the same production guest stage/dock, warms for three
seconds, then measures 20 seconds of synthetic 10 fps moving frames. There
is no camera, network, live room or audio encoding in this measurement.
The sequence was glass → solid → solid → glass.

| Backing | App CPU, one core | Longest 100 ms main-loop tick | Peak process RSS |
|---|---:|---:|---:|
| Glass, first | 24.94% | 124.0 ms | 163.5 MiB |
| Solid, first | 25.23% | 126.8 ms | 179.0 MiB |
| Solid, repeat | 23.08% | 120.2 ms | 179.0 MiB |
| Glass, repeat | 24.31% | 126.7 ms | 170.5 MiB |

Average CPU was 24.63% with glass and 24.16% with solid, a 0.47 percentage
point difference within the approximately two-point observed run variation.
There is no demonstrated material app-CPU or scheduling regression in this
scene. RSS is each fresh process's high-water mark, including different test
setup histories; it is not evidence that glass saves memory. Retention tests
separately verify a single backing across layout/state/SwiftUI updates.

## Host-side layout/state work

After one discarded warmup batch, each run performs 10,000 six-button state
and layout updates. Means were 313.1/315.3 µs for glass and 307.7/316.8 µs for
solid. The two-run average difference is approximately 0.6%. This measures
UIKit host work, not physical display latency or GPU energy.

## Reproduction

Use the RockNRoll scheme with the installed Xcode developer directory and
`platform=macOS,arch=arm64,variant=Designed for iPad`. Run the following test
selectors, once per fresh process/backing:

- `RockNRollTests/MeetingChromeProfileTests`
- `RockNRollTests/MeetingChromeSurfaceTests/testOptInToolbarStateAndLayoutProfile`

Pass `TEST_RUNNER_MEETING_CHROME_VISIBLE_PROFILE=1` and
`TEST_RUNNER_MEETING_CHROME_PROFILE=1` to xcodebuild. For the opaque comparison,
add `TEST_RUNNER_MEETING_CHROME_SOLID=1`; for glass, use `0` or omit it. Tests
emit `MEETING_CHROME_VISIBLE_PROFILE` JSON and `MEETING_CHROME_PROFILE` lines.
The launch switch is absent from Release.

Raw results: ignored `.build/glass92/chrome-profile-results.json`, the four
`mac-*-profile*.log` files and corresponding xcresults.

## Acceptance limits

These are app CPU/scheduling proxies. They do not establish compositor GPU
cost, sustained real-conference energy, iPhone battery use, or glass-to-glass
latency. The iPhone became unavailable before the planned energy comparison;
no physical energy result is claimed. The implementation keeps glass outside
video/reading surfaces and adds no production timer, display link, media
callback, capture or codec work.
