#!/usr/bin/env python3
"""Compare synthetic reference/decoded detail charts and steady native counters."""
import argparse, json, math
from pathlib import Path
import numpy as np
from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument('directory', type=Path)
args = parser.parse_args()
results = []
for path in sorted(args.directory.glob('report-*.json')):
    phase = path.stem.removeprefix('report-')
    report = json.loads(path.read_text())
    reference = np.asarray(Image.open(args.directory / f'reference-{phase}.png').convert('RGB'), dtype=np.float32)
    decoded = np.asarray(Image.open(args.directory / f'snapshot-{phase}.png').convert('RGB'), dtype=np.float32)
    if decoded.shape != reference.shape:
        raise ValueError(f'{phase}: receiver dimensions {decoded.shape} != source {reference.shape}')
    text = (slice(50, 800), slice(50, 3700))
    received = report['receiver'].get('frames', [])
    minimum_frames = 3 if report.get('constrained') else 10
    delivered = len(received) > minimum_frames and any(f.get('width') == report['width'] for f in received[-10:])
    mse = float(np.mean((reference[text] - decoded[text])**2))
    psnr = 10 * math.log10(255**2 / mse) if mse else None
    moving_psnr = None
    moving_path = args.directory / f'snapshot-moving-{phase}.png'
    if delivered and moving_path.exists():
        moving = np.asarray(Image.open(moving_path).convert('RGB'), dtype=np.float32)
        errors = []
        for index in range(3):
            candidate = np.asarray(Image.open(args.directory / f'reference-moving{index}-{phase}.png').convert('RGB'), dtype=np.float32)
            errors.append(float(np.mean((candidate[text] - moving[text])**2)))
        moving_mse = min(errors)
        moving_psnr = 10 * math.log10(255**2 / moving_mse) if moving_mse else None
    before = {r['id']: r for r in report['before'] if r['type'] == 'outbound-rtp' and r.get('kind') == 'video'}
    after = [r for r in report['after'] if r['type'] == 'outbound-rtp' and r.get('kind') == 'video']
    frame_count = byte_count = encode_seconds = qp_sum = 0
    for row in after:
        old = before.get(row['id'], {})
        frame_count += row.get('framesEncoded', 0) - old.get('framesEncoded', 0)
        byte_count += row.get('bytesSent', 0) - old.get('bytesSent', 0)
        encode_seconds += row.get('totalEncodeTime', 0) - old.get('totalEncodeTime', 0)
        qp_sum += row.get('qpSum', 0) - old.get('qpSum', 0)
    seconds = report['duration']
    results.append({'phase': phase, 'scrolling': report['scrolling'], 'composed': report['composed'], 'freshFramesReceived': delivered, 'movingTextPSNRdB': moving_psnr, 'textPSNRdB': psnr if delivered else None,
                    'cpuPercentOfOneCore': 100 * report['processCPUSeconds'] / seconds,
                    'encodedFPS': frame_count / seconds, 'actualKbps': 8 * byte_count / seconds / 1000,
                    'encodeMsPerFrame': 1000 * encode_seconds / frame_count if frame_count else None,
                    'meanQP': qp_sum / frame_count if frame_count else None,
                    'codec': [r.get('mimeType') for r in after], 'encoder': [r.get('encoderImplementation') for r in after],
                    'powerEfficient': [r.get('powerEfficientEncoder') for r in after],
                    'degradationPreference': [r.get('degradationPreference') for r in after],
                    'encodingLimits': [r.get('encodingLimits') for r in after]})
print(json.dumps(results, indent=2))
