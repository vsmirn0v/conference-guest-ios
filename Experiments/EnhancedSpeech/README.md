# Enhanced speech qualification — 2026-10-06

This is an isolated experiment. No neural model, package dependency, PCM hook,
resampler or audio-session change was added to the shipping application.
Conversation, Music, echo protection and call recovery retain their existing paths.

## Candidate and reproducibility

- [DeepFilterNet-mlx](https://github.com/kylehowells/DeepFilterNet-mlx), source
  `c6c4b9dc98c62bfa90ed66c5fd4f5d54e88c7b4f`.
- [DeepFilterNet3 streaming Core ML assets](https://huggingface.co/iky1e/DeepFilterNet3-Streaming-CoreML),
  snapshot `dfc12319b3a62d09e9d51aace480c981067b9d7b`.
- Every asset passed the snapshot's SHA256SUMS. Published code and model license
  files were inspected; neither code nor weights were copied into the application.
- Optimized benchmark CLI on Apple M4 / macOS 27.0.1. Eight-second paced runs,
  48 kHz mono, 480 samples per 10 ms hop, persistent recurrent state, one hop/batch.
- Input: 12.37 seconds of locally synthesized Samantha speech, plus Gaussian noise
  with seed 38 and a target 5 dB SNR. No microphone recording or meeting audio.
- Full-file processing and an eight-second live-clock simulation are separate
  measurements. The latter includes scheduler/backlog latency but no network,
  microphone, AEC or conferencing encoder.

## Measurements

| Allowed compute units | Compute p50 / p95 / p99 | Output p95 / p99 | Missed 10 ms deadlines |
| --- | --- | --- | --- |
| All | 1.095 / 2.311 / 4.068 ms | 34.137 / 82.752 ms | 17 / 800 |
| CPU + Neural Engine | 1.126 / 2.049 / 2.777 ms | 33.858 / 34.635 ms | 0 / 800 |
| CPU only | 1.281 / 2.065 / 2.428 ms | 33.765 / 34.183 ms | 0 / 800 |

The model adds **30 ms fixed signal delay**, excluding inference and scheduling.
The All run's maximum compute time was 62 ms and its maximum queue delay was
98 ms. These short runs were sequential, with changing host load; they do not
establish a permanent backend ranking. Allowed compute units are not proof that
particular graph operations executed on the Neural Engine. Energy was not measured.

The All full-file output, after conversion to signed 16-bit PCM, gave 0.9917
correlation with clean speech and 17.82 dB gain-fitted SNR, against 5.01 dB noisy
input. The benchmark WAV writer trims fixed model delay, so file comparison uses
zero additional alignment offset. This one synthetic sample is encouraging, not
human listening, PESQ/STOI, accent coverage or music fidelity qualification.

## Reproduce

Use a fresh checkout/archive of the pinned source and local assets from the pinned
model snapshot. Install Xcode's Metal Toolchain if the upstream MLX dependency
requires it; the benchmark package builds MLX even when evaluating Core ML.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build -c release --product deepfilternet-benchmark
.build/release/deepfilternet-benchmark /path/to/noisy-48k-mono.wav \
  --model /path/to/pinned-assets --coreml-model-dir /path/to/pinned-assets \
  --engines coreml --coreml-compute-units cpuAndNeuralEngine \
  --skip-offline --live --live-duration 8 --warmup 1 --runs 1 \
  --save-output --output-dir /tmp/enhanced-speech-results
```

Repeat with `all` and `cpuOnly`. Sanitized benchmark JSON is in Results. No models,
generated WAVs or recordings are committed. The app's iOS 16 minimum is unchanged;
the candidate package itself requires iOS 17, so future integration must remain an
availability-gated, separately linked feature rather than raise the app minimum.

## Adoption gate

Keep this experimental. The guest engine exposes no supported raw-PCM processing
hook. An app-owned engine could use its public processing delegate, but needs a
bounded streaming adapter, route/rate adaptation, state reset on mute/hold/retirement,
AEC preservation and a single denoiser. No second AVAudioEngine or private SDK patch.
Never enable it in Music. Before adoption, compare real noisy speech against native
Voice Isolation and the current Conversation profile, then measure iPhone CPU/energy,
speaker echo and cellular/FaceTime recovery. Physical profiling runs stay under one
minute. No evidence yet supports changing the current production audio path.
