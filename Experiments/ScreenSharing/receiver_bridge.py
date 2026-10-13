#!/usr/bin/env python3
"""Local XCTest bridge to a Playwright CLI receive-only browser session."""
import argparse
import base64
import json
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--cli', required=True)
parser.add_argument('--session', default='screen-resize')
parser.add_argument('--port', type=int, default=18769)
parser.add_argument('--evidence', type=Path, required=True)
parser.add_argument('--keep-visible', action='store_true', help='Avoid Chromium presentation throttling during detail benchmarks')
args = parser.parse_args()

def evaluate(expression):
    result = subprocess.run([args.cli, '--session', args.session, 'eval', expression],
                            capture_output=True, text=True, timeout=20, check=True)
    payload = result.stdout.split('### Result\n', 1)[1].split('\n### ', 1)[0]
    return json.loads(payload)

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        # Explicit synthetic-chart qualification only, bounded and loopback-local.
        try:
            kind, label = self.path.lstrip('/').split('-', 1)
            if kind not in ['reference', 'report'] or len(label) > 48 or not label.replace('-', '').isalnum():
                self.send_error(404); return
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size <= 20_000_000:
                self.send_error(413); return
            payload = self.rfile.read(size)
            if kind == 'reference':
                if not payload.startswith(b'\x89PNG\r\n\x1a\n'):
                    self.send_error(415); return
                args.evidence.with_name(self.path[1:] + '.png').write_bytes(payload)
            else:
                result = json.loads(payload)
                args.evidence.with_name(self.path[1:] + '.json').write_text(json.dumps(result, indent=2))
            self.send_response(204); self.end_headers()
        except Exception as error:
            self.send_error(500, str(error))
    def do_GET(self):
        try:
            if self.path == '/reset':
                # Keep the independent receiver visible: an occluded Chromium
                # window can throttle presentation callbacks despite decoding.
                if args.keep_visible:
                    subprocess.run([args.cli, '--session', args.session, 'run-code', 'async page => { await page.bringToFront(); }'], capture_output=True, text=True, timeout=20, check=True)
                result = evaluate('(() => { window.rockResizeReceiver.reset(); return {reset: true}; })()')
            elif self.path == '/frames':
                result = evaluate('({frames: window.rockResizeReceiver.frames, error: window.rockResizeReceiver.error || null})')
                args.evidence.write_text(json.dumps(result, indent=2))
            elif self.path.startswith('/snapshot-') and len(self.path) < 60 and self.path.removeprefix('/snapshot-').replace('-', '').isalnum():
                # Explicit opt-in synthetic-chart test, never arbitrary page content.
                result = evaluate('''(() => {
                    const video = [...document.querySelectorAll('video')].sort((a,b) => b.videoWidth*b.videoHeight-a.videoWidth*a.videoHeight)[0];
                    if (!video || !video.videoWidth) throw Error('No decoded video');
                    const canvas = document.createElement('canvas'); canvas.width = video.videoWidth; canvas.height = video.videoHeight;
                    canvas.getContext('2d').drawImage(video, 0, 0);
                    return {width: canvas.width, height: canvas.height, png: canvas.toDataURL('image/png').split(',')[1]};
                })()''')
                image = args.evidence.with_name(self.path[1:] + '.png')
                image.write_bytes(base64.b64decode(result.pop('png')))
                result['path'] = str(image)
            else:
                self.send_error(404)
                return
            data = json.dumps(result).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as error:
            self.send_error(500, str(error))
    def log_message(self, *_):
        pass

print(f'Receiver evidence bridge listening on 127.0.0.1:{args.port}', flush=True)
HTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
