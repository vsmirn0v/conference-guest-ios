#!/usr/bin/env python3
"""Russian speech recognition benchmark for the Attention "Listen" role.

Runs every listen model in NativeMacGuest/Attention/ListenModels.json through
sherpa-onnx (the runtime the app embeds) on FLEURS ru and on local recordings,
and reports WER, CER, real-time factor and model load time on this Mac.

Usage (from the repository root):
    python3 -m venv .build/asr-bench/venv
    .build/asr-bench/venv/bin/pip install sherpa-onnx==2.0.1 soundfile numpy jiwer
    .build/asr-bench/venv/bin/python Experiments/ASRBench/asr_bench.py --fleurs 150
    .build/asr-bench/venv/bin/python Experiments/ASRBench/asr_bench.py --recordings ~/Recordings/meetings

A recordings folder holds `name.wav` (any rate, mono or stereo) with a
reference transcript in `name.txt`. Recordings of other people need their
consent; nothing here uploads audio anywhere.
"""
import argparse
import csv
import hashlib
import io
import json
import pathlib
import re
import resource
import sys
import tarfile
import time
import urllib.request

import numpy as np
import soundfile
import jiwer
import sherpa_onnx

ROOT = pathlib.Path(__file__).resolve().parents[2]
CATALOG = ROOT / "NativeMacGuest/Attention/ListenModels.json"
WORK = ROOT / ".build/asr-bench"
FLEURS = "https://huggingface.co/datasets/google/fleurs/resolve/main/data/ru_ru"


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def fetch(url, target, expected=None, size=None):
    """Download once; a pinned hash must match, an unpinned one is reported."""
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists() or (size and target.stat().st_size != size):
        partial = target.with_suffix(target.suffix + ".part")
        with urllib.request.urlopen(url) as response, open(partial, "wb") as out:
            while block := response.read(1 << 20):
                out.write(block)
        partial.rename(target)
    actual = sha256(target)
    if expected and expected != "PIN" and actual != expected:
        raise SystemExit(f"{target.name}: SHA-256 {actual} differs from the catalog's {expected}")
    return actual


def prepare_model(model):
    folder = WORK / "models" / model["id"]
    pins = {}
    for item in model["files"]:
        actual = fetch(item["url"], folder / item["name"], item["sha256"], item.get("size"))
        if item["sha256"] == "PIN":
            pins[item["name"]] = actual
    return folder, pins


def recognizer(model, folder, threads, provider):
    path = lambda key: str(folder / model["config"][key])
    kind = model["kind"]
    if kind == "nemo_transducer":
        return sherpa_onnx.OfflineRecognizer.from_transducer(
            encoder=path("encoder"), decoder=path("decoder"), joiner=path("joiner"), tokens=path("tokens"),
            num_threads=threads, provider=provider, feature_dim=model["featureDim"],
            model_type="nemo_transducer", decoding_method="greedy_search")
    if kind == "nemo_ctc":
        return sherpa_onnx.OfflineRecognizer.from_nemo_ctc(
            model=path("model"), tokens=path("tokens"), num_threads=threads, provider=provider,
            feature_dim=model["featureDim"], decoding_method="greedy_search")
    if kind == "whisper":
        return sherpa_onnx.OfflineRecognizer.from_whisper(
            encoder=path("encoder"), decoder=path("decoder"), tokens=path("tokens"),
            num_threads=threads, provider=provider, language="ru", task="transcribe")
    raise SystemExit(f"Unsupported model kind {kind}")


def normalize(text):
    """Compare words, not formatting: lower case, ё→е, punctuation removed."""
    text = text.lower().replace("ё", "е")
    text = re.sub(r"[^\w\s]", " ", text)
    return " ".join(text.split())


def to_16k_mono(samples, rate):
    if samples.ndim > 1:
        samples = samples.mean(axis=1)
    samples = samples.astype(np.float32)
    if rate == 16000:
        return samples
    duration = len(samples) / rate
    positions = np.linspace(0, len(samples) - 1, int(duration * 16000))
    return np.interp(positions, np.arange(len(samples)), samples).astype(np.float32)


def fleurs(limit):
    folder = WORK / "fleurs-ru"
    fetch(f"{FLEURS}/dev.tsv", folder / "dev.tsv")
    archive = folder / "dev.tar.gz"
    fetch(f"{FLEURS}/audio/dev.tar.gz", archive)
    # FLEURS lists several speakers per sentence in a row; take one recording
    # per distinct sentence so the sample covers `limit` different sentences.
    rows, seen = [], set()
    with open(folder / "dev.tsv", newline="") as stream:
        for row in csv.reader(stream, delimiter="\t", quoting=csv.QUOTE_NONE):
            if row[0] not in seen:
                seen.add(row[0]); rows.append((row[1], row[2]))
    wanted = dict(rows[:limit])
    items = []
    with tarfile.open(archive) as tar:
        for member in tar:
            name = pathlib.PurePath(member.name).name
            if name in wanted:
                data, rate = soundfile.read(io.BytesIO(tar.extractfile(member).read()))
                items.append((name, to_16k_mono(data, rate), wanted[name]))
                if len(items) == len(wanted):
                    break
    sample = WORK / "sample-ru.wav"
    if items and not sample.exists():
        soundfile.write(sample, items[0][1], 16000, subtype="FLOAT")
        sample.with_suffix(".txt").write_text(items[0][2])
    return items


def recordings(folder):
    items = []
    for wav in sorted(pathlib.Path(folder).expanduser().glob("*.wav")):
        reference = wav.with_suffix(".txt")
        if reference.exists():
            data, rate = soundfile.read(wav)
            items.append((wav.name, to_16k_mono(data, rate), reference.read_text().strip()))
    return items


def run(model, folder, items, threads, provider):
    started = time.perf_counter()
    engine = recognizer(model, folder, threads, provider)
    load = time.perf_counter() - started
    hypotheses, references, audio, decode = [], [], 0.0, 0.0
    for name, samples, reference in items:
        stream = engine.create_stream()
        stream.accept_waveform(16000, samples)
        started = time.perf_counter()
        engine.decode_stream(stream)
        decode += time.perf_counter() - started
        audio += len(samples) / 16000
        hypotheses.append(stream.result.text.strip())
        references.append(reference)
    hyp = [normalize(x) for x in hypotheses]
    ref = [normalize(x) for x in references]
    return {
        "model": model["id"], "provider": provider, "threads": threads, "utterances": len(items),
        "audioSeconds": round(audio, 1), "loadSeconds": round(load, 2), "rtf": round(decode / audio, 4),
        "wer": round(jiwer.wer(ref, hyp) * 100, 2), "cer": round(jiwer.cer(ref, hyp) * 100, 2),
        "peakRSSMB": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1 << 20), 1),
        "punctuated": sum(bool(re.search(r"[.,?!]", x)) for x in hypotheses),
        "samples": [{"id": n, "reference": r, "hypothesis": h} for (n, _, r), h in zip(items[:5], hypotheses[:5])],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fleurs", type=int, default=0, help="number of FLEURS ru dev utterances")
    parser.add_argument("--recordings", help="folder of name.wav + name.txt pairs")
    parser.add_argument("--models", nargs="*", help="model ids (default: every listen model)")
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--provider", default="cpu", choices=["cpu", "coreml"])
    a = parser.parse_args()
    catalog = json.loads(CATALOG.read_text())
    models = [m for m in catalog["models"] if m["role"] == "listen" and (not a.models or m["id"] in a.models)]
    sets = []
    if a.fleurs:
        sets.append(("fleurs-ru-dev", fleurs(a.fleurs)))
    if a.recordings:
        sets.append(("recordings", recordings(a.recordings)))
    if not sets:
        parser.error("choose --fleurs N and/or --recordings FOLDER")
    results, pins = [], {}
    for model in catalog["models"]:
        if model["role"] == "vad":
            prepare_model(model)
    for model in models:
        folder, model_pins = prepare_model(model)
        if model_pins:
            pins[model["id"]] = model_pins
        for name, items in sets:
            result = run(model, folder, items, a.threads, a.provider)
            result["set"] = name
            results.append(result)
            print(f'{name:14} {model["id"]:24} WER {result["wer"]:6.2f}  CER {result["cer"]:6.2f}  '
                  f'RTF {result["rtf"]:.3f}  load {result["loadSeconds"]:5.1f}s  punct {result["punctuated"]}/{result["utterances"]}',
                  flush=True)
    out = WORK / "results"
    out.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    report = {"createdAt": stamp, "sherpaOnnx": sherpa_onnx.__version__, "machine": machine(),
              "results": results, "unpinnedHashes": pins}
    (out / f"asr-bench-{stamp}.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"Report: {out / f'asr-bench-{stamp}.json'}")
    if pins:
        print("Hashes to pin in the catalog:", json.dumps(pins, indent=2))


def machine():
    import platform, subprocess
    chip = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
    memory = int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout.strip() or 0)
    return {"chip": chip, "memoryGB": round(memory / (1 << 30)), "macOS": platform.mac_ver()[0]}


if __name__ == "__main__":
    sys.exit(main())
