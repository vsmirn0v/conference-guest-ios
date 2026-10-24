# Menu-bar calendar suggestion

The idle Mac menu previously filtered out every event whose start was before the current instant. At 13:01, it therefore offered the 14:00 meeting even when a resolved 13:00–14:00 event was displayed on Home.

`CalendarMeetingStore.suggestedMenuMeeting` now selects the earliest eligible resolved occurrence whose end is still in the future, with a stable occurrence-ID tie-break. Ongoing meetings therefore precede later meetings. An active automatic-join countdown keeps precedence. The skip label is computed for the displayed occurrence, and skipping automatic attendance preserves manual Join. Existing join-action freshness and active-call guards remain.

The regression exercises out-of-order events, selection one minute after start, actual Join dispatch, automatic-skip state, advancement at the exact end, and an empty menu after both events end. Selected calendar/store/menu suites ran 51 cases each on Mac and simulator, with zero failures (three Mac and one simulator platform/opt-in skips). Read-only Astra review found no blocker.

Local evidence: `.build/menu-suggestion108/menu-mac.xcresult` and `menu-simulator.xcresult`. The directory name is a scratch identifier, not evidence of a published build 108.
