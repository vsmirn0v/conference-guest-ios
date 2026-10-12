#!/usr/bin/env python3
"""Local XCTest bridge to a Playwright CLI receive-only browser session."""
import argparse
import json
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--cli', required=True)
parser.add_argument('--session', default='screen-resize')
parser.add_argument('--port', type=int, default=18769)
parser.add_argument('--evidence', type=Path, required=True)
args = parser.parse_args()

def evaluate(expression):
    result = subprocess.run([args.cli, '--session', args.session, 'eval', expression],
                            capture_output=True, text=True, timeout=20, check=True)
    payload = result.stdout.split('### Result\n', 1)[1].split('\n### ', 1)[0]
    return json.loads(payload)

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            if self.path == '/reset':
                result = evaluate('(() => { window.rockResizeReceiver.reset(); return {reset: true}; })()')
            elif self.path == '/frames':
                result = evaluate('({frames: window.rockResizeReceiver.frames, error: window.rockResizeReceiver.error || null})')
                args.evidence.write_text(json.dumps(result, indent=2))
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
