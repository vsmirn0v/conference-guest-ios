# Participant sheet hosting

The guest engine's public custom navigation contract attaches subsidiary panels
as children of its configured container. The previous meeting host was a
full-screen modal above that container, so iPhone/iPad participant sheets were
created underneath the visible meeting. Mac's app-owned participant panel did
not use that SDK route.

The persistent meeting host is now a full-size child of the home container,
and is itself the SDK's configured container. SDK main screens and subsidiary
panels are siblings inside that host. SDK panel dismissal can reset its sibling
accessibility flags without exposing the outer home page. Transport recovery replaces only the
meeting content; logical departure removes only the owned host and dismisses
its actual presented modal, without dismissing the home controller.

To preserve modal accessibility isolation, mount snapshots the preexisting
underlay views' accessibility flags using weak references. Only those views are
hidden from VoiceOver; later SDK panels remain accessible. Recovery preserves
the snapshot, and departure restores each original flag. Recovery status and
Cancel are hidden while the meeting is active.

Astra reviewed recent screen sharing and host/navigation changes. It confirmed
the routing defect and accessibility isolation issue. Both are addressed.
No further substantiated defect was found in the reviewed capture changes.

Regression coverage exercises actual view hit testing, SDK sibling panels,
transport replacement, departure/reuse, accessibility restoration, and the real
SDK participant route with portrait/landscape changes and a controlled network
interruption. The SDK removes its list before its dismissal animation finishes;
the UI test lets dismissal and rotation settle before tapping again.

An iOS 17.5 Simulator run with incoming browser camera video hit a host OpenGL
compiler crash (`com.apple.opengl.cvmDoWork`, `cvmsServerElementBuild`). Panel
qualification on that runtime therefore uses a camera-muted independent browser;
iOS 27 live qualification also receives generated moving camera video. This
Simulator-specific failure does not establish a physical-device defect.
