#!/usr/bin/env python3
"""Signs a speech-model catalog for rock.glowsoft.ru/mac/models.json.

The app accepts a downloaded catalog only when the update key (the same Ed25519 key
Sparkle uses for the appcast) signed its exact bytes, its schemaVersion and runtime
match the bundled catalog, its revision is higher, and every file is pinned by SHA-256.

    python3 NativeMacGuest/distribution/sign-catalog.py NativeMacGuest/Attention/ListenModels.json --output OUT

writes OUT/models.json and OUT/models.json.sig (base64). Upload both to /mac/ next to
appcast.xml; nothing else changes on the server.
"""
import argparse
import base64
import json
import pathlib
import re
import shutil
import subprocess

from build_support import KEYCHAIN_ACCOUNT, PUBLIC_KEY, pinned_sparkle

ROOT = pathlib.Path(__file__).resolve().parents[2]
BUNDLED = ROOT / 'NativeMacGuest/Attention/ListenModels.json'


def check(catalog, bundled):
    if catalog.get('schemaVersion') != bundled.get('schemaVersion') or catalog.get('runtime') != bundled.get('runtime'):
        raise ValueError('schemaVersion and runtime must match the bundled catalog')
    if not isinstance(catalog.get('revision'), int) or catalog['revision'] <= bundled.get('revision', 0):
        raise ValueError('revision must be an integer above the bundled catalog revision')
    for model in catalog.get('models', []):
        for file in model.get('files', []):
            if not re.fullmatch(r'[0-9a-f]{64}', file.get('sha256', '')):
                raise ValueError(f"{model.get('id')}/{file.get('name')} is not pinned by SHA-256")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('catalog', type=pathlib.Path)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    data = args.catalog.read_bytes()
    if len(data) > 262144:
        raise ValueError('catalog exceeds 256 KB')
    check(json.loads(data), json.loads(BUNDLED.read_bytes()))
    pinned_sparkle(ROOT)
    tools = ROOT / '.build/native-dmg/Sparkle/bin'
    public = subprocess.run([tools / 'generate_keys', '--account', KEYCHAIN_ACCOUNT, '-p'],
                            check=True, capture_output=True, text=True).stdout.strip()
    if public != PUBLIC_KEY:
        raise ValueError('The Keychain account does not match the app’s public update key')
    args.output.mkdir(parents=True, exist_ok=False)
    target = args.output / 'models.json'
    shutil.copyfile(args.catalog, target)
    sign = [tools / 'sign_update', '--account', KEYCHAIN_ACCOUNT]
    signature = subprocess.run(sign + ['-p', target], check=True, capture_output=True, text=True).stdout.strip()
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError('Invalid signature')
    subprocess.run(sign + ['--verify', target, signature], check=True)
    (args.output / 'models.json.sig').write_text(signature + '\n')
    print(f'Signed {target} ({len(data)} bytes)')


if __name__ == '__main__':
    main()
