#!/usr/bin/env python3
"""Sign an author-approved complete catalog with the dedicated local Keychain key."""
import argparse
import base64
import json
from pathlib import Path
import subprocess
import tempfile

ACCOUNT = 'dev.vsmirn0v.rocknroll.support.catalog'
PUBLIC_KEY = 'EqdxgBL6FZiCOOgihOjJkl6bG9SytDodMRE4iB3WTnE='


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--sparkle-bin', required=True, type=Path)
    args = parser.parse_args()
    catalog = json.loads(args.source.read_bytes())
    if catalog['schema'] != 1 or catalog['kind'] != 'direct-mac-author-support':
        raise SystemExit('Unexpected catalog type')
    if args.output.exists():
        prior = json.loads(base64.b64decode(json.loads(args.output.read_bytes())['payload'], validate=True))
        if catalog['revision'] <= prior['revision']:
            raise SystemExit('Increase the catalog revision')
        def destinations(value):
            return {row['id']: row for row in value['tiers'] + value['destinations']}
        old, new = destinations(prior), destinations(catalog)
        retired = set(catalog['retired'])
        if not retired.issuperset(set(prior['retired']) | (old.keys() - new.keys())) or retired.intersection(new):
            raise SystemExit('Carry forward all retired and removed destination IDs')
        for key in old.keys() & new.keys():
            if any(old[key].get(field) != new[key].get(field) for field in ('url', 'method', 'amountRUB', 'checkoutURL')):
                raise SystemExit('A different route requires a new ID')
    public = subprocess.check_output([args.sparkle_bin / 'generate_keys', '--account', ACCOUNT, '-p'], text=True).strip()
    if public != PUBLIC_KEY:
        raise SystemExit('Unexpected signing key')
    payload = json.dumps(catalog, sort_keys=True, separators=(',', ':')).encode()
    with tempfile.TemporaryDirectory() as temp:
        path = Path(temp) / 'catalog.json'
        path.write_bytes(payload)
        tool = [args.sparkle_bin / 'sign_update', '--account', ACCOUNT]
        signature = subprocess.check_output([*tool, '-p', path], text=True).strip()
        subprocess.run([*tool, '--verify', path, signature], check=True)
    envelope = dict(payload=base64.b64encode(payload).decode(), signature=signature)
    args.output.write_text(json.dumps(envelope, separators=(',', ':')) + '\n')


if __name__ == '__main__':
    main()
