# Attention — Phase 4 (local judge) and Phase 7 (voice replies) plan

Written 6 Nov 2026 against beta 63. Phases 0–3, 5 and the model comparison are released;
microphone-bus R0–R3 are released; R4 waits on your echo test.

## Your Mac sets the budget

MacBook Air, Apple M4 (10 cores), **16 GB unified memory**, macOS 27.2. The app is sandboxed
(`com.apple.security.app-sandbox`) with network client and server entitlements.

While you are in two meetings the app, its two WebRTC sessions and the local transcriber use
about 2–3 GB, and macOS itself 4–5 GB. That leaves **roughly 6–8 GB for models**, and only when
they take turns. Rapid-MLX's own sizing for 16 GB is `qwen3.5-4b-4bit`; a 4B model at 4-bit
peaks at about 3.9 GB at 1k context on this chip (oMLX community benchmark: 406 tok/s prefill,
37 tok/s decode, 2.5 s to first token at 1k).

## LSA: what it is and why it is not for us (yet)

**Latent Sparse Attention** (Prefrontal-AI, released 2 Nov 2026, Apache-2.0) clusters the keys
of a long context hierarchically in a learned latent space, so each query scores a few clusters
instead of every key. It needs a per-model *distilled indexer*; maps exist for Qwen3.8-27B and
GLM-5.3-Flash. The reference runtime is an SGLang fork on CUDA.

**Rapid-MLX's 4 Nov post** reports LSA running end-to-end on Apple Silicon as a hybrid: LSA for
prompt digestion (prefill), ordinary dense attention with MTP for generation. Qwen3.8-27B on an
M3 Ultra at **128k context**: time to first token 640 s → 440 s (−31 %), peak memory
40.7 → 28.8 GB (−29 %), decode unchanged. Pure LSA matched the paper's prefill scaling
(1.16× at 64k, 1.41× at 128k) but slowed decode, because per-token routing costs more than it
saves when decode is memory-bandwidth bound. It is not in a release yet (v1.0.1 is from 2 Nov).

Why it does not help this app today:

1. **Our prompts are short.** A judge call is the last three minutes of one meeting (≤ 60 lines),
   your profile, the meeting's instructions and ten examples: about **2–4k tokens**. The writer's
   call is the same plus the verdict. LSA's gains begin around 64k and matter at 128k+. At 4k the
   routing overhead would cost more than it saves.
2. **Its models do not fit a 16 GB Air.** Qwen3.8-27B at 4-bit is ~15 GB of weights before KV
   cache; Rapid-MLX lists it for 32 GB+ machines. No distilled LSA map exists for a 4B-class model.
3. **Our bottleneck is elsewhere.** Every 20-second tick re-sends a prompt whose first 60–80 %
   (system text, profile, instructions, examples) is identical to the last tick; only the window
   tail changes. What removes that cost is a **prefix (radix) cache**, which Rapid-MLX has on by
   default, plus a small quantized KV cache. Decode is ~100 tokens per call and barely matters.

Where LSA *would* matter: a future "whole-meeting memory" (judging or summarising over the
entire two-hour transcript, 60–100k tokens) on a 32 GB+ Mac. Keep it on the list for then.

## What Rapid-MLX gives us now

Rapid-MLX (Apache-2.0, Python 3.12+, `brew install raullenchai/rapid-mlx/rapid-mlx`, v1.0.1 on
2 Nov 2026) is an OpenAI-compatible server on MLX, loopback-only by default, installable as a
login service (`rapid-mlx service install`), with idle model release.

- `/v1/chat/completions` with **strict `json_schema`**: constrained generation plus validation
  (PR #3871, merged 29 Sep 2026). Violations answer 422 `json_schema_violation` or 502
  `strict_schema_violation`. Our judge already validates every verdict and retries 5xx twice, so
  this maps onto existing behaviour.
- **Prefix cache** on by default; **quantized KV** (`--kv-cache-dtype int8`); **MTP** speculative
  decoding default-on for 9B+ Qwen models (not 4B).
- `/v1/audio/transcriptions`: Whisper, Parakeet v3 (Russian among 25 languages), Qwen3-ASR,
  SenseVoice. We keep sherpa-onnx + GigaAM for transcription; nothing to change.
- `/v1/audio/speech`: **Qwen3-TTS** (CustomVoice, VoiceDesign, Base/clone), VoxCPM2 (30 languages),
  MOSS-TTS-Nano (20), Kokoro. Qwen3-TTS is trained on 10 languages including Russian; the
  CustomVoice named speakers are zh/en/ja/ko only, so Russian goes through **VoiceDesign** (a
  described voice) or **Base + clone** (a 10-second clip of a voice plus its transcript).
- `/v1/embeddings` (EmbeddingGemma 2, 1.1 GB) and an undocumented `/v1/systemone` "typed
  decisions" endpoint (`system-one` extra). Neither is needed now.

Because the app is sandboxed it cannot launch a Homebrew Python. The honest options:

| Option | How | Fit |
|---|---|---|
| **A. Sidecar you install** | You run Rapid-MLX as a login service; the app talks to `127.0.0.1:8000/v1` through the existing "Server on this network" provider | Works today. Right for you as the sole user. |
| B. Bundled helper | Ship a signed Python + MLX + models inside the app | 1–2 GB, notarization and sandbox friction; not worth it. |
| **C. In-process MLX** | `mlx-swift` (MLXLLM) for the judge, `mlx-audio-swift` or `swift-qwen3-tts` for speech; no Python, fully sandboxed | The real "Phase 4/7 in the app". Do it after A proves the models, together with Phase 6's model manager. |

## Phase 4 — local judge and feedback

Order: 4a → measure → 4b → 4c. 4d is gated.

### 4a. Rapid-MLX preset and measurement (1–2 days)

- Provider preset **"Rapid-MLX on this Mac"**: `http://127.0.0.1:8000/v1`, model
  `qwen3.5-4b-4bit`, no key. Settings shows whether the server answers (`GET /v1/models`) and, if
  not, the two commands to install and start it as a login service.
- Error mapping: 422 `json_schema_violation` → verdict error (no retry, shown as such);
  502 `strict_schema_violation` → already retried as 5xx.
- **Measure with the comparison tool**: run your saved decisions and drafts through the local
  model. Gate to proceed: agreement with your choices within ten points of the API model,
  median verdict time under 3 s plugged in, failure rate under 5 %. Also time two consecutive calls
  with the same prefix to confirm the prefix cache (expect the second to prefill only the tail).
- Candidate models in 16 GB: `qwen3.5-4b-4bit` (default), Gemma 4 small, `lfm2.5-2.6b-4bit`,
  and a Russian-tuned 8B at 4-bit (~4.5 GB, slower) if the 4B's Russian judging disappoints.
  Your meetings are Russian, so the comparison on your real prompts decides, not benchmarks.

### 4b. Local-mode scheduler and cost controls (3–4 days)

- Keep stable parts first in the prompt (already the order) so the cache prefix is long; never put
  volatile text (clock, counts) before the window.
- When the provider is local, plugged in and the thermal state is nominal: tick every 10 s and allow
  12 calls a minute (now 20 s / 6). Still one call in flight.
- Guards: `ProcessInfo.thermalState` serious/critical → pause; Low Power Mode → pause; memory
  pressure warning → pause and tell the sidebar why. Battery pause stays as it is.
- Local does not change what leaves the Mac: nothing. Settings → "What leaves this Mac" says so.

### 4c. Feedback into the prompt and thresholds (3–5 days)

- **Recalibrate thresholds**: the comparison engine already computes agreement/precision/recall
  per decision. Add a per-preset action that picks the threshold maximising agreement with your
  labelled history (instead of only ±0.05 steps), free with a local model.
- **Writer learns from your edits**: when you send an edited draft, keep (draft, sent) pairs per
  preset (last 10) and show them to the writer as "the user rewrote drafts like this".
- **Decline reasons as rules**: already in the prompt; add a short "do not alert for" summary when
  a reason repeats three times.

### 4d. In-process judge with mlx-swift (1–2 weeks, gated)

Only if 4a's numbers are good *and* you want users without Homebrew. Risks to check first:
Qwen3.5's hybrid (Gated DeltaNet) layers in `mlx-swift-examples`; constrained JSON in Swift
(`mlx-swift-structured`, or our validate-and-retry); model download and storage (Phase 6's model
manager); unloading on memory pressure. Pairs naturally with Phase 6.

## Phase 7 — voice replies

The audio path exists and is tested (R2: gate + player in the input graph for Guest, Telemost,
TrueConf; R3 for Rock). What is missing is a voice and the connection to Phase 5 drafts.

### 7a. Speak the draft with the system voice (1 day)

- Card gets **"Say it"** next to Send: the Phase 5 draft is synthesised with `AVSpeechSynthesizer`
  (macOS Russian voices Milena/Yuri; enhanced voices from System Settings) and played through the
  existing `speak(_:)` path: gate closes your microphone, plays, mutes, reopens.
- Nothing is spoken without the click; the card shows "Playing a voice reply…" as today.
- Requires the existing "Voice replies (experimental)" toggle.

### 7b. Qwen3-TTS through Rapid-MLX (2–3 days)

- Settings → Intelligence → Voice: "System voice" or "Rapid-MLX voice". The latter POSTs
  `/v1/audio/speech` with `qwen3-tts-voicedesign-4bit` and a voice description, or
  `qwen3-tts-clone` with a 10-second clip of your own voice and its transcript (both stay on the
  Mac; cloning your own voice for your own meetings, clearly labelled).
- WAV → `AVAudioPCMBuffer` → `playVoiceReply`. A two-sentence reply is ~5 s of audio; expect a few
  seconds to generate on M4 — acceptable for a reply, measured in 7b.
- Verify Russian by ear with VoiceDesign and clone; CustomVoice has no Russian speaker.
- Memory: `qwen3-tts-*-4bit` (~1 GB weights). With the judge loaded as well, Rapid-MLX's idle
  release decides; measure peak with two meetings open.

### 7c. In-process TTS (1–2 weeks, gated)

The Qwen3-TTS Swift port already exists: `mlx-audio-swift` (macOS 14+, Qwen3-TTS, streaming
chunks) or `swift-qwen3-tts` (MIT, Russian listed, no chunked audio yet). The work is integration,
download and memory budgeting, not a port. Same gate and pairing as 4d.

## Effort and order

| Step | Days | Depends on |
|---|---|---|
| 4a preset + measurement | 1–2 | you install Rapid-MLX |
| 7a system-voice "Say it" | 1 | Phase 5 (done) |
| 4b local scheduler + guards | 3–4 | 4a passes its gate |
| 7b Qwen3-TTS via Rapid-MLX | 2–3 | 4a's server running |
| 4c recalibration + writer examples | 3–5 | a week of labelled decisions |
| 4d / 7c in-process MLX | 1–2 weeks each | 4a/7b prove the models; Phase 6 model manager |

Suggested first week: 4a and 7a (both small, both testable by you the same day), then 7b and 4b.

## Risks

- Russian judging quality of a 4B model: unknown until the comparison runs on your prompts.
- 16 GB with two meetings, judge and TTS: measured in 4a/7b; fallback is the API judge under
  memory pressure.
- Rapid-MLX moves fast (0.16 → 1.0 in two weeks; Python 3.12 now required). We use only the
  OpenAI-standard subset and pin the version in the install hint.
- Constrained decoding on small Qwen models has been reported flaky in a sibling MLX server; our
  validator and retry absorb it, and the comparison's "Failed" column shows the rate.
- LSA: wrong shape for 3-minute windows and wrong size for this Mac; revisit for whole-meeting
  memory on a 32 GB+ machine.

## Sources

- Rapid-MLX LSA post, 4 Nov 2026: https://x.com/rapidmlx/status/2118074173323141191
- Latent Sparse Attention: https://github.com/Prefrontal-AI/latent-sparse-attention
- Rapid-MLX: https://github.com/raullenchai/Rapid-MLX, https://rapidmlx.com/docs/perf-flags,
  https://rapidmlx.com/docs/models/families/audio, strict JSON PR #3871
- M4 16 GB Qwen3.5-4B benchmark: https://omlx.ai/benchmarks/eh146ez1
- Qwen3-TTS Swift: https://github.com/Blaizzy/mlx-audio-swift,
  https://github.com/AtomGradient/swift-qwen3-tts, https://github.com/fmcgoohan/MLXVoiceKit

## Status (6 Nov 2026): 4a measured

Rapid-MLX 1.0.1, `qwen3.5-4b-4bit`, MacBook Air M4 16 GB, `local_smoke.py` (six Russian scenarios
with known answers, each sent twice, the second with one extra line):

| Request shape | Correct | Valid JSON | Median time | Prompt cache |
|---|---|---|---|---|
| Strict `json_schema` | 6/6 | 6/6 | 8.1 s | not used (schema adds ~300 prompt tokens) |
| `json_object` + shape in the instructions | **6/6** | **6/6** | **3.6 s** | 512 tokens reused |
| No `response_format` | 5/6 | 6/6 | 3.3 s | 512 tokens reused |

Breakdown on one prompt: reading 635 tokens 2.2 s cold, 0.3 s with the cache; ~110 answer tokens
≈ 3.5 s plain, ≈ 7 s under the strict grammar. Thinking is not the cost (output is ~110 tokens with
or without `enable_thinking: false`). Server RSS ≈ 1 GB plus MLX buffers; `recipe` budgets 6 GB.

Decisions taken in code:

- **Models on this Mac** (127.0.0.1 / localhost) get `json_object`, the verdict or draft shape
  appended to the system prompt, temperature 0, `max_tokens` 400, and for Rapid-MLX
  `enable_thinking: false`. Providers elsewhere keep the strict schema. Answers in a Markdown
  fence are accepted. Logged prompts stay the shape-free version; a local replay adds the shape once.
- **The 4B writer is not safe.** With the app's exact writer rules, and again with an extra rule
  against confirming or choosing for the user, it wrote "Подтверждаю, DNS готов", "Выбираю центр
  сертификации DigiCert" and answered a thank-you with nonsense. So while the judge runs on this
  Mac, cards offer reactions only; Settings → Replies has an opt-in "Draft with the model on this
  Mac anyway". A separate writer provider (e.g. the API model for drafts only) is a follow-up.
- **Gate result:** quality passes on the scenarios (6/6, same as expected answers); time is 3.6 s
  against the 3 s target. Your real decisions still need Compare models in the app (the log is in
  the app's sandbox container, unreadable from outside).

### Earlier notes (same day)

- **Install route.** The Homebrew formula pulls 66 dependencies (PyTorch, OpenCV, Qt, VTK) and
  upgrades 28 installed formulae, so it was stopped before installing anything and its tap removed.
  Rapid-MLX 1.0.1 is installed instead with pip into an isolated venv, `~/.rapid-mlx/venv`
  (1.8 GB, Python 3.14). `rapid-mlx service install` is a system LaunchDaemon with its own service
  account, meant for an always-on Mac mini; on a laptop the server is started by hand (or later by
  a per-user LaunchAgent) with `--no-telemetry`, bound to 127.0.0.1.
- **Model.** `rapid-mlx recipe` on this Mac picks `qwen3.5-4b-4bit` (≈6 GB RAM,
  `mlx-community/Qwen3.5-4B-MLX-4bit`, 3.1 GB download): dense Gated DeltaNet, reasoning parser
  qwen3, no speculative decoding by default.
- **App.** Provider "Rapid-MLX on this Mac" (`http://127.0.0.1:8000/v1`, no key) with a status
  check in Settings (running / model missing / not answering, with the start commands). Local
  providers get a 60 s request timeout (first call loads the model) and "What leaves this Mac"
  says nothing does. A 422 `json_schema_violation` maps to a malformed-verdict error, not retried.
- **Measurement.** The app's decision log lives in its sandbox container, which other processes
  cannot read, so the comparison on your real decisions runs in the app (Compare models).
  `Experiments/AttentionBench/local_smoke.py` checks six Russian scenarios with known answers,
  schema validity, timing and the prefix cache, plus one reply draft.

## Status (6 Nov 2026): rest of 4 and 7 (beta 64)

Built:

- **Separate writer.** Settings → Intelligence → Replies → "Write replies with": the judge's
  provider (default) or another one with its own model. A judge on this Mac can pair with the API
  model as writer. Drafts need the writer's key when it needs one (one keychain key is shared).
  "What leaves this Mac" names the writer's host.
- **4b, local scheduling and guards.** A judge on this Mac, plugged in, thermal state nominal or
  fair and no memory pressure: checks every 10 s, 12 calls a minute (otherwise 20 s / 6). It pauses
  on serious/critical thermal state, Low Power Mode or a memory-pressure warning, with the reason in
  the sidebar (`AttentionMemoryPressure` watches the system's pressure events).
- **4c, learning.** Each meeting's instructions → "Tune threshold from your choices" replays the
  meeting's saved verdicts under every threshold from 0.30 to 0.80 and offers the one that matches
  your Open / reply / reaction / spoken / Decline choices best (needs six choices of both kinds).
  Drafts you rewrite before sending are kept (ten per meeting) and the five newest are shown to the
  writer. A decline reason given three or more times becomes a line in the judge's prompt.
- **7a, "Say it".** Cards in meetings that can play a voice reply (Voice replies on, joined after)
  get a reply field and "Say it": the text is synthesised and played through the R2 path (gate
  closes your microphone, plays, mutes, reopens). Works without chat too (TrueConf). Counts as an
  approval (`spoken`). Settings → Intelligence → Voice → Listen previews on this Mac only.
- **7b, Qwen3-TTS via Rapid-MLX.** Voice "Rapid-MLX on this Mac": OpenAI-style
  `/v1/audio/speech` with `qwen3-tts-voicedesign-4bit` (2.3 GB), a voice description, the reply's
  language from `NLLanguageRecognizer`, WAV back. Rapid-MLX needs the `audio` extra (+0.5 GB) and
  `--enable-audio`; one server then serves the 4B judge and the voice together.

Measured here: "Сейчас посмотрю и отвечу через минуту." → 4.4 s of 24 kHz speech in 10.8 s cold
(model load); "Анна, я сейчас на другой встрече, отвечу через пару минут." → 5.6 s in 2.6 s warm.
GigaAM transcribed both back correctly ("Анна" heard as "Она"). The app's live test: 1.9 s.

Not built: 4d and 7c (models inside the app via mlx-swift / mlx-audio-swift, 1–2 weeks each). They
remain gated on real use of the Rapid-MLX route.

## Status (6 Nov 2026): betas 66–69

- **Listen on the Neural Engine (beta 66, 608715d).** GigaAM v3 e2e RNN-T runs natively through
  Core ML (`CoreMLGigaAM.swift`): encoder on the ANE, decoder/joint on the CPU, Swift log-mel
  front end matching torchaudio (parity max 9e-5). Default model `gigaam-v3-e2e-rnnt-coreml`
  (446 MB); the previous sherpa model stays selected when it is the only one installed. Bench:
  real-time factor 0.0104, WER 4.14 (int8 sherpa on CPU: 28×, WER 4.60), first load 9–12 s.
- **Judge "Apple on this Mac" (beta 67, 24799f2, `OnDeviceJudge.swift`).** Foundation Models
  (macOS 26+) judges and drafts. The system model lists no Russian, so a meeting in a language
  it lacks is translated to English on this Mac first (Translation framework, per-line cache),
  and the card's reason and chat drafts are translated back. The verdict schema is built per
  window so evidence can only cite existing lines; four extra rules stop the small model from
  treating the user's interests as the meeting's topic. Bench (`Experiments/AttentionBench/
  ru_scenarios.py`, 31 tuning + 12 held-out Russian windows, opt-in `AttentionLocalModelBench`):
  through the app's judge 28/31 and 12/12 acceptable, no missed "now", median 3.3 s per window
  including translation. Rapid-MLX on the same set: 27/31 and 12/12 in English, 25/31 in
  Russian. FoundationModels and Translation are weak-linked; the app still runs on macOS 13.
- Betas 68–69 carried no attention changes (main-thread WebRTC freeze fixes).
- Still not verified live: the Apple judge in a real meeting, Compare models on real decisions.
  4d is now superseded by the Apple judge for the judge role (see
  `remaining-work-plan-2026-11-06.md`).
