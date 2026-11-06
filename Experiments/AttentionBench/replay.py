#!/usr/bin/env python3
"""Replay Attention decisions against a judge model and compare with your choices.

Each decision the app logs carries the exact chat messages it sent. This script
sends those same messages to any OpenAI-compatible endpoint and reports how the
replayed verdicts agree with what you did with the cards: Open counts as "needed",
Decline as "not needed". Decisions without a card action are replayed and shown
for comparison but do not count toward agreement.

The API key is read from the ATTENTION_API_KEY environment variable and is never
printed. Nothing is written except the optional --report file.

    ATTENTION_API_KEY=... python3 Experiments/AttentionBench/replay.py \\
        --decisions "<Application Support>/Attention/decisions" \\
        --base-url https://api.openai.com/v1 --model gpt-4.1-mini
"""
import argparse
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request

SCHEMA = {
    "type": "object", "additionalProperties": False,
    "required": ["attention", "probability", "reason", "evidence", "action"],
    "properties": {
        "attention": {"type": "string", "enum": ["no", "soon", "now"]},
        "probability": {"type": "number"},
        "reason": {"type": "string"},
        "evidence": {"type": "array", "items": {"type": "string"}},
        "action": {"type": "string", "enum": ["none", "open", "chat", "reaction"]},
    },
}


def load(folder):
    decisions, outcomes = {}, {}
    for path in sorted(pathlib.Path(folder).glob("*.jsonl")):
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            record = json.loads(line)
            if record.get("messages") and record.get("verdict"):
                decisions[record["id"]] = record
            elif record.get("decisionID") and record.get("outcome") in ("opened", "replied", "reacted", "spoken", "declined"):
                outcomes[record["decisionID"]] = record["outcome"]
    return decisions, outcomes


def judge(base_url, model, key, messages, timeout):
    body = json.dumps({"model": model, "messages": messages, "response_format": {
        "type": "json_schema", "json_schema": {"name": "attention_verdict", "strict": True, "schema": SCHEMA}}}).encode()
    request = urllib.request.Request(base_url.rstrip("/") + "/chat/completions", data=body, method="POST",
                                     headers={"Content-Type": "application/json"})
    if key:
        request.add_header("Authorization", "Bearer " + key)
    started = time.monotonic()
    with urllib.request.urlopen(request, timeout=timeout) as response:
        answer = json.loads(response.read())
    content = answer["choices"][0]["message"]["content"]
    return json.loads(content), time.monotonic() - started


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--decisions", required=True, help="the app's Attention/decisions folder")
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--limit", type=int, default=200)
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--report", help="write per-decision results as JSON here")
    args = parser.parse_args()
    key = os.environ.get("ATTENTION_API_KEY", "")
    decisions, outcomes = load(args.decisions)
    chosen = sorted(decisions.values(), key=lambda r: (r["id"] not in outcomes, r["at"]))[:args.limit]
    if not chosen:
        sys.exit("No replayable decisions found (records need logged messages and a verdict).")
    rows, agree, labelled, true_pos, false_pos, false_neg, failures = [], 0, 0, 0, 0, 0, 0
    for record in chosen:
        threshold = record.get("threshold") or 0.55
        try:
            verdict, seconds = judge(args.base_url, args.model, key, record["messages"], args.timeout)
        except (urllib.error.URLError, KeyError, ValueError, TimeoutError) as error:
            failures += 1
            rows.append({"id": record["id"], "error": type(error).__name__})
            continue
        replayed = verdict.get("attention") != "no" and float(verdict.get("probability", 0)) >= threshold
        original = record["verdict"]["level"] != "no" and record["verdict"]["probability"] >= threshold
        user = outcomes.get(record["id"])
        row = {"id": record["id"], "at": record["at"], "meeting": record["meetingTitle"], "user": user,
               "original": record["verdict"]["level"], "replayed": verdict.get("attention"),
               "probability": verdict.get("probability"), "seconds": round(seconds, 2)}
        rows.append(row)
        if user:
            needed = user in ("opened", "replied", "reacted", "spoken")
            labelled += 1; agree += int(replayed == needed)
            true_pos += int(replayed and needed); false_pos += int(replayed and not needed); false_neg += int(not replayed and needed)
        print(f'{record["at"][:19]}  {record["meetingTitle"][:24]:24}  user={user or "-":8}  '
              f'original={record["verdict"]["level"]:4}  replay={verdict.get("attention"):4} '
              f'p={float(verdict.get("probability", 0)):.2f}  {"card" if replayed else "    "}  shown-before={"y" if original else "n"}')
    print()
    print(f"Replayed {len(rows) - failures} of {len(chosen)} decisions with {args.model}; {failures} failed.")
    if labelled:
        precision = true_pos / (true_pos + false_pos) if true_pos + false_pos else 0
        recall = true_pos / (true_pos + false_neg) if true_pos + false_neg else 0
        print(f"Agreement with your choices: {agree}/{labelled} ({agree / labelled:.0%}); "
              f"precision {precision:.2f}, recall {recall:.2f}.")
    else:
        print("No opened or declined cards yet, so agreement cannot be measured.")
    if args.report:
        pathlib.Path(args.report).write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
