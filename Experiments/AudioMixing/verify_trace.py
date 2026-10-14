#!/usr/bin/env python3
"""Validate the real media path; a connected UI is not a playback assertion."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('trace', type=Path)
parser.add_argument('--start', type=float, required=True)
parser.add_argument('--end', type=float, required=True)
args = parser.parse_args()
rows = sorted({(row['time'], row['event']): row for row in
               (json.loads(line) for line in args.trace.read_text().splitlines())
               if args.start <= row['time'] <= args.end}.values(), key=lambda row: row['time'])
assert rows, 'No trace records in the requested playback interval'
assert not any(row.get('interrupted') or row.get('reconnecting') for row in rows), 'Meeting yielded or rejoined during playback'
samples = [row for row in rows if row['event'] == 'rtp-sample' and row.get('appState') == 2]
assert len(samples) >= 3, 'Need at least three background RTP samples'
assert samples[-1]['time'] - samples[0]['time'] >= 10, 'Background interval too short'
previous = {}
progress = 0
for sample in samples:
    assert sample['audioReady'] and sample['audioGateReady'], 'Audio ownership lost'
    assert sample['audioOptions'] & 1, 'MixWithOthers lost'
    assert sample['otherAudioPlaying'], 'No competing playback at sample time'
    assert sample['sampleRate'] == 48_000, 'Unexpected built-in output sample rate'
    audio = [stream for stream in sample['streams'] if stream.get('kind') == 'audio']
    assert audio, 'No incoming audio stream'
    for stream in audio:
        identity = stream['id']
        if identity in previous:
            old = previous[identity]
            assert stream['bytesReceived'] > old['bytesReceived'], 'Incoming RTP stopped'
            assert stream['totalAudioEnergy'] > old['totalAudioEnergy'], 'Decoded nonzero audio stopped'
            progress += 1
        previous[identity] = stream
for left, right in zip(samples, samples[1:]):
    assert right['time'] - left['time'] < 12, 'Background processing stalled'
assert progress >= 2, 'No continuous decoded-audio stream'
print(json.dumps({'backgroundSamples': len(samples), 'progressIntervals': progress,
                  'seconds': round(samples[-1]['time'] - samples[0]['time'], 2),
                  'sampleRate': 48_000, 'interruptions': 0, 'reconnects': 0}))
