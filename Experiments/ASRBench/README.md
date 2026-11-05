# ASR benchmark

Scores the listen models in `NativeMacGuest/Attention/ListenModels.json` with the same
sherpa-onnx runtime the app embeds. See `docs/attention-phase-0-1.md` for results.

```bash
python3 -m venv .build/asr-bench/venv
.build/asr-bench/venv/bin/pip install sherpa-onnx==2.0.1 soundfile numpy jiwer
.build/asr-bench/venv/bin/python Experiments/ASRBench/asr_bench.py --fleurs 150
.build/asr-bench/venv/bin/python Experiments/ASRBench/asr_bench.py --recordings ~/MeetingSamples
```

A recordings folder holds `name.wav` with the reference text in `name.txt`. Record other
people only with their consent. Models, data and reports stay under `.build/asr-bench`.
The run also writes `sample-ru.wav`, which the Swift tests use for an end-to-end check.
