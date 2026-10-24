#!/usr/bin/env python3
"""Provision/build the external Mac companion; never modify the iOS app bundle."""
import argparse, hashlib, json, os, pathlib, plistlib, re, shutil, subprocess, tempfile
ROOT = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--identity', required=True, help='Apple Development signing identity for the final provisioned bundle')
p.add_argument('--install', action='store_true', help='Install the verified build in /Applications (required by the host sandbox)')
p.add_argument('--allow-provisioning-updates', action='store_true', help='Allow Xcode to register/update the Mac app-group profile')
p.add_argument('--framework-root', type=pathlib.Path, default=ROOT/'.build/webrtc-m156-desktop-audio/native-framework-r4',
               help='Directory containing LiveKitWebRTC.xcframework and build-evidence.json')
p.add_argument('--output-dir', type=pathlib.Path, default=ROOT/'.build/native-mac-guest')
p.add_argument('--configuration', choices=('Debug', 'Release'), default='Debug')
p.add_argument('--version', default='0.1')
p.add_argument('--build-number', default='1')
p.add_argument('--archive', action='store_true', help='Create an Xcode archive for later TestFlight distribution')
a = p.parse_args()
if not a.version or not a.build_number.isdecimal() or int(a.build_number) < 1:
    raise SystemExit('A nonempty version and positive numeric build number are required')
build = a.output_dir.resolve()
archive = build/(f'RockNRollNativeGuest-{a.version}-{a.build_number}.xcarchive') if a.archive else None
project = build/'Project'; project.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
# The helper explicitly controls InputMixer mute. The shipping framework clears
# it on StartRecording; this isolated native artifact preserves that intent.
framework_root = a.framework_root.resolve()
framework_evidence = json.loads((framework_root/'build-evidence.json').read_text())
framework_binary = framework_root/'LiveKitWebRTC.xcframework/macos-arm64/LiveKitWebRTC.framework/LiveKitWebRTC'
if hashlib.sha256(framework_binary.read_bytes()).hexdigest() != framework_evidence['frameworkBinarySHA256']:
    raise SystemExit('Native InputMixer framework does not match its build evidence')
for resource in (ROOT/'RockNRoll/Assets.xcassets/AdditionalRootCA.dataset').iterdir():
    native_resource = ROOT/'NativeMacGuest/Assets.xcassets/AdditionalRootCA.dataset'/resource.name
    if resource.is_file() and (not native_resource.is_file() or native_resource.read_bytes() != resource.read_bytes()):
        raise SystemExit('Native public root certificate asset differs from its canonical shared resource')
spec_source = (ROOT/'NativeMacGuest/project.yml').read_text()
# Persist the requested identity in the generated project too. Otherwise a later
# build-for-testing silently restores the specification's development defaults.
spec_source = re.sub(r'(?m)^(\s*MARKETING_VERSION: ).*$', lambda m: m[1]+json.dumps(a.version), spec_source)
spec_source = re.sub(r'(?m)^(\s*CURRENT_PROJECT_VERSION: ).*$', lambda m: m[1]+json.dumps(a.build_number), spec_source)
dependency_root = build/'Dependencies'
subprocess.run(['python3',str(ROOT/'NativeMacGuest/prepare-livekit.py'),
                '--framework',str(framework_root/'LiveKitWebRTC.xcframework'),
                '--destination',str(dependency_root)],check=True,env=env)
for name in ['client-sdk-swift','webrtc-xcframework']:
    spec_source = spec_source.replace('../.build/native-desktop-dependencies/'+name,str(dependency_root/name))
# Resolve formal XcodeGen source/package paths from the checked-in specification,
# rather than relying on the generated project's directory depth.
spec_source = re.sub(r'(?m)^(\s*(?:- )?path: )(.+)$',
    lambda m: m[1]+str((ROOT/'NativeMacGuest'/m[2]).resolve()), spec_source)
spec_dir = build/'Spec'; spec_dir.mkdir(parents=True, exist_ok=True)
with tempfile.NamedTemporaryFile(mode='w', prefix='.native-guest-build-', suffix='.yml',
                                 dir=spec_dir, delete=False) as spec_file:
    spec_file.write(spec_source)
    generated_spec = pathlib.Path(spec_file.name)
try:
    subprocess.run(['xcodegen','generate','--spec',str(generated_spec),'--project',str(project)],env=env,check=True)
    cmd = ['xcodebuild','-project',str(project/'RockNativeGuest.xcodeproj'),'-scheme','RockNRollNativeGuest',
           '-configuration',a.configuration,'-destination','platform=macOS,arch=arm64','-derivedDataPath',str(build/'Xcode'),
           '-jobs','4',
           'MARKETING_VERSION='+a.version,'CURRENT_PROJECT_VERSION='+a.build_number]
    if a.allow_provisioning_updates: cmd.append('-allowProvisioningUpdates')
    subprocess.run(cmd+['build'],env=env,check=True)
    if a.archive:
        assert archive is not None
        if archive.exists(): raise SystemExit('Refusing to replace an existing archive')
        subprocess.run(cmd+['-archivePath',str(archive),'archive'],env=env,check=True)
finally:
    generated_spec.unlink(missing_ok=True)
app = build/'Xcode/Build/Products'/a.configuration/'RockNRoll Native Guest.app'
subprocess.run(['codesign','--force','--sign',a.identity,'--preserve-metadata=identifier,entitlements,flags,runtime',str(app)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
signature = subprocess.run(['codesign','-dv','--verbose=4',str(app)],capture_output=True,text=True,check=True)
if 'TeamIdentifier=5V64BP2H3P' not in signature.stderr:
    raise SystemExit('The selected signing certificate does not belong to the app-group provisioning team')
# This gate catches signatures that look valid but lack a provisioned app group.
executable = app/'Contents/MacOS/RockNRoll Native Guest'
subprocess.run([str(executable),'--check-container'],check=True)
sources = sorted(x for x in (ROOT/'Experiments/NativeGuest').glob('*.swift') if x.name not in {'Main.swift', 'GuestCompanionPeer.swift'})
sources += sorted(x for x in (ROOT/'NativeMacGuest').rglob('*.swift') if 'Tests' not in x.parts)
sources += [ROOT/'Shared/NativeGuestCompanionProtocol.swift', ROOT/'RockNRoll/NativeVideoPixelBuffer.swift']
for source in re.findall(r'(?m)^      - path: (\.\./.+)$', (ROOT/'NativeMacGuest/project.yml').read_text()):
    path = (ROOT/'NativeMacGuest'/source).resolve()
    if path.is_file(): sources.append(path)
    elif path.is_dir(): sources += sorted(x for x in path.rglob('*') if x.is_file() and '__pycache__' not in x.parts)
sources += sorted((ROOT/'ConferenceCore/Sources').rglob('*.swift'))+[ROOT/'ConferenceCore/Package.swift']
sources = sorted(set(sources))
sources += [ROOT/'NativeMacGuest/Info.plist',ROOT/'NativeMacGuest/NativeGuest.entitlements',ROOT/'NativeMacGuest/project.yml',ROOT/'NativeMacGuest/build.py']
sources += [ROOT/'NativeMacGuest/prepare-livekit.py',dependency_root/'native-livekit.json']
sources += sorted(x for x in (ROOT/'NativeMacGuest/Assets.xcassets').rglob('*') if x.is_file())
sources += sorted(x for x in (ROOT/'RockNRoll/Assets.xcassets/AdditionalRootCA.dataset').rglob('*') if x.is_file())
artifacts = [executable, app/'Contents/MacOS/RockNRoll Native Guest.debug.dylib', app/'Contents/Info.plist']
artifacts += [app/'Contents/Resources/Assets.car', app/'Contents/Resources/AppIcon.icns']
artifacts += [x for x in (app/'Contents/Frameworks').rglob('LiveKitWebRTC') if x.is_file() and not x.is_symlink()]
manifest = {'artifacts':{str(x.relative_to(app)):hashlib.sha256(x.read_bytes()).hexdigest() for x in artifacts if x.exists()}, 'bundleIdentifier' :'dev.vsmirn0v.conferenceguest.nativeguest',
            'configuration':a.configuration, 'version':a.version, 'buildNumber':a.build_number,
            'nativeFramework':framework_evidence,
            'sources':{str(x.relative_to(ROOT)):hashlib.sha256(x.read_bytes()).hexdigest() for x in sources},
            'executableSHA256':hashlib.sha256(executable.read_bytes()).hexdigest()}
if archive is not None:
    archived_app = archive/'Products/Applications/RockNRoll Native Guest.app'
    archived_info = plistlib.loads((archived_app/'Contents/Info.plist').read_bytes())
    if (archived_info.get('CFBundleIdentifier') != manifest['bundleIdentifier'] or
        archived_info.get('CFBundleShortVersionString') != a.version or
        archived_info.get('CFBundleVersion') != a.build_number or
        archived_info.get('LSApplicationCategoryType') != 'public.app-category.video'):
        raise SystemExit('Archived app identity or Mac category differs from the requested build')
    archived_files = ['Contents/MacOS/RockNRoll Native Guest', 'Contents/Info.plist',
        'Contents/Resources/AppIcon.icns', 'Contents/Resources/Assets.car',
        'Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC']
    subprocess.run(['codesign','--verify','--deep','--strict',str(archived_app)],check=True)
    manifest['archive'] = {'path':str(archive.relative_to(ROOT)),
        'artifacts':{name:hashlib.sha256((archived_app/name).read_bytes()).hexdigest() for name in archived_files}}
(build/'build-evidence.json').write_text(json.dumps(manifest,indent=2)+'\n')
if a.install:
    destination = pathlib.Path('/Applications/RockNRoll Native Guest.app')
    destination.parent.mkdir(exist_ok=True)
    if destination.exists():
        old = plistlib.loads((destination/'Contents/Info.plist').read_bytes())
        if old.get('CFBundleIdentifier') != manifest['bundleIdentifier']:
            raise SystemExit('Refusing to replace an unrelated installed bundle')
        # Keep any prior development companion recoverable; never replace a running instance.
        ps = subprocess.check_output(['ps','-axo','command'],text=True)
        if str(destination/'Contents/MacOS') in ps: raise SystemExit('Close the installed companion before updating it')
        archives = build/'archives'; archives.mkdir(exist_ok=True)
        import uuid
        previous = archives/(str(uuid.uuid4())+'.app')
        subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister','-u',str(destination)],check=True)
        destination.rename(previous)
    shutil.copytree(app,destination,symlinks=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(destination)],check=True)
    subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister','-f',str(destination)],check=True)
    print(destination)
else: print(app)
