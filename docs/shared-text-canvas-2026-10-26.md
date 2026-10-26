# Full-canvas text selection — October 26, 2026

## Design and invariants

Select text captures one immutable full-resolution incoming shared frame and temporarily covers the same media canvas, with opaque image pixels and floating regular-glass controls. It does not replace the live renderer or change meeting media subscriptions. The entry is an icon beside View and More. In capture mode the contextual row provides Live, New frame, Fit/Enlarge and More; primary meeting controls remain available. Blank content clears native selection; explicit Live or Escape exits. Source replacement/end leaves the existing snapshot available and labeled. Refresh is explicit, remains single-flight and cannot deliver stale results to a closed preview.

The image and native OCR analysis survive rotation/window resizing. Zoom is relative to aspect fit and reading position is stored in normalized image coordinates. Temporary clamping/letterboxing must not erase the desired reading position. A transient zero-size layout cannot reset the image or leave it offscreen. Fitted aspect-ratio margins are intentional; no additional black header/footer panel is reserved. No continuous image readback, repeated recognition during layout or automatic clipboard writes are added.

On iOS, the regular glass control hierarchy owns semantic foreground content, including the main meeting dock. Both guest and other engine parent surfaces reserve the actual contextual toolbar width and preserve hit testing through wide-layout gaps. Native Mac uses the existing meeting window and native selection/Copy responder chain, with compact content tools at the top. Accessibility uses an opaque semantic fallback when required.

## Review and validation

Astra 6 xhigh reviewed architecture, implementation and acceptance. Review findings addressed before release include full-canvas parent mounting, inline dock/tool overlap and hit-testing, semantic glass content hierarchy, explicit Escape/Fit routing, and retained edge reading position across temporary viewport clamps. Final results and publication are recorded in the release documents.

Required checks include retained owned image/OCR/selection across actual zoomed view resizing, rendered image pixels after orientation changes, no repeated capture/recognition, source ending/replacement and failed refresh, native keyboard selection/Copy, contextual/primary control hit testing including wide inline layouts, and existing call/layout/notification/update regressions.

Physical iPhone is unavailable during this change. Device touch/gesture and real-device glass appearance remain a follow-up; no codec, audio transport, background joining or PiP lifecycle behavior is intentionally changed.
