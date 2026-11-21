# Meeting assistant: design draft (6 Nov 2026)

Drafts: https://claude.ai/artifact/FKSAEa7g3Y88xvzMKkXawf (eight boards, private).
This note holds the reasoning behind them and the mapping onto today's code.

## What is wrong today

- A card appears over the home window, vanishes when you look at the meeting, when
  the meeting closes, or two minutes after a "now" verdict. Nothing lists what you
  missed; an expired card cannot be acted on.
- One switch for the whole feature, plus a per-meeting pause buried in a context
  menu and an urgency slider inside the preset editor. The judge polls every
  meeting you are not looking at, whatever its state.
- One drafted reply, one channel at a time.
- The "judge" is a backend name leaking into the UI; nothing to talk to.

## The model

### Attention modes

One per meeting, three values. They replace `enabled` + `paused` + `urgency`.

| Mode | Triggers the judge | Shows |
|---|---|---|
| Off | never | nothing; transcription and notes still run |
| Mentions | at once on a local name/alias hit or a question put to you (named, or in a two-person call); otherwise every 2 min | any qualifying card when you were named or asked; otherwise only `now` ≥ 0.8 |
| Watch | everything above plus the 20 s cadence on changed windows, preset threshold | Now and Soon |

Resolution, first match wins:

1. Your override for this meeting (until you leave, 30 min, or "always for this
   series", which writes 2).
2. The series or room default (`MeetingPreset.mode`).
3. The situation default: on screen / background with sound / silenced. Three
   pickers in Settings → Assistant. Shipped: Off / Watch / Mentions.

The situation is read from `isOnScreen` and `snapshot.playoutOn`, so the mode
follows the meeting as you silence it or bring it forward. The chip in the sidebar
row and the Assistant button in the control bar show the resolved mode and open
the same popover; ⌃⌥A cycles it for the selected meeting; "switch standup to
mentions" does it by voice.

### Moments and history

A judged window that qualifies is a *moment*. Moments live in a store, not only on
screen: `AttentionDecisionRecord` already has them; the UI adds a state machine
per moment: live → missed (hold expired or crowded out) / answered (replied,
reacted, spoken, opened) / dismissed / not for me. The Assistant sidebar section
lists them (All / Live / Missed / Answered), badge = live + missed unseen.

A missed moment keeps its actions: reply in chat, say it, open, remind me, plus
"Since then", a summary of transcript and chat after the moment, generated on
demand by the writer provider. Quiet checks show as one collapsed line per meeting
so the inbox also says "it looked, nothing for you".

On screen: at most two cards; the rest show as "+N in Assistant".

### Reply variants

The writer returns up to three variants with a stance label (confirm / ask for
time / hand off / decline …) instead of one `ReplyDraft`. The card marks the
variant ranked first by your history ("your usual"), the chosen text is editable,
and each goes to chat (⌘↩), to voice (⌥↩) or as a reaction. "More…" asks for a
redraft with a hint (shorter, in English, firmer).

### Talking to the assistant

- Push-to-talk (hold ⌥ Space) or a typed line in the Assistant panel. Wake word is
  a later option, on-device, opt-in.
- While you hold the key the microphone is held back from the meeting the same way
  "Say it" holds it; the words go to the local transcriber only.
- The transcript becomes a typed command through a structured LLM decision
  against a command schema: `setAttention(meeting, mode, scope)`, `join(meeting)`,
  `leave`, `mute`, `sendChat(meeting, text)`, `say(meeting, text)`,
  `react(meeting, reaction)`, `readChat(meeting, n)`, `catchUp(meeting, minutes)`,
  `remind(moment, at)`, `remember(fact)`. No keyword or phrase lists in production
  code, per the workspace rule.
- Outward actions (send, say, react, leave) render a confirmation card first;
  "send without asking" lifts that for the rest of the meeting. Mode changes and
  reads apply at once.
- Answers are text in the panel and, optionally, spoken into your headphones, never
  into a meeting.
- Every command is also a button or a keystroke; the panel works without voice.

### Meeting outcomes

When you leave a meeting, or it ends, the writer turns its transcript and chat
into an *outcome*: a short summary, the decisions, the tasks (who said they would
do what, by when), and what stayed open. Nothing is sent anywhere; it is kept with
the room's history and editable line by line.

- Your tasks are offered as reminders (the existing Reminders tab) with one
  click; the row shows when a reminder is set.
- The next occurrence of a series shows "Last time: …" on its home card and in
  the join window, with the state of your tasks.
- Series pages stack occurrences, so "what did we decide about X" can be asked
  across weeks, by voice ("что я обещал на инфра-синке?") or in the panel.
- The memory's meeting store reads from outcomes (topics, decisions, your
  commitments), so attention and replies get better from what was agreed, not only
  from what you clicked.
- "Copy as text" and "Send to the meeting chat" share the outcome deliberately;
  nothing goes out on its own.

### Memory and learning

Three stores, all local, all visible and editable in Settings → Assistant → Memory:

- People: how they address you, their role, how you usually answer them.
- Meetings: the series' default mode, topics that reached you, hit rate, usual
  reply channel.
- You: role, reply style, preferred stance, quiet hours.

Inputs: card outcomes and decline reasons (exists), reply edits (exists), reply
variant picks, mode switches, "remember that…" by voice.

Outputs: the preset threshold and variant ranking adjust silently (threshold
tuning exists). Everything else is a suggestion in "This week I noticed", kept
or dropped by you: a series default after three repeated switches, "stop raising
X unless asked" after repeated "already known", your wording replacing a
variant. Before judging or writing, the 3–5 most relevant past moments and your
replies for the same series and people are retrieved on-device and added to the
prompt as examples.

The assistant never sends, leaves or changes a mode on its own.

### Name

Working name "Roadie": the crew member who runs the stage so the band can play.
"Assistant" stays as the generic label in chrome; the name appears where you talk
to it. Easy to change later; the tab and section titles do not depend on it.

## Decisions (6 Nov, review)

- On screen defaults to Off.
- The moments history is a sidebar section with a badge, one list across meetings.
- Answers are text only by default; talk-back is a Settings → Voice option.
- The persona name "Roadie" stays where you talk to it.

## Step 1 as built (6 Nov, beta 75)

- `AttentionMode` (off / mentions / watch) and `AttentionSituation` (on screen / background /
  silenced) in `AttentionModel.swift`; `MeetingPreset.mode`; `AttentionStore.situationModes`
  persisted per situation (Off / Watch / Mentions by default).
- `AttentionCoordinator.resolvedMode` (meeting override with optional expiry → series/room
  preset → situation), `setMode(scope:)` (until you leave, 30 min, every time), `resetMode`,
  `cycleMode`; the per-meeting pause is gone. `tick()` judges Mentions only on your name or a
  question to you, else every 2 min, and `apply()` holds non-mention Mentions cards to `now ≥ 0.8`.
  Decision records keep the mode and whether you were mentioned.
- Views (`AttentionModeViews.swift`): the chip in each sidebar row, an Attention picker in the
  row's context menu, an Assistant button in the meeting control bar (⌃⌥A), the switch popover
  with "Keep this" scopes, "Attention by situation" in Settings → Intelligence, and an Attention
  picker in a meeting's instructions.
- The judge still says "judge" in Settings; the rename to Assistant comes with the Settings rework.

## Mapping onto the code

| Design | Code today | Change |
|---|---|---|
| Mode per meeting | `AttentionStore.enabled`, `MeetingState.paused`, `MeetingPreset.urgency` | `AttentionMode` enum; `MeetingPreset.mode`; `MeetingState.override` with expiry; situation defaults in `AttentionStore`; `waitingReason` resolves the mode and gates the judge; Mentions skips the 20 s cadence (`tick()` trigger only). |
| Chip and popover | `AttentionBadge`, context menu Pause | `AttentionModeChip` in the row and the control bar; one popover view. |
| Moments inbox | `AttentionDecisionRecord` (30 days) | moment state and seen flag on the record; `AttentionInbox` view; `apply()` marks missed instead of deleting. |
| Since then | — | writer request over the window after `record.at`. |
| Variants | `ReplyDraft` | `ReplyDraft.variants: [Variant(stance, text)]`; writer schema returns up to three; ranking from `ReplyEdit` history. |
| Talk | `MicrophoneHandover`, `VoiceSynthesis`, `LocalSpeechRecognizer` | `AssistantCommand` schema, `AssistantSession` actor, push-to-talk hot key, confirmation cards; talk-back through `VoicePreviewPlayer` on the default output. |
| Outcomes | `RoomHistoryStore`, `CatchUpStore` (gap timeline only), `CalendarReminderRepository` | `MeetingOutcome` record (summary, decisions, tasks, open) written on leave by the writer; `OutcomeView`; reminders from tasks; "last time" on `HomeMeetingCard` and the join window. |
| Memory | `AttentionProfile`, `MeetingPreset.examples/replyEdits` | `AssistantMemory` store (people, meetings, you) with retrieval; suggestions with keep/undo. |
| Settings | Intelligence tab | renamed Assistant; sections Attention, Replies, Voice, Memory, Models, What leaves this Mac. |

## Suggested order

1. Modes, resolution and the chip/popover (changes judging cost and noise at once).
2. Moments inbox with missed state and "Since then".
3. Reply variants and channel choice on the card.
4. Outcomes on leave, reminders from your tasks, "last time" on the next occurrence.
5. Talk: push-to-talk, command schema, confirmation cards; typed first, voice second.
6. Memory stores and the weekly suggestions.
