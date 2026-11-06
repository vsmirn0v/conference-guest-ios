# Remaining phase work — plan as of beta 69 (6 Nov 2026)

Source plans: Attention (https://claude.ai/artifact/UUhRwq5uiiYJrsuyvr2FyA; records in
`attention-phase-0-1.md`, `attention-phase-2-3-plan.md`, `attention-phase-4-7-plan.md`) and
R4 shared audio engine (`r4-shared-engine-plan.md`). The native-Mac parity acceptance ledger
(`native-mac-feature-parity-2026-10-24.md`) lists verification gates, not features; it is
referenced at the end. Checked against the code at `6cfdbae` (beta 69).

## Where each phase stands

| Phase | Built | Not built | Not verified live |
|---|---|---|---|
| Attention 0–1 Listen | Harness, consent copy, sherpa-onnx GigaAM; **beta 66**: GigaAM v3 on the Neural Engine through Core ML as the default model | — | Core ML model download and live transcription |
| Attention 2 sources | 2a your microphone, 2b Telemost/TrueConf (in-app WebRTC audio, speaking-timeline attribution), 2c Rock (opt-in) | — | Telemost/TrueConf/Rock transcription and Telemost attribution |
| Attention 3 judge | Presets, window builder, API judge, cards, sidebar, inspector, replay | Trigger "question then ≥ 4 s silence"; JEV adapter; preset sync across devices | A live OpenAI call; cards in a real multi-meeting session; notifications |
| Attention 4 local judge | 4a Rapid-MLX preset and measurements, 4b local scheduling and guards, 4c learning (threshold tuning, writer examples, repeated-decline rule); **beta 67**: "Apple on this Mac" judge (Foundation Models + on-device ru↔en translation, 40/43 on the Russian bench) | 4d in-process MLX judge; two-tier escalation (cheap judge → strong model when uncertain) | Apple judge in a live meeting; Compare models on real decisions |
| Attention 5 replies | Drafts, send/edit/redraft, reactions, separate writer provider, local-writer gate | Preset-allowed auto-send for a narrow instruction (with audit trail) | Draft quality; Telemost/Rock chat delivery from a card |
| Attention 6 model manager | Pinned Listen catalog (bundled JSON, SHA-256, download, per-model delete); provider form with Test and model chooser; "What leaves this Mac"; Compare models | Roles overview with Local/Cloud badges; storage overview; remote signed catalog; Hugging Face search | A comparison run against a real provider |
| Attention 7 voice | 7a system voice "Say it", 7b Qwen3-TTS through Rapid-MLX | 7c in-process TTS; voice enrollment/cloning | Say it in live meetings |
| R4 S0–S5 | Shared engine, Guest/Telemost/TrueConf/Rock behind the flag, recovery | — | — |
| R4 S6 | Beta 65+ ships the flag (off) | Flag on by default | The eight live checks in `r4-shared-engine-plan.md` § S6 |

Stability work from betas 67–69 that no plan listed: the input-mute alert fix (363fa4a), and no
WebRTC call on the main thread for Guest (d2dc2d5) and Telemost/TrueConf (d7c37fd) peers.

## Remaining work, in order

Effort is one person; each item ends in a beta. Items marked *gated* wait on your live checks.

### 1. Record and verify (now)

- **Docs catch-up** (done with this plan): status for betas 66–69 in the phase records.
- **R4 S6 live checks** — *gated on you*: run the eight checks on beta 69 with the flag on.
  Then: flag on by default (keep the off switch, relaunch note), 0.5 day. Done when a beta
  ships with the flag on and the checks are recorded in the R4 plan.
- **Attention live checks** — *gated on you*: one real multi-meeting session with the Apple
  judge, then Compare models on those decisions (Apple vs Rapid-MLX vs the API model).
  Decides the default "on this Mac" judge. Done when the result is recorded in the Phase 4–7
  plan.

### 2. Freeze and crash follow-ups (beta 70, 2–3 days)

- **Peer creation off the main thread.** `factory.peerConnection(with:)` at join still runs
  on the main actor in `GuestPeer.init` and `NativeDesktopRTCPeer.init`; a stall at that moment
  can still freeze the app. Create the connection on the peer's `GuestNativeCalls` queue and
  make the inits async. 1 day, covered by extending `GuestNativeCallsTests`.
- **Sidebar crash on fast resize** (crash at 16:24, beta 66): SwiftUI tore the home sidebar
  `List` down mid-resize. Reproduce with a scripted window resize; likely fix is keeping the
  `NavigationSplitView` sidebar alive (no conditional removal) during live resize. 1–2 days.
- **Sparkle update path**: install beta 65 and let it update to 70. Half a day of checking.

### 3. Judge quality (beta 71, 3–4 days)

- **Question-then-silence trigger** (Phase 3 leftover): a line ending in a question mark with
  no newer line for 4 s judges at once, like a name mention does. 1 day; fits the existing
  trigger in `AttentionCoordinator`.
- **Two-tier escalation** (Phase 4): the cheap judge on this Mac (Apple or Rapid-MLX) answers
  every tick; when its probability is in the uncertain band (0.35–0.65) the strong provider
  re-judges the same window. Settings: "Escalate to … when unsure". 2–3 days, with the band
  and both results in the decision log so Compare models can score it.
- **Drop 4d** (in-process MLX judge). The Apple judge already runs in-process, sandboxed, with
  nothing to download; Rapid-MLX stays for macOS 13–15 and larger models.

### 4. Model manager remainder (beta 72, 5 days)

- **Roles view**: Settings → Intelligence shows Listen / Judge / Write / Voice, each with its
  provider and a Local / Cloud badge; today they are spread over four sections. 2 days.
- **Storage overview**: models with sizes, delete, total; the per-model delete exists. 1 day.
- **Remote signed catalog** for Listen models: fetch `rock.glowsoft.ru/mac/models.json`
  (Ed25519-signed like the appcast), fall back to the bundled copy; lets a new model ship
  without an app release. 2 days.
- **Defer Hugging Face search.** The pinned catalog with SHA-256 is the safety model; search
  would admit unpinned files. Revisit if someone needs a model the catalog lacks.

### 5. Voice (beta 73, 1–2 days)

- **Personal Voice**: macOS 14+ `AVSpeechSynthesisVoice` personal voices (the user's own,
  created in System Settings → Accessibility) through the existing 7a system-voice path, behind
  the system's authorization prompt. Gives cloning without the Qwen3-TTS port. 1–2 days.
- **Defer 7c** (Qwen3-TTS port, 5–7 weeks) and in-app enrollment unless Personal Voice is not
  enough.

### Status after beta 70 (items 2–5 shipped together)

- **Done:** peer creation off the main thread (Guest and external peers; inits async, join
  and recovery drop a peer created after close). Question-then-silence trigger. Escalation
  ("When the judge is unsure, ask …", band 0.35–0.65, first verdict and model kept in the
  decision log); the escalation provider also stands in when the primary judge errors. Roles
  view with On this Mac / Cloud badges and installed speech-model size. Signed catalog client
  (Curve25519 over the exact bytes with the appcast key, higher revision only, every model
  pinned) plus `distribution/sign-catalog.py`. Personal Voice as a reply voice. The Apple
  writer can now draft (it was blocked by an endpoint check). A failed ru→en translation now
  judges in the original language instead of failing.
- **Not done:** sidebar resize crash and the Sparkle 65→70 update check — the debug build
  shares the bundle ID with the installed app, so reproducing or updating would replace it;
  needs a separate test Mac or account. No catalog is hosted yet (the app keeps the bundled
  one until `models.json` + `.sig` are uploaded).
- **Observed:** on this Mac the Apple model and translation refuse sessions with
  ModelManagerError 1013 "CriticalMemoryPressure"; the real-model test skips in that state.
  Personal Voice speaks only the languages the user's voice was recorded in.

### Beta 70 join hang and review fixes (for beta 71)

- **Hang.** On macOS 27.2 (26B123) the audio session service (`audiomxd`) deadlocked on
  this app's AirPods/headset-mute opt-in (`PrefersBluetoothAccessoryMuting`) at four of
  five meeting starts today, killed itself after 9 s and left CoreAudio stalled: the
  meeting's audio never started (buttons stayed inactive). The startup-audio timeout then
  read the audio route on the main thread and blocked on the same CoreAudio lock. Fixed:
  route reads are off the main thread and bounded (timeout log and Help → Copy/Export
  Diagnostics); headset-button mute is a setting, off by default, and turns itself off for
  later meetings when the opt-in fails or takes over 2 s.
- **Review findings 1–5 fixed:** API keys per provider kind (the old key moves to the
  judge's provider); the speech model unloads when no meeting transcribes; line times
  re-anchor to each buffer's arrival (a playout stall no longer dates lines early); a
  card crowded out by two more urgent ones changes nothing and is logged `crowdedOut`;
  system/Personal Voice synthesis gives up after 30 s.
- Not verified: a live meeting on beta 71, and whether the headset opt-in deadlock
  reproduces on other macOS builds.

### 6. Deferred, with the reason

| Item | Why deferred |
|---|---|
| Preset-allowed auto-send | The 4B local writer committed on the user's behalf in tests; the Apple writer is unmeasured. Revisit after live draft quality is known, API/Apple writer only. |
| JEV adapter | No demand; any OpenAI-compatible judge fits the contract. |
| Preset sync across devices | Mac-only feature today. |
| WebRTC audio-module root fix | The 30 s stall is inside the module's device-change handling in CoreAudio; the fix needs the M156 source tree (`.build/webrtc-m156-port` is gone) and a framework rebuild, ~1 week. The app-side queues make it non-blocking; do this when the next WebRTC rebuild happens anyway. |

### Parity acceptance ledger

`native-mac-feature-parity-2026-10-24.md` § "Remaining acceptance gates" still lists physical
and live gates (headsets and acoustics, iCloud second device and Handoff, calendar end-to-end,
six-participant rooms, keyboard-only and VoiceOver, external distribution). They are not
features; they close with recorded runs on the betas above.

## Totals

About three weeks of implementation (items 2–5) plus your live checks in item 1. Betas 70–73
ship between items so each gets its own validation record.
