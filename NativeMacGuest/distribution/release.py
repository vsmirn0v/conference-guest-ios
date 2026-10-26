#!/usr/bin/env python3
"""Prepare verified local direct releases. This tool never publishes to a server."""
import argparse
import base64
import datetime
import email.utils
import fnmatch
import json
import os
import pathlib
import plistlib
import re
import subprocess
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET

from build_support import APP_NAME, BUNDLE_ID, DIRECT_INFO, FEED_URL, KEYCHAIN_ACCOUNT, PUBLIC_KEY, TEAM_ID, find_application, pinned_sparkle, sha256

ROOT = pathlib.Path(__file__).resolve().parents[2]
ORIGIN = 'https://rock.glowsoft.ru'
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NS)
ENV = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')


def run(command, *, capture=False, check=True):
    return subprocess.run([str(x) for x in command], env=ENV, check=check,
                          capture_output=capture, text=True)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def inspect_app(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != BUNDLE_ID:
        raise ValueError('Unexpected app bundle identity')
    for key, value in DIRECT_INFO.items():
        if info.get(key) != value:
            raise ValueError(f'Direct app has an unexpected {key}')
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    if (not isinstance(version, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', version)
            or not isinstance(build, str) or not build.isdecimal() or int(build) < 1):
        raise ValueError('Version/build cannot form an immutable release filename')
    if not (app / 'Contents/Frameworks/Sparkle.framework').is_dir():
        raise ValueError('Direct app does not embed Sparkle')
    run(['codesign', '--verify', '--deep', '--strict', app])
    details = run(['codesign', '-dv', '--verbose=4', app], capture=True)
    signing_lines = details.stderr.splitlines()
    runtime = re.search(r'(?m)^CodeDirectory .*flags=(0x[0-9a-fA-F]+)\(', details.stderr)
    if (f'TeamIdentifier={TEAM_ID}' not in signing_lines or f'Identifier={BUNDLE_ID}' not in signing_lines or
            'Authority=Developer ID Application:' not in details.stderr or
            runtime is None or not int(runtime[1], 16) & 0x10000):
        raise ValueError('The exported app must carry this team’s Developer ID signature')
    entitlement_result = run(['codesign', '-d', '--entitlements', ':-', app], capture=True)
    entitlements = plistlib.loads(entitlement_result.stdout.encode())
    required = {'com.apple.security.app-sandbox': True,
                'com.apple.developer.icloud-container-environment': 'Production',
                'com.apple.developer.aps-environment': 'production',
                'com.apple.developer.team-identifier': TEAM_ID}
    for key, value in required.items():
        if entitlements.get(key) != value:
            raise ValueError(f'Unexpected exported entitlement: {key}')
    arrays = {'com.apple.security.application-groups': ['group.dev.vsmirn0v.conferenceguest'],
              'com.apple.developer.icloud-container-identifiers': ['iCloud.dev.vsmirn0v.conferenceguest'],
              'com.apple.developer.icloud-services': ['CloudKit']}
    for key, values in arrays.items():
        if entitlements.get(key) != values:
            raise ValueError(f'Unexpected exported entitlement: {key}')
    if entitlements.get('get-task-allow') or entitlements.get('com.apple.security.get-task-allow'):
        raise ValueError('The exported app must not allow debugging')
    names = entitlements.get('com.apple.security.temporary-exception.mach-lookup.global-name', [])
    if not {BUNDLE_ID + '-spks', BUNDLE_ID + '-spki'}.issubset(names):
        raise ValueError('Sparkle sandbox mach-lookup exceptions are missing')
    profile_path = app / 'Contents/embedded.provisionprofile'
    profile_result = run(['security', 'cms', '-D', '-i', profile_path], capture=True)
    profile = plistlib.loads(profile_result.stdout.encode())
    if TEAM_ID not in profile.get('TeamIdentifier', []):
        raise ValueError('The exported provisioning profile belongs to a different team')
    authorized = profile.get('Entitlements', {})
    for key, values in {**{key: [value] for key, value in required.items() if key != 'com.apple.security.app-sandbox'},
                        **arrays}.items():
        permitted = authorized.get(key, [])
        permitted = [permitted] if isinstance(permitted, str) else permitted
        if not all(any(fnmatch.fnmatchcase(value, pattern) for pattern in permitted) for value in values):
            raise ValueError(f'Exported profile does not authorize {key}')
    application_id = authorized.get('com.apple.application-identifier', authorized.get('application-identifier', ''))
    if not fnmatch.fnmatchcase(TEAM_ID + '.' + BUNDLE_ID, application_id):
        raise ValueError('Exported profile does not authorize the app identity')
    return info


def assess_app(app):
    info = inspect_app(app)
    run(['xcrun', 'stapler', 'validate', app])
    run(['spctl', '--assess', '--type', 'execute', '--verbose=2', app])
    return info


def export_app(args):
    archive = args.archive.resolve()
    archived_app = find_application(archive / 'Products/Applications')
    archived_info = plistlib.loads((archived_app / 'Contents/Info.plist').read_bytes())
    if archived_info.get('CFBundleIdentifier') != BUNDLE_ID or archived_info.get('SUFeedURL') != FEED_URL:
        raise ValueError('Use an archive built with --distribution direct --configuration Release')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    options = {'method': 'developer-id', 'destination': 'upload', 'signingStyle': 'automatic',
               'teamID': TEAM_ID, 'iCloudContainerEnvironment': 'Production',
               'manageAppVersionAndBuildNumber': False}
    options_path = output / 'DeveloperIDUpload.plist'
    options_path.write_bytes(plistlib.dumps(options))
    # Xcode's signed-in account handles its cloud-managed Developer ID certificate
    # and notarization. No exportable private identity or notarytool password is needed.
    run(['xcodebuild', '-exportArchive', '-archivePath', archive, '-exportOptionsPlist', options_path,
         '-exportPath', output / 'Upload', '-allowProvisioningUpdates'])
    finalize_export(args)


def finalize_export(args):
    """Resume an accepted upload without submitting the archive again."""
    archive, output = args.archive.resolve(), args.output.resolve()
    if not output.is_dir():
        raise ValueError('Finalize requires the existing export output directory')
    archived_app = find_application(archive / 'Products/Applications')
    archived_info = plistlib.loads((archived_app / 'Contents/Info.plist').read_bytes())
    if archived_info.get('CFBundleIdentifier') != BUNDLE_ID or archived_info.get('SUFeedURL') != FEED_URL:
        raise ValueError('Finalize requires a direct Release archive')
    expected_pending = f'error: Archive "{archive.name}" is processing and not ready for distribution.'
    deadline = time.monotonic() + args.wait_seconds
    log_prefix = 'finalize-' + uuid.uuid4().hex[:12]
    attempt = 0
    while True:
        attempt += 1
        result = run(['xcodebuild', '-exportNotarizedApp', '-archivePath', archive,
                      '-exportPath', output / 'App', '-allowProvisioningUpdates'], capture=True, check=False)
        log_path = output / f'{log_prefix}-{attempt:03d}.log'
        log_path.write_text(result.stdout + result.stderr)
        if result.returncode == 0:
            break
        # This exact Xcode diagnostic is a machine command's defined failure
        # format; other exit-65 errors must never be retried as pending work.
        diagnostics = [line.strip() for line in (result.stdout + result.stderr).splitlines()
                       if line.strip().startswith('error:')]
        if result.returncode != 65 or diagnostics != [expected_pending]:
            raise ValueError(f'Notarized export failed; see {log_path}')
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f'Archive is still processing; resume with finalize. See {log_path}')
        if attempt == 1:
            print(f'Archive is processing; retrying every 30 seconds for up to {args.wait_seconds} seconds.', flush=True)
        time.sleep(min(30, remaining))
    app = find_application(output / 'App')
    run(['xcrun', 'stapler', 'staple', app])
    info = assess_app(app)
    if (info['CFBundleVersion'] != archived_info['CFBundleVersion'] or
            info['CFBundleShortVersionString'] != archived_info['CFBundleShortVersionString']):
        raise ValueError('Notarized export version/build differs from the archive')
    write_json(output / 'export-evidence.json', {
        'archive': str(archive), 'app': str(app), 'version': info['CFBundleShortVersionString'],
        'build': info['CFBundleVersion'], 'bundleIdentifier': BUNDLE_ID,
        'notarization': 'xcode-cloud-account', 'appStapleValidated': True,
        'gatekeeperExecuteAccepted': True})
    print(app)


def package_app(args):
    app = args.app.resolve()
    info = assess_app(app)
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    dmg = output / f'RockNRoll-{version}-{build}-arm64.dmg'
    with tempfile.TemporaryDirectory(prefix='rock-native-dmg-') as temp:
        staging = pathlib.Path(temp) / 'Staging'
        staging.mkdir()
        run(['ditto', app, staging / app.name])
        (staging / 'Applications').symlink_to('/Applications', target_is_directory=True)
        notices = pathlib.Path(__file__).with_name('Sparkle-LICENSE.txt').read_bytes()
        (staging / 'Third-Party-Notices.txt').write_bytes(notices)
        run(['hdiutil', 'create', '-volname', APP_NAME, '-srcfolder', staging,
             '-format', 'UDZO', '-ov', dmg])
        if args.dmg_identity:
            run(['codesign', '--sign', args.dmg_identity, '--timestamp', dmg])
        if args.notary_profile:
            run(['xcrun', 'notarytool', 'submit', dmg, '--keychain-profile', args.notary_profile,
                 '--wait', '--output-format', 'json'])
            run(['xcrun', 'stapler', 'staple', dmg])
            run(['xcrun', 'stapler', 'validate', dmg])
        run(['hdiutil', 'verify', dmg])
        mount = pathlib.Path(temp) / 'Mounted'
        mount.mkdir()
        run(['hdiutil', 'attach', dmg, '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', mount])
        try:
            mounted_info = assess_app(mount / app.name)
            if mounted_info != info or (mount / 'Applications').readlink() != pathlib.Path('/Applications'):
                raise ValueError('Mounted disk image does not match the verified app/install target')
            if (mount / 'Third-Party-Notices.txt').read_bytes() != notices:
                raise ValueError('Mounted disk image is missing the Sparkle third-party notices')
        finally:
            run(['hdiutil', 'detach', mount])
    assessment = run(['spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature',
                      '--verbose=2', dmg], capture=True, check=False)
    evidence = {'schemaVersion': 1, 'version': version, 'build': build, 'file': dmg.name,
                'downloadURL': ORIGIN + '/mac/releases/' + dmg.name, 'sha256': sha256(dmg),
                'length': dmg.stat().st_size, 'bundleIdentifier': BUNDLE_ID,
                'appStapleValidated': True, 'gatekeeperExecuteAccepted': True,
                'outerDMGNotarized': bool(args.notary_profile),
                'outerDMGAssessmentAccepted': assessment.returncode == 0,
                'outerDMGAssessment': (assessment.stdout + assessment.stderr).strip()}
    write_json(output / 'release.json', evidence)
    print(output / 'release.json')


def read_json(path, limit=65536):
    if path.stat().st_size > limit:
        raise ValueError('Release metadata exceeds its size limit')
    return json.loads(path.read_text())


def item_channel(item):
    return item.findtext(f'{{{NS}}}channel') or 'stable'


def prepare_feed(args):
    pinned_sparkle(ROOT)
    tools = ROOT / '.build/native-dmg/Sparkle/bin'
    public = run([tools / 'generate_keys', '--account', KEYCHAIN_ACCOUNT, '-p'], capture=True).stdout.strip()
    if public != PUBLIC_KEY:
        raise ValueError('The Keychain account does not match the app’s public update key')
    release_path = args.release.resolve()
    release = read_json(release_path)
    version, build = release['version'], release['build']
    if (not isinstance(version, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', version)
            or not isinstance(build, str) or not build.isdecimal() or int(build) < 1):
        raise ValueError('Invalid release version/build')
    filename = f'RockNRoll-{version}-{build}-arm64.dmg'
    dmg = release_path.parent / filename
    url = ORIGIN + '/mac/releases/' + filename
    if (release.get('file') != filename or release.get('downloadURL') != url or
            release.get('sha256') != sha256(dmg) or release.get('length') != dmg.stat().st_size or
            release.get('bundleIdentifier') != BUNDLE_ID or not release.get('appStapleValidated') or
            not release.get('gatekeeperExecuteAccepted')):
        raise ValueError('Release evidence does not match the verified immutable disk image')
    inventory = read_json(args.previous_inventory) if args.previous_inventory else {'schemaVersion': 1}
    previous_channels = [inventory[name] for name in ['stable', 'beta'] if name in inventory]
    if (len(previous_channels) == 2 and previous_channels[0]['build'] == previous_channels[1]['build'] and
            any(previous_channels[0][key] != previous_channels[1][key] for key in ['downloadURL', 'sha256'])):
        raise ValueError('A build number identifies different inventory artifacts across channels')
    for previous in previous_channels:
        if previous['build'] == build and (previous['downloadURL'] != url or previous['sha256'] != release['sha256']):
            raise ValueError('A build number already identifies a different inventory artifact')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    sign = [tools / 'sign_update', '--account', KEYCHAIN_ACCOUNT]
    signature = run(sign + ['-p', dmg], capture=True).stdout.strip()
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError('Invalid Sparkle artifact signature')
    run(sign + ['--verify', dmg, signature])
    if args.previous_feed:
        if args.previous_feed.stat().st_size > 262144:
            raise ValueError('Previous appcast exceeds its size limit')
        run(sign + ['--verify', args.previous_feed])
        rss = ET.parse(args.previous_feed).getroot()
        channel = rss.find('channel')
        if rss.tag != 'rss' or channel is None:
            raise ValueError('Invalid previous appcast')
    else:
        rss = ET.Element('rss', {'version': '2.0'})
        channel = ET.SubElement(rss, 'channel')
        ET.SubElement(channel, 'title').text = APP_NAME
        ET.SubElement(channel, 'link').text = ORIGIN
        ET.SubElement(channel, 'description').text = 'Signed Apple Silicon Mac app updates.'
        ET.SubElement(channel, 'language').text = 'en'
    title = channel.find('title')
    if title is None:
        title = ET.SubElement(channel, 'title')
    title.text = APP_NAME
    for old in list(channel.findall('item')):
        enclosure = old.find('enclosure')
        if enclosure is None or item_channel(old) not in {'stable', 'beta'}:
            raise ValueError('Unexpected previous appcast entry')
        if not enclosure.get('url', '').startswith(ORIGIN + '/mac/releases/RockNRoll-'):
            raise ValueError('Previous appcast points outside the release directory')
        if enclosure.get(f'{{{NS}}}version') == build and (
                enclosure.get('url') != url or enclosure.get(f'{{{NS}}}edSignature') != signature or
                enclosure.get('length') != str(dmg.stat().st_size)):
            raise ValueError('A build number already identifies a different feed artifact across channels')
        if item_channel(old) == args.channel and enclosure.get(f'{{{NS}}}version') == build:
            channel.remove(old)
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f'{APP_NAME} {version} ({build})'
    ET.SubElement(item, 'pubDate').text = email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc))
    ET.SubElement(item, f'{{{NS}}}minimumSystemVersion').text = '13.0'
    ET.SubElement(item, f'{{{NS}}}hardwareRequirements').text = 'arm64'
    if args.channel == 'beta':
        ET.SubElement(item, f'{{{NS}}}channel').text = 'beta'
    ET.SubElement(item, 'enclosure', {'url': url, 'length': str(dmg.stat().st_size),
                  'type': 'application/octet-stream', f'{{{NS}}}version': build,
                  f'{{{NS}}}shortVersionString': version, f'{{{NS}}}edSignature': signature})
    # Retain six complete releases per channel. Newest build is selected first.
    items = sorted(channel.findall('item'),
                   key=lambda entry: int(entry.find('enclosure').get(f'{{{NS}}}version')), reverse=True)
    counts = {'stable': 0, 'beta': 0}
    for entry in items:
        channel.remove(entry)
        name = item_channel(entry)
        counts[name] += 1
        if counts[name] <= 6:
            channel.append(entry)
    appcast = output / 'appcast.xml'
    ET.indent(rss)
    ET.ElementTree(rss).write(appcast, encoding='utf-8', xml_declaration=True)
    run(sign + [appcast])
    run(sign + ['--verify', appcast])
    entry = {key: release[key] for key in ['version', 'build', 'downloadURL', 'sha256']}
    if args.channel in inventory and int(inventory[args.channel]['build']) > int(build):
        raise ValueError('Refusing to move a release channel backwards')
    inventory[args.channel] = entry
    if 'stable' not in inventory:
        raise ValueError('Prepare the initial stable release before a beta')
    if 'beta' not in inventory or (args.channel == 'stable' and int(inventory['beta']['build']) < int(build)):
        inventory['beta'] = entry
    write_json(output / 'latest.json', inventory)
    print(appcast)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    export = commands.add_parser('export', help='Cloud-sign, notarize and export an existing direct Release archive')
    export.add_argument('--archive', type=pathlib.Path, required=True)
    export.add_argument('--output', type=pathlib.Path, required=True)
    export.add_argument('--wait-seconds', type=int, default=1800, help='Retry only pending notarization, from 0 to 1800 seconds')
    export.set_defaults(action=export_app)
    finalize = commands.add_parser('finalize', help='Resume notarized export of an accepted upload without re-uploading')
    finalize.add_argument('--archive', type=pathlib.Path, required=True)
    finalize.add_argument('--output', type=pathlib.Path, required=True)
    finalize.add_argument('--wait-seconds', type=int, default=1800, help='Retry only pending notarization, from 0 to 1800 seconds')
    finalize.set_defaults(action=finalize_export)
    package = commands.add_parser('package', help='Create a DMG around a verified notarized app')
    package.add_argument('--app', type=pathlib.Path, required=True)
    package.add_argument('--output', type=pathlib.Path, required=True)
    package.add_argument('--dmg-identity', help='Optional locally available Developer ID identity for the outer image')
    package.add_argument('--notary-profile', help='Optional existing notarytool Keychain profile for the outer image')
    package.set_defaults(action=package_app)
    feed = commands.add_parser('feed', help='Sign the immutable DMG and public appcast using the existing Keychain key')
    feed.add_argument('--release', type=pathlib.Path, required=True)
    feed.add_argument('--channel', choices=('stable', 'beta'), required=True)
    feed.add_argument('--output', type=pathlib.Path, required=True)
    feed.add_argument('--previous-feed', type=pathlib.Path)
    feed.add_argument('--previous-inventory', type=pathlib.Path)
    feed.set_defaults(action=prepare_feed)
    args = parser.parse_args()
    if args.command in {'export', 'finalize'} and not 0 <= args.wait_seconds <= 1800:
        parser.error('--wait-seconds must be between 0 and 1800')
    if args.command == 'feed' and bool(args.previous_feed) != bool(args.previous_inventory):
        parser.error('Provide both previous feed and inventory, or neither for the first release')
    try:
        args.action(args)
    except (ValueError, OSError, subprocess.CalledProcessError, ET.ParseError) as error:
        raise SystemExit(str(error)) from error


if __name__ == '__main__':
    main()
