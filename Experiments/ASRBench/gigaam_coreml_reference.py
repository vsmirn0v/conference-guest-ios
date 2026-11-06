"""Reference outputs for the app's native Core ML GigaAM (CoreMLGigaAM.swift).

Writes, next to the bench's sample-ru.wav:
  sample-ru.gigaam-mel.f32   torchaudio log-mel of the first 30 s window, float32 [64][2999]
  sample-ru.gigaam-coreml.txt  the transcript from the conversion's own reference loop (CPU_AND_GPU)

Needs Python <= 3.13 with coremltools, torch, torchaudio, soundfile (coremltools has no 3.14 wheel):
  uv venv --python 3.13 .build/asr-bench/coreml-venv
  uv pip install --python .build/asr-bench/coreml-venv/bin/python coremltools torch torchaudio soundfile numpy
  .build/asr-bench/coreml-venv/bin/python Experiments/ASRBench/gigaam_coreml_reference.py
The model is the catalog's gigaam-v3-e2e-rnnt-coreml, under .build/asr-bench/models.
"""
import json
import pathlib

import coremltools as ct
import numpy as np
import soundfile
import torch
import torchaudio

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORK = ROOT / ".build/asr-bench"
MODEL = WORK / "models/gigaam-v3-e2e-rnnt-coreml"
BLANK, SR, WINDOW = 1024, 16000, 30 * 16000

samples, rate = soundfile.read(WORK / "sample-ru.wav", dtype="float32")
assert rate == SR and samples.ndim == 1, "sample-ru.wav must be 16 kHz mono"
n = min(len(samples), WINDOW)
padded = torch.zeros(1, WINDOW)
padded[0, :n] = torch.from_numpy(samples[:n])
mel = torchaudio.transforms.MelSpectrogram(sample_rate=SR, n_mels=64, win_length=320, hop_length=160,
                                           n_fft=320, center=False, mel_scale="htk", norm=None)
feats = mel(padded).clamp(1e-9, 1e9).log().numpy().astype(np.float32)   # [1, 64, 2999]
feats[0].astype("<f4").tofile(WORK / "sample-ru.gigaam-mel.f32")

unit = ct.ComputeUnit.CPU_AND_GPU   # token-exact per the conversion's notes
enc = ct.models.MLModel(str(MODEL / "GigaAMv3Encoder.mlpackage"), compute_units=unit)
dec = ct.models.MLModel(str(MODEL / "GigaAMv3DecoderStep.mlpackage"), compute_units=unit)
joint = ct.models.MLModel(str(MODEL / "GigaAMv3JointStep.mlpackage"), compute_units=unit)
pieces = json.loads((MODEL / "tokens.json").read_text())
out = enc.predict({"features": feats, "length": np.array([(n - 320) // 160 + 1], dtype=np.int32)})
encoded, frames = out["encoded"], int(np.array(out["encoded_len"]).reshape(-1)[0])
ids, h = [], np.zeros((1, 1, 320), dtype=np.float32)
c, last = h.copy(), BLANK
for t in range(frames):
    enc_t = encoded[:, :, t].astype(np.float32)
    for _ in range(10):
        d = dec.predict({"token": np.array([[last]], dtype=np.int32), "h_in": h, "c_in": c})
        k = int(np.argmax(joint.predict({"enc_t": enc_t, "dec_t": d["dec_out"].astype(np.float32)})["logits"]))
        if k == BLANK:
            break
        ids.append(k)
        h, c, last = d["h_out"].astype(np.float32), d["c_out"].astype(np.float32), k
text = "".join(pieces[i] for i in ids).replace("▁", " ").strip()
(WORK / "sample-ru.gigaam-coreml.txt").write_text(text + "\n", encoding="utf-8")
print(f"mel {feats.shape}, {len(ids)} tokens: {text}")
