# Attention — Phase 2 and Phase 3 implementation plan

Plan and design drafts: https://claude.ai/artifact/UUhRwq5uiiYJrsuyvr2FyA (5 Nov 2026).
Phase 0–1 record: `docs/attention-phase-0-1.md`. This document is the work breakdown for
Phase 2 (more audio sources) and Phase 3 (meeting presets and the judge on an API provider),
written against the code as of beta 54 (commit 0cbba16).

## What the code changed in the original plan

1. **Telemost and TrueConf are in-app WebRTC sessions**, not separate apps.
   `NativeDesktopExternalSession` subscribes through `NativeDesktopRTCPeer`; the provider
   sends audio on the subscriber peer. No ScreenCaptureKit capture is needed. Today the peer
   reports only video tracks (`reportTrack` drops audio receivers), so Phase 2 is "surface the
   audio track", not "capture another process".
2. **External audio is mixed by the provider**, so there is no per-speaker track. Speaker
   attribution comes from the provider's own speaking signals (`speaking` per Telemost slot,
   TrueConf roster/device status), which the session already folds into
   `snapshot.participants[].speaking`. Diarization models are not needed for Phase 2.
3. **Rock meetings** (LiveKit SDK) do have one `RemoteAudioTrack` per participant, like Guest.
   They are music by default, so transcription stays off there unless switched on.
4. **Your microphone** is already tapped in `GuestSystemAudio` (the input meter). The same tap
   can feed the transcriber. Only the talk meeting holds physical input, so your words are
   attributed to that meeting by construction.
5. **Presets can attach to existing identities**: a room (`RecentRoom.id`, the invitation URL,
   used for favorites and as the catch-up key) and a calendar series (`CalendarMeeting.seriesID`;
   the join carries `eventID`).

## Recommended order

| Step | Scope | Effort | Why this order |
|---|---|---:|---|
| 2a | Your microphone into the transcript | 3–4 days | Small, needed by the judge ("you already answered") |
| 3 | Presets, judge on an API provider, attention cards | 3–3.5 weeks | The user-visible value; needs no new runtime |
| 2b | Telemost / TrueConf audio with speaker attribution | 1.5–2 weeks | Needs live provider testing; the judge works on Guest meetings meanwhile |
| 2c | Rock audio (opt-in) | 2–3 days | Optional; same sink pattern as Guest |

Total about 6–7 weeks for one person. 2b can start in parallel with 3 if a second person joins.

## Phase 2a — your microphone (3–4 days)

Goal: lines you say appear in Live text and the judge's window as "You", for the meeting that
holds your microphone, while it is unmuted.

- `GuestSystemAudio`: add a second consumer to the existing input tap (next to
  `inputMeter`), guarded by the same lock pattern as `inputMeterEnabled`. No new engine or tap.
- `NativeDesktopMeetingEngine`: `setLocalAudioSink(_:)` with a default no-op; implemented by
  the Guest engine and the external session (both own a `GuestSystemAudio`).
- `MeetingTranscriber.feedLocal(buffer)`: one more speaker keyed `local`, lines carry
  `participantName = displayName` and an `isYou` flag.
- Gate on confirmed state, not on audio presence: buffers are dropped before VAD unless
  `snapshot.microphoneOn` is true and this meeting is the talk meeting. Muting ends the
  utterance (flush) so nothing said while muted is transcribed.
- Setting "Include my microphone" under Settings → Transcription, default on (your words
  already go to that meeting). Per-meeting pause stays one switch for both directions.
- Diagnostics: `local-transcription-stop` gains `micUtterances`, `micSeconds`.

Tests: `LocalTranscriptionTests` (gating by snapshot; mic lines stop when the microphone moves
to another meeting; `feedLocal` end-to-end with the sample utterance), one session scenario in
`run-session.sh` for the talk-meeting move.

## Phase 2b — Telemost and TrueConf (1.5–2 weeks)

Goal: external meetings transcribe locally with sound off, lines carry the speaker's name when
the provider says who is speaking.

1. `NativeDesktopRTCPeer`: report audio receivers (`onAudioTrack(mid, LKRTCAudioTrack)`) beside
   `onTrack`; forget them on close.
2. `NativeDesktopExternalSession`: `remoteAudio: [NativeDesktopRemoteAudio]` (track, no
   participant id) and `onRemoteAudio`. Move `remoteAudio`, `onRemoteAudio` and
   `setTranscriptionOutput` into `NativeDesktopMeetingEngine` with defaults, plus
   `supportsLocalTranscription`. `NativeDesktopMeetingModel` starts the transcriber from the
   capability instead of the `NativeDesktopGuestEngine` cast.
3. `SpeakerAttributor` (ConferenceCore, pure): the model records speaking changes from each
   snapshot as `(participantID, from, to)`; an utterance `[start, end]` gets the participant
   whose speaking interval overlaps it most, when that overlap is at least 60 % of the
   utterance; otherwise the line is unattributed and shown as "Participant". Nothing lexical.
4. Sound off: Telemost's hello sends `quiet: !outputIntent`. Check on a live meeting whether
   the server stops sending audio when quiet. If so, send `quiet: false` while local
   transcription runs and keep output silent locally through `setTranscriptionOutput`, as
   the Guest path does. TrueConf: verify the device-status message carries speaking.
5. Settings → Transcription: per-source switches (Guest, Telemost/TrueConf, Rock, My
   microphone).

Tests: `ExternalEngineProtocolTests` (audio track reported and released),
`SpeakerAttributor` unit tests (single, overlapping, none, late signal), `ExternalLiveTests`
manual acceptance: names on lines, sound-off transcript, no audible leak.

Risks: Telemost quiet flag (item 4); TrueConf may not send a speaking signal, then lines are
unattributed until a diarization option exists; mixed audio raises WER on overlapping speech.

## Phase 2c — Rock (2–3 days, opt-in)

`RemoteAudioTrack.add(audioRenderer:)` per participant in `NativeDesktopRockEngine`, mapped to
the same `remoteAudio` shape with the participant identity. Off by default per the Rock
switch.

## Phase 3 — presets and the judge (3–3.5 weeks)

### 3.1 Data (ConferenceCore, Codable, Sendable) — 3 days

- `MeetingPreset`: id, title, bindings (`.room(invitationURL)`, `.calendarSeries(seriesID)`),
  about, matters, people, never, urgency (quiet/normal/eager), threshold adjustment,
  allowed actions (open, chat, reaction; chat/reaction drafts arrive in Phase 5), examples.
- `PresetExample`: at, verdict, decision (approved/declined), declineReason, excerpt, reason.
  Ten most recent are shown to the judge; fifty are kept.
- `AttentionProfile`: name, aliases, role, default threshold.
- `MeetingPresetStore`: JSON in Application Support/Attention, atomic writes, persistence
  warning like `CatchUpStore`. Resolution for a meeting: room invitation (also
  `latestInvitationURL`), then the calendar series of the join's `eventID`, else none
  (profile only). Cross-device sync is deferred; the document shape allows a later
  `RoomSyncDocument` field.

### 3.2 Window builder (ConferenceCore, pure) — 3 days

`AttentionWindow` from the meeting model: last 3 minutes (cap 60 lines) of transcript with
speaker, `isYou`, time; chat messages; reactions; roster joins/leaves since the last tick;
your state (microphone, sound, on screen); lines that contain the profile's name or aliases
(string containment on the user's own data, nothing hardcoded). `fingerprint` hashes the line
ids so an unchanged window is never judged twice. Sources already exist: `transcript`
(service + local), `chat`, `chat.reactionHistory`, `snapshot.participants`.

### 3.3 Judge contract and the first provider — 5 days

- `AttentionVerdict`: attention (no/soon/now), probability, reason (two sentences at most),
  evidence (line ids), suggestedAction (none/open/chat/reaction).
- `protocol AttentionJudge { func judge(_ request: JudgeRequest) async throws -> AttentionVerdict }`
  with `JudgeRequest` = window + preset + profile + examples.
- `OpenAIChatJudge`: POST `{base}/chat/completions`, `response_format` JSON schema (strict),
  temperature 0, 20 s timeout, two retries on 5xx/timeouts. Validation: evidence ids must be
  in the window, probability in range; otherwise the verdict is rejected and counted.
- Prompt order is fixed: system rules → preset → approved examples → declined examples →
  window → the four questions. Russian and English system text.
- `AttentionProviderConfig`: name, base URL, model, extra headers, key reference. The key is
  stored in the Keychain with the `KeychainRoomHistoryStorage` pattern (service
  `dev.vsmirn0v.conferenceguest.attention`). Presets: OpenAI, OpenRouter, LAN (Ollama,
  LM Studio, vLLM; no key). JEV fits the same contract and is a later adapter.
- Nothing is logged but counts, latency and status codes; a test asserts the key never
  reaches `probeLog` or diagnostics exports.

### 3.4 Scheduler (`AttentionCoordinator`, workspace level) — 4 days

- Eligible meeting: connected, transcribing (service or local), and not the meeting on screen
  in a key, visible window. Everything else, including the on-screen meeting while the window
  is hidden, is judged.
- Tick every 20 s per eligible meeting when its fingerprint changed; immediate tick on a
  trigger: your name or alias in a new line or chat message, a direct chat mention, a
  participant leaving.
- One judge call in flight across meetings; budget of six calls per minute by default.
- Hysteresis: "now" holds two minutes or until you act; a card never repeats for the same
  evidence set; "soon" may escalate to "now".
- `AttentionDecision` records (window, preset id, verdict, provider, latency, your action,
  decline reason) as JSON lines under Application Support/Attention/decisions, kept 30 days.
  No audio is ever stored.
- Global switch, per-meeting pause, optional "not on battery".

### 3.5 UI — 6 days

- Attention card in the meeting view where the transcription announcement sits; at most two
  stacked. Actions: Open, Dismiss (soon), Decline (inline strip: not urgent / wrong meeting /
  I already know / other), Why.
- Sidebar: red dot and "now"/"soon" badge in `NativeDesktopSidebarMeetingRow`; an Attention
  section listing the latest verdict per meeting (quiet meetings are visibly judged quiet).
- Decision inspector sheet: reason, evidence lines (focusing them in Live text the way
  `catchUpFocus` does), preset rules applied, examples used, provider and latency, "This was
  wrong", "Copy for support".
- Preset editor sheet from a favorite's context menu, a calendar series row, the meeting
  toolbar menu ("Instructions for this meeting") and the card's Why.
- Settings → Intelligence (tag 6): profile (name, aliases, role), judge provider form with
  Test (sends a fixture window and shows the parsed verdict), global switch, battery option,
  and the line "What leaves this Mac" naming the provider.
- Russian and English strings in both Localizable files.

### 3.6 Feedback loop — 2 days

Open from a card stores an approved example; Decline stores a declined one with its reason,
on the meeting's preset (auto-created for the room when none exists). Each decision moves the
preset threshold by 0.05, bounded to 0.30–0.80. Examples are visible and deletable in the
editor.

### 3.7 Replay harness — 2 days

`Experiments/AttentionBench/replay.py` re-runs stored decisions through a provider and reports
agreement with your approve/decline choices. This is how prompts are tuned without sitting in
meetings.

### Phase 3 acceptance

- Two meetings for an hour, one muted: a direct question to you in the muted meeting shows a
  card within 30 s; no card repeats for the same lines; Decline is stored and visible in the
  editor; Open switches the meeting.
- Settings Test works against the chosen provider; a wrong key or an offline provider shows
  one status line and nothing else breaks.
- Key never appears in logs or diagnostics exports (test).
- CPU: the judge adds no measurable load; cost at worst about three calls a minute at
  roughly 1.5k tokens each.

Tests: ConferenceCore unit tests (preset store, resolution, window builder and fingerprint,
verdict validation, scheduler state machine with a fake judge); Mac parity tests (coordinator
with the fake judge, card and badge state, settings round trip); provider client against a
`URLProtocol` stub; session scenarios unchanged.

## Decisions needed before starting Phase 3

1. The first judge provider: an OpenAI-compatible endpoint with your key, OpenRouter, or a
   LAN server (Ollama, LM Studio, vLLM).
2. One recurring meeting to write the first preset for and tune on.
3. Whether the on-screen meeting is ever judged (plan: only while the window is hidden).
4. Microphone transcription default on (plan: on).
