"""Direct-distribution inputs; the checked-in App Store configuration stays intact."""
import hashlib
import pathlib
import plistlib
import re

BUNDLE_ID = 'dev.vsmirn0v.conferenceguest.nativeguest'
APP_NAME = "Rock'N'Roll for Mac"
APP_BUNDLE_NAME = APP_NAME + '.app'
# The executable and code identity remain stable across the product rename.
EXECUTABLE_NAME = 'RockNRoll Native Guest'
LEGACY_APP_BUNDLE_NAME = EXECUTABLE_NAME + '.app'
TEAM_ID = '5V64BP2H3P'
FEED_URL = 'https://rock.glowsoft.ru/mac/appcast.xml'
PUBLIC_KEY = 'qDR0lWh9zJDV/twmkh1YKSngxxiQbHHDm7ARBuVFhkY='
KEYCHAIN_ACCOUNT = BUNDLE_ID + '.sparkle'
SPARKLE_VERSION = '2.10.0'
SPARKLE_BUILD = '2064'
SPARKLE_ARCHIVE_SHA256 = 'c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c'
SPARKLE_BINARY_SHA256 = 'a4b35bf38c12044686d0910dcb680560f1ff000061fbe19541c0b5e41c6c6008'
DIRECT_INFO = {
    'SUFeedURL': FEED_URL,
    'SUPublicEDKey': PUBLIC_KEY,
    'SUEnableInstallerLauncherService': True,
    'SURequireSignedFeed': True,
    'SUVerifyUpdateBeforeExtraction': True,
    'SUEnableAutomaticChecks': True,
    'SUAutomaticallyUpdate': True,
    'SUSendProfileInfo': False,
}


def find_application(directory):
    """Resolve an exported/archived app by identity, including historical names."""
    matches = []
    for app in pathlib.Path(directory).glob('*.app'):
        if app.is_symlink() or not app.is_dir():
            continue
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') == BUNDLE_ID:
            matches.append(app)
    if len(matches) != 1:
        raise ValueError('Expected exactly one native app with the configured bundle identity')
    return matches[0]


def application_executable(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != BUNDLE_ID or info.get('CFBundleExecutable') != EXECUTABLE_NAME:
        raise ValueError('Unexpected native app identity or executable')
    return app / 'Contents/MacOS' / EXECUTABLE_NAME


def installation_destination(directory, process_commands):
    """Preserve an existing name; never duplicate, overwrite strangers or a running app."""
    directory = pathlib.Path(directory)
    candidates = [directory / name for name in (APP_BUNDLE_NAME, LEGACY_APP_BUNDLE_NAME)]
    installed = []
    for app in candidates:
        if any(str(app / 'Contents/MacOS') + '/' in command for command in process_commands.splitlines()):
            raise ValueError('Close the installed native app before updating it')
        if app.is_symlink():
            raise ValueError('Refusing to replace a symbolic-link installation')
        if not app.exists():
            continue
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != BUNDLE_ID:
            raise ValueError('Refusing to replace an unrelated installed bundle')
        installed.append(app)
    if len(installed) > 1:
        raise ValueError('Both native app names are installed; resolve the duplicate before updating')
    return installed[0] if installed else candidates[0]


def installed_application(directory):
    app = installation_destination(directory, '')
    if not app.is_dir():
        raise ValueError('The native app is not installed')
    return app


def resolve_source_paths(root, spec):
    """Anchor formal source and file-setting paths to the checked-in spec."""
    source = pathlib.Path(root).resolve() / 'NativeMacGuest'
    spec = re.sub(r'(?m)^(\s*(?:- )?path: )(.+)$',
                  lambda match: match[1] + str((source / match[2]).resolve()), spec)
    for key in ('INFOPLIST_FILE', 'CODE_SIGN_ENTITLEMENTS', 'SWIFT_OBJC_BRIDGING_HEADER'):
        spec, count = re.subn(r'(?m)^(        ' + key + r': )(.+)$',
                             lambda match: match[1] + str((source / match[2]).resolve()), spec)
        if count != 1:
            raise ValueError(f'Expected one application {key} setting')
    return spec


def sha256(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def pinned_sparkle(root):
    bundle = root / '.build/native-dmg/Sparkle/Sparkle.framework'
    info = plistlib.loads((bundle / 'Resources/Info.plist').read_bytes())
    archive = root / f'.build/native-dmg/Sparkle-{SPARKLE_VERSION}.tar.xz'
    if (info.get('CFBundleShortVersionString') != SPARKLE_VERSION or
            info.get('CFBundleVersion') != SPARKLE_BUILD or
            sha256(bundle / 'Sparkle') != SPARKLE_BINARY_SHA256 or
            sha256(archive) != SPARKLE_ARCHIVE_SHA256):
        raise ValueError('Sparkle does not match the pinned 2.10.0 distribution')
    return bundle, {'version': SPARKLE_VERSION, 'build': SPARKLE_BUILD,
                    'archiveSHA256': SPARKLE_ARCHIVE_SHA256,
                    'binarySHA256': SPARKLE_BINARY_SHA256}


def configure_distribution(root, spec_dir, spec, distribution):
    # XcodeGen recursively includes the app directory; tooling is never a resource.
    spec = spec.replace('Tests, __pycache__, NativeGuest.entitlements',
                        'Tests, distribution, __pycache__, NativeGuest.entitlements')
    if distribution == 'app-store':
        return spec, None, []
    bundle, evidence = pinned_sparkle(root)
    info = plistlib.loads((root / 'NativeMacGuest/Info.plist').read_bytes())
    info.update(DIRECT_INFO)
    entitlements = plistlib.loads((root / 'NativeMacGuest/NativeGuest.entitlements').read_bytes())
    entitlements['com.apple.security.temporary-exception.mach-lookup.global-name'] = [
        BUNDLE_ID + '-spks', BUNDLE_ID + '-spki']
    info_path = spec_dir / 'Info-Direct.plist'
    entitlements_path = spec_dir / 'NativeGuest-Direct.entitlements'
    info_path.write_bytes(plistlib.dumps(info))
    entitlements_path.write_bytes(plistlib.dumps(entitlements))
    for key, path in [('INFOPLIST_FILE', info_path), ('CODE_SIGN_ENTITLEMENTS', entitlements_path)]:
        spec, count = re.subn(r'(?m)^(        ' + key + r': ).*$',
                              lambda match: match[1] + str(path), spec)
        if count != 1:
            raise ValueError(f'Expected one application {key} setting')
    anchor = '        product: LiveKitWebRTC\n'
    if spec.count(anchor) != 1:
        raise ValueError('Expected one application LiveKitWebRTC dependency')
    spec = spec.replace(anchor, anchor + f'      - framework: {bundle}\n'
                        '        embed: true\n        codeSign: true\n')
    resource_anchors = ['      - path: ../Experiments/NativeGuest\n',
                        f'      - path: {root / "Experiments/NativeGuest"}\n']
    if sum(spec.count(anchor) for anchor in resource_anchors) != 1:
        raise ValueError('Expected one NativeGuest source resource anchor')
    resource_anchor = next(anchor for anchor in resource_anchors if anchor in spec)
    spec = spec.replace(resource_anchor, '      - path: ' + str(root / 'NativeMacGuest/distribution/Sparkle-LICENSE.txt') + '\n        buildPhase: resources\n' + resource_anchor, 1)
    test_anchor = '      - target: RockNRollNativeGuest\n'
    spec = spec.replace(test_anchor, test_anchor + f'      - framework: {bundle}\n        embed: false\n')
    test_settings = '        PRODUCT_BUNDLE_IDENTIFIER: dev.vsmirn0v.conferenceguest.nativeguest.tests\n'
    spec = spec.replace(test_settings, test_settings + '        SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) NATIVE_DIRECT_UPDATES"\n')
    anchor = '        PRODUCT_MODULE_NAME: RockNativeDesktop\n'
    if spec.count(anchor) != 1:
        raise ValueError('Expected one application module setting')
    spec = spec.replace(anchor, anchor + '        SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) NATIVE_DIRECT_UPDATES"\n')
    return spec, evidence, [info_path, entitlements_path]
