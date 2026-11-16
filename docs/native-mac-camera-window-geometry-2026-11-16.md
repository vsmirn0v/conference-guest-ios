# Native Mac camera fixture geometry warnings

The granted camera test passed on macOS 27.2 build 26B123. Xcode reported two unique runtime warnings, `Invalid view geometry: width is negative.` and `Invalid view geometry: height is negative.` The six underlying events occurred from 18:12:25.105858 to 18:12:25.139707 local time (UTC+03) in PID 71182, before the camera permission result and first frame.

The unified log recorded the events under `com.apple.runtime-issues`, category `AppKit`. Symbolication of AppKit image UUID `77E3ADB8-E4E8-3912-8599-D43182877C10` placed all six in the window title bar's sharing indicator.

```text
_NSViewValidateGeometry
NSViewValidateSize
-[NSView setFrameSize:]
-[NSThemeFrame _positionSharingIndicator]
```

The first four events followed a selective-window-sharing notification through `-[NSWindow _setIsSelectivelyShared:]` and `-[NSWindowSharingSessionRecipientIndicator invalidateIntrinsicContentSize]`. The final two came from `-[NSThemeFrame layout]`. These paths identify the AppKit title bar as the source of the negative dimensions. The logs do not identify the process that initiated sharing.

The granted run recorded authorization, appearance of the live preview after the first frame, and removal of the preview on stop. The final denied run recorded denial, no preview surface, and actionable permission guidance with zero runtime warnings. The camera and settings source required no geometry change.

The original results are `.build/camera-permission-validation/granted.xcresult` and `.build/camera-permission-validation/denied-final.xcresult`. Extracted summaries, timestamped unified-log backtraces, and symbolicated AppKit frames are in `investigation/2026-11-16-camera-window-geometry/`.
