# Silent Home calendar refresh

Baseline: `b252236` / 0.2.0 (93).

Home no longer inserts a temporary “Checking calendar…” card above Join.
The unused placeholder view is removed rather than hidden with a spacer.
The calendar scan continues unchanged; actual imminent meeting and handoff
cards remain visible. Full agenda/settings still explain loading, permission
and error states. Existing resolved rows survive refresh, and interaction
protection still defers structural changes while typing, touching or scrolling.

A genuine newly discovered imminent meeting can still appear when Home is
idle. This change removes loading-only insertion/removal, not useful meeting
suggestions. Later-only metadata enrichment retains the Join/favorite geometry.

GPT-6 Astra ultra planned and reviewed the minimal production change.

## Evidence

The delayed empty-calendar regression reproduced the original loading card and
163-point Join/favorite jump in both English and Russian. With the fix, both
languages pass no-placeholder, visible-favorite and unchanged-frame assertions;
the test additionally opens the agenda and verifies the completed empty scan.
The English empty-state test literal was corrected to its existing localized
value during qualification.

Older delayed-imminent/countdown assertions assumed that the removed card
reserved space. They were separated into later-only metadata stability,
genuine imminent discovery with typing protection, and bottom countdown
placement/cancellation. This does not reintroduce a placeholder or defer real
suggestions behind an extra tap.

Final qualification and publication are recorded in the build 94 release note.
Raw logs, screenshots and xcresults are retained under ignored
`.build/calendar94/`. No physical iPhone check is required for the removed Home
placeholder; audio, video, background behavior and permissions are unchanged.
