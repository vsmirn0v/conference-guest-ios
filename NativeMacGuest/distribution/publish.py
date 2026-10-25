#!/usr/bin/env python3
"""Verify and preflight a Mac release; --apply publishes only release files."""
import argparse
import hashlib
import json
import pathlib
import re
import shlex
import subprocess
import urllib.error
import urllib.request
import uuid
import xml.etree.ElementTree as ET

from build_support import KEYCHAIN_ACCOUNT, PUBLIC_KEY, pinned_sparkle, sha256
from release import BUNDLE_ID, NS, ORIGIN, ROOT, read_json, run

HOST = 'root@kachat.app'
SSH_OPTIONS = ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15']
STAGING_ROOT = '/var/www/rocknroll/.publish-stage'
ARTIFACT = re.compile(r'RockNRoll-[A-Za-z0-9][A-Za-z0-9._-]*-[0-9]+-arm64\.dmg')
HEX256 = re.compile(r'[a-f0-9]{64}')


def artifact_name(url):
    prefix = ORIGIN + '/mac/releases/'
    if not isinstance(url, str) or not url.startswith(prefix) or not ARTIFACT.fullmatch(url[len(prefix):]):
        raise ValueError('Release URL must name an immutable artifact on rock.glowsoft.ru')
    return url[len(prefix):]


def local_plan(args):
    pinned_sparkle(ROOT)
    tools = ROOT / '.build/native-dmg/Sparkle/bin'
    public = run([tools / 'generate_keys', '--account', KEYCHAIN_ACCOUNT, '-p'], capture=True).stdout.strip()
    if public != PUBLIC_KEY:
        raise ValueError('The Keychain public key differs from the app update key')
    if args.feed.stat().st_size > 262144:
        raise ValueError('Appcast exceeds its size limit')
    sign = [tools / 'sign_update', '--account', KEYCHAIN_ACCOUNT, '--verify']
    run(sign + [args.feed])
    release = read_json(args.package / 'release.json')
    filename = artifact_name(release['downloadURL'])
    if filename != f"RockNRoll-{release['version']}-{release['build']}-arm64.dmg" or filename != release['file']:
        raise ValueError('Package filename differs from its version/build')
    dmg = args.package / filename
    if (release.get('sha256') != sha256(dmg) or release.get('length') != dmg.stat().st_size or
            release.get('bundleIdentifier') != BUNDLE_ID or
            not release.get('appStapleValidated') or not release.get('gatekeeperExecuteAccepted')):
        raise ValueError('Package evidence does not match the verified disk image')
    inventory = read_json(args.inventory)
    if set(inventory) != {'schemaVersion', 'stable', 'beta'} or inventory['schemaVersion'] != 1:
        raise ValueError('Expected only schemaVersion, stable and beta release inventory fields')
    expanded = {'schemaVersion': 1}
    references_new = False
    for channel in ['stable', 'beta']:
        entry = inventory[channel]
        if set(entry) != {'version', 'build', 'downloadURL', 'sha256'}:
            raise ValueError('Unexpected release inventory fields')
        name = artifact_name(entry['downloadURL'])
        if (not isinstance(entry['build'], str) or not entry['build'].isdecimal() or int(entry['build']) < 1 or
                name != f"RockNRoll-{entry['version']}-{entry['build']}-arm64.dmg" or
                not isinstance(entry['sha256'], str) or not HEX256.fullmatch(entry['sha256'])):
            raise ValueError('Invalid channel version, filename or digest')
        expanded[channel] = dict(entry, file=name)
        if name == filename:
            references_new = True
            if entry['sha256'] != release['sha256']:
                raise ValueError('Inventory digest differs from the new artifact')
    if not references_new:
        raise ValueError('Neither release channel references the new artifact')
    if expanded['stable']['build'] == expanded['beta']['build'] and any(
            expanded['stable'][key] != expanded['beta'][key] for key in ['downloadURL', 'sha256']):
        raise ValueError('Equal channel build numbers identify different artifacts')
    rss = ET.parse(args.feed).getroot()
    channel = rss.find('channel')
    if rss.tag != 'rss' or channel is None:
        raise ValueError('Invalid appcast structure')
    entries = channel.findall('item')
    if not 1 <= len(entries) <= 12:
        raise ValueError('Expected between one and twelve complete appcast entries')
    feed_artifacts, found_new, feed_channels, build_identities = [], False, {}, {}
    for item in entries:
        enclosure = item.find('enclosure')
        if enclosure is None or (item.findtext(f'{{{NS}}}channel') or 'stable') not in {'stable', 'beta'}:
            raise ValueError('Unexpected feed channel or enclosure')
        name = artifact_name(enclosure.get('url'))
        length = int(enclosure.get('length', '0'))
        if length < 1:
            raise ValueError('Invalid feed enclosure length')
        feed_artifacts.append({'file': name, 'length': length})
        build_number = enclosure.get(f'{{{NS}}}version')
        if not build_number or not build_number.isdecimal() or int(build_number) < 1:
            raise ValueError('Feed enclosure has an invalid build number')
        identity = (enclosure.get('url'), enclosure.get(f'{{{NS}}}edSignature'), length)
        if build_number in build_identities and build_identities[build_number] != identity:
            raise ValueError('Equal feed build numbers identify different artifacts across channels')
        build_identities[build_number] = identity
        feed_channels.setdefault(name, set()).add(item.findtext(f'{{{NS}}}channel') or 'stable')
        if name == filename:
            found_new = True
            if (length != dmg.stat().st_size or enclosure.get(f'{{{NS}}}version') != release['build'] or
                    enclosure.get(f'{{{NS}}}shortVersionString') != release['version']):
                raise ValueError('Feed enclosure does not match the new artifact')
            signature = enclosure.get(f'{{{NS}}}edSignature')
            if not signature:
                raise ValueError('Feed enclosure lacks its update signature')
            run(sign + [dmg, signature])
    if not found_new:
        raise ValueError('The appcast does not contain the new artifact')
    for name in ['stable', 'beta']:
        channels = feed_channels.get(expanded[name]['file'], set())
        if (name == 'stable' and 'stable' not in channels) or (name == 'beta' and not channels):
            raise ValueError('Inventory channel is not offered by the signed appcast')
    return {'artifact': {'file': filename, 'sha256': release['sha256'], 'length': dmg.stat().st_size},
            'inventory': expanded, 'feedArtifacts': feed_artifacts,
            'feedSHA256': sha256(args.feed), 'inventorySHA256': sha256(args.inventory)}, dmg


def remote(operation, plan):
    helper = pathlib.Path(__file__).with_name('publish_remote.py').read_text()
    request = json.dumps({'operation': operation, 'plan': plan}, separators=(',', ':'))
    command = 'python3 - ' + shlex.quote(request)
    result = subprocess.run(['ssh', *SSH_OPTIONS, HOST, command], input=helper, text=True,
                            capture_output=True, check=False)
    if result.returncode:
        raise ValueError('Remote ' + operation + ' failed: ' + result.stderr.strip())
    return json.loads(result.stdout)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


def public_digest(url, expected_length, expected_hash, cache_policy):
    request = urllib.request.Request(url, headers={'Cache-Control': 'no-cache', 'User-Agent': 'RockNRoll-release-verification/1'})
    opener = urllib.request.build_opener(NoRedirect())
    result, count = hashlib.sha256(), 0
    with opener.open(request, timeout=60) as response:
        if response.status != 200 or cache_policy not in response.headers.get('Cache-Control', '').lower():
            raise ValueError('Unexpected HTTPS status or cache policy for ' + url)
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            count += len(chunk)
            if count > expected_length:
                raise ValueError('HTTPS response exceeds its expected length: ' + url)
            result.update(chunk)
    if count != expected_length or result.hexdigest() != expected_hash:
        raise ValueError('HTTPS artifact or metadata hash differs: ' + url)


def verify_public(args, plan):
    artifact = plan['artifact']
    public_digest(ORIGIN + '/mac/releases/' + artifact['file'], artifact['length'], artifact['sha256'], 'immutable')
    public_digest(ORIGIN + '/mac/appcast.xml', args.feed.stat().st_size, plan['feedSHA256'], 'no-store')
    public_digest(ORIGIN + '/mac/latest.json', args.inventory.stat().st_size, plan['inventorySHA256'], 'no-store')
    lengths = {entry['file']: entry['length'] for entry in plan['feedArtifacts']}
    for channel in ['stable', 'beta']:
        entry = plan['inventory'][channel]
        if entry['file'] not in lengths:
            raise ValueError('Channel alias is missing from the signed appcast')
        public_digest(ORIGIN + f'/mac/{channel}/latest.dmg', lengths[entry['file']], entry['sha256'], 'no-store')


def publish(args):
    plan, dmg = local_plan(args)
    result = remote('preflight', plan)
    print('Local signatures/digests verified; remote preflight passed for ' + plan['artifact']['file'], flush=True)
    if not args.apply:
        print('Read-only preflight complete. Use --apply to publish the verified release files.', flush=True)
        return
    plan['expectedState'] = result['state']
    plan['stageID'] = uuid.uuid4().hex
    remote('stage', plan)
    stage = STAGING_ROOT + '/' + plan['stageID']
    for source, name in [(dmg, plan['artifact']['file']), (args.feed, 'appcast.xml'), (args.inventory, 'latest.json')]:
        subprocess.run(['scp', *SSH_OPTIONS, str(source.resolve()), HOST + ':' + stage + '/' + name], check=True)
    published = remote('apply', plan)
    try:
        verify_public(args, plan)
    except (ValueError, OSError, urllib.error.URLError) as error:
        raise ValueError('Release files were installed, but HTTPS verification failed. Backup: ' +
                         published['backupDirectory'] + '. ' + str(error)) from error
    evidence = {'host': HOST, 'publicRoot': '/var/www/rocknroll/releases',
                'artifact': plan['artifact'], 'state': published['state'],
                'backupDirectory': published['backupDirectory'], 'httpsVerified': True}
    if args.evidence:
        with args.evidence.open('x') as stream:
            json.dump(evidence, stream, indent=2)
            stream.write('\n')
    print(json.dumps(evidence, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--feed', type=pathlib.Path, required=True)
    parser.add_argument('--inventory', type=pathlib.Path, required=True)
    parser.add_argument('--package', type=pathlib.Path, required=True, help='Directory containing the DMG and release.json')
    parser.add_argument('--apply', action='store_true', help='Publish the verified release files over the existing SSH connection')
    parser.add_argument('--evidence', type=pathlib.Path, help='New local evidence file after successful HTTPS verification')
    args = parser.parse_args()
    try:
        publish(args)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError, ET.ParseError) as error:
        raise SystemExit(str(error)) from error


if __name__ == '__main__':
    main()
