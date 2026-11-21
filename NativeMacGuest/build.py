#!/usr/bin/env python3
"""Provision/build the external Mac companion; never modify the iOS app bundle."""
import argparse, hashlib, json, os, pathlib, plistlib, re, shutil, subprocess, tempfile
from native_dependencies import (AUDIO_ROUTE_RECOVERY_PATCHES, audio_route_recovery_lock_paths,
    default_framework_root, ensure_framework, sha256 as cached_sha256, verify_audio_route_recovery_framework)
from distribution.build_support import (APP_NAME, APP_BUNDLE_NAME, EXECUTABLE_NAME,
    application_executable, configure_distribution, find_application, installation_destination, resolve_source_paths)
ROOT = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--identity', help='Apple Development signing identity for the final provisioned bundle')
p.add_argument('--compile-only', action='store_true', help='Compile without signing or running the app; no Apple team membership required')
p.add_argument('--install', action='store_true', help='Install the verified build in /Applications (required by the host sandbox)')
p.add_argument('--allow-provisioning-updates', action='store_true', help='Allow Xcode to register/update the Mac app-group profile')
p.add_argument('--framework-root', type=pathlib.Path, default=default_framework_root(ROOT),
               help='Directory containing LiveKitWebRTC.xcframework and build-evidence.json')
p.add_argument('--output-dir', type=pathlib.Path, default=ROOT/'.build/native-mac-guest')
p.add_argument('--configuration', choices=('Debug', 'Release'), default='Debug')
p.add_argument('--distribution', choices=('app-store', 'direct'), default='app-store',
               help='App Store build (default) or separately configured Sparkle direct build')
p.add_argument('--version', default='0.1')
p.add_argument('--build-number', default='1')
p.add_argument('--archive', action='store_true', help='Create an Xcode archive for later TestFlight distribution')
p.add_argument('--jobs', type=int, default=max(4, min(os.cpu_count() or 4, 10)),
               help='Maximum concurrent build jobs passed to xcodebuild')
p.add_argument('--reuse-cache', action='store_true',
               help='Reuse persistent prepared SDK dependencies, project, and DerivedData cache')
a = p.parse_args()
if a.compile_only and (a.install or a.archive):
    p.error('--compile-only cannot install or archive an unsigned build')
if not a.compile_only and not a.identity:
    p.error('--identity is required for a signed build; use --compile-only for a compile check')
if not a.version or not a.build_number.isdecimal() or int(a.build_number) < 1:
    raise SystemExit('A nonempty version and positive numeric build number are required')
build = a.output_dir.resolve()
archive = build/(f'RockNRollNativeGuest-{a.version}-{a.build_number}.xcarchive') if a.archive else None
if archive is not None and archive.exists():
    raise SystemExit('Refusing to replace an existing archive')
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
if a.reuse_cache:
    sha_cache = str(ROOT / '.build/native-mac-guest-cache/sha256-cache.json')
    os.environ['RNR_SHA256_CACHE_PATH'] = sha_cache
    env['RNR_SHA256_CACHE_PATH'] = sha_cache
framework_root = ensure_framework(a.framework_root)
if a.distribution == 'direct':
    try:
        verify_audio_route_recovery_framework(framework_root, ROOT)
    except (KeyError, ValueError) as error:
        raise SystemExit(str(error)) from error
framework_evidence = json.loads((framework_root/'build-evidence.json').read_text())
framework_binary = framework_root/'LiveKitWebRTC.xcframework/macos-arm64/LiveKitWebRTC.framework/LiveKitWebRTC'
if cached_sha256(framework_binary) != framework_evidence['frameworkBinarySHA256']:
    raise SystemExit('Native InputMixer framework does not match its build evidence')
for resource in (ROOT/'RockNRoll/Assets.xcassets/AdditionalRootCA.dataset').iterdir():
    native_resource = ROOT/'NativeMacGuest/Assets.xcassets/AdditionalRootCA.dataset'/resource.name
    if resource.is_file() and (not native_resource.is_file() or native_resource.read_bytes() != resource.read_bytes()):
        raise SystemExit('Native public root certificate asset differs from its canonical shared resource')
if a.reuse_cache:
    cache_root = ROOT / '.build/native-mac-guest-cache'
    cache_key = f'{a.distribution}-{a.configuration}'
    dependency_root = cache_root / 'Dependencies'
    project = cache_root / f'Project-{cache_key}'
    derived_data = cache_root / f'Xcode-{cache_key}'
    spec_dir = cache_root / f'Spec-{cache_key}'
    marker_path = dependency_root / 'native-livekit.json'
    if marker_path.is_file():
        expected_patches = {
            path.name: hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted((ROOT / 'Dependencies/native-macos/livekit-patches').glob('*.patch'))
        }
        try:
            cached_marker = json.loads(marker_path.read_text())
        except (OSError, ValueError):
            cached_marker = None
        if (not cached_marker or
                cached_marker.get('framework_sha256') != framework_evidence['frameworkBinarySHA256'] or
                cached_marker.get('patches') != expected_patches):
            shutil.rmtree(dependency_root, ignore_errors=True)
            shutil.rmtree(derived_data, ignore_errors=True)
    for directory in (build, dependency_root, project, derived_data, spec_dir):
        directory.mkdir(parents=True, exist_ok=True)
else:
    dependency_root = build/'Dependencies'
    project = build/'Project'
    derived_data = build/'Xcode'
    spec_dir = build/'Spec'
    project.mkdir(parents=True, exist_ok=True)
    spec_dir.mkdir(parents=True, exist_ok=True)
spec_source = (ROOT/'NativeMacGuest/project.yml').read_text()
# Persist the requested identity in the generated project too. Otherwise a later
# build-for-testing silently restores the specification's development defaults.
spec_source = re.sub(r'(?m)^(\s*MARKETING_VERSION: ).*$', lambda m: m[1]+json.dumps(a.version), spec_source)
spec_source = re.sub(r'(?m)^(\s*CURRENT_PROJECT_VERSION: ).*$', lambda m: m[1]+json.dumps(a.build_number), spec_source)
# The local speech runtime is a pinned static library; it must exist before xcodegen.
subprocess.run(['python3',str(ROOT/'NativeMacGuest/prepare-sherpa.py')],check=True,env=env)
subprocess.run(['python3',str(ROOT/'NativeMacGuest/prepare-livekit.py'),
                '--framework',str(framework_root/'LiveKitWebRTC.xcframework'),
                '--destination',str(dependency_root)],check=True,env=env)
unified_root = ROOT / '.build/unified-sdk-dependencies'
if not (unified_root / 'native-livekit.json').is_file():
    subprocess.run(['python3', str(ROOT/'NativeMacGuest/prepare-livekit.py'),
                    '--framework', str(framework_root/'LiveKitWebRTC.xcframework'),
                    '--destination', str(unified_root)], check=True, env=env)
for name in ['client-sdk-swift','webrtc-xcframework']:
    spec_source = spec_source.replace('../.build/unified-sdk-dependencies/'+name,str(dependency_root/name))
# Resolve source/package and file-setting paths independently of output depth.
spec_source = resolve_source_paths(ROOT, spec_source)
spec_source, sparkle_evidence, distribution_inputs = configure_distribution(ROOT, spec_dir, spec_source, a.distribution)
last_spec_path = spec_dir / 'last-spec.yml'
pbxproj_path = project / 'RockNativeGuest.xcodeproj/project.pbxproj'
needs_xcodegen = (
    not a.reuse_cache
    or not pbxproj_path.is_file()
    or not last_spec_path.is_file()
    or last_spec_path.read_text() != spec_source
)
generated_spec = None
if needs_xcodegen:
    with tempfile.NamedTemporaryFile(mode='w', prefix='.native-guest-build-', suffix='.yml',
                                     dir=spec_dir, delete=False) as spec_file:
        spec_file.write(spec_source)
        generated_spec = pathlib.Path(spec_file.name)
try:
    if needs_xcodegen:
        subprocess.run(['xcodegen','generate','--spec',str(generated_spec),'--project',str(project)],env=env,check=True)
        last_spec_path.write_text(spec_source)
    resolved = project/'RockNativeGuest.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
    resolved.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT/'NativeMacGuest/Package.resolved', resolved)
    cmd = ['xcodebuild','-disableAutomaticPackageResolution','-project',str(project/'RockNativeGuest.xcodeproj'),'-scheme','RockNRollNativeGuest',
           '-configuration',a.configuration,'-destination','platform=macOS,arch=arm64','-derivedDataPath',str(derived_data),
           '-jobs',str(max(1, a.jobs)),
           'MARKETING_VERSION='+a.version,'CURRENT_PROJECT_VERSION='+a.build_number]
    if a.compile_only:
        cmd.append('CODE_SIGNING_ALLOWED=NO')
    if a.allow_provisioning_updates: cmd.append('-allowProvisioningUpdates')
    if a.archive:
        assert archive is not None
        if archive.exists(): raise SystemExit('Refusing to replace an existing archive')
        subprocess.run(cmd+['-archivePath',str(archive),'archive'],env=env,check=True)
    else:
        subprocess.run(cmd+['build'],env=env,check=True)
finally:
    if generated_spec is not None:
        generated_spec.unlink(missing_ok=True)
app = find_application(archive/'Products/Applications') if a.archive else derived_data/'Build/Products'/a.configuration/APP_BUNDLE_NAME
voice_worker_path = pathlib.Path('Contents/MacOS/RockClonedVoiceWorker')
gpu_voice_worker_path = pathlib.Path('Contents/MacOS/RockClonedVoiceGPUWorker')
for worker_path in (voice_worker_path, gpu_voice_worker_path):
    if not (app / worker_path).is_file():
        raise SystemExit(f'The voice worker is missing from the application: {worker_path.name}')
if a.compile_only:
    print('Unsigned compile check passed: ' + str(app))
    raise SystemExit(0)
info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
if any(info.get(key) != APP_NAME for key in ('CFBundleName', 'CFBundleDisplayName')):
    raise SystemExit('Built app name differs from the requested product')
if not a.archive:
    subprocess.run(['codesign','--force','--sign',a.identity,'--preserve-metadata=identifier,entitlements,flags,runtime',str(app)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
signature = subprocess.run(['codesign','-dv','--verbose=4',str(app)],capture_output=True,text=True,check=True)
if 'TeamIdentifier=5V64BP2H3P' not in signature.stderr:
    raise SystemExit('The selected signing certificate does not belong to the app-group provisioning team')
# This gate catches signatures that look valid but lack a provisioned app group.
executable = application_executable(app)
subprocess.run([str(executable),'--check-container'],check=True)
subprocess.run([str(executable),'--check-voice-worker'],check=True,timeout=20)
sources = sorted((ROOT/'MeetingEngine/Sources').rglob('*.swift')) + [ROOT/'MeetingEngine/Package.swift']
sources += sorted(x for x in (ROOT/'NativeMacGuest').rglob('*.swift') if 'Tests' not in x.parts)
sources += [ROOT/'Shared/NativeGuestCompanionProtocol.swift']
for source in re.findall(r'(?m)^      - path: (\.\./.+)$', (ROOT/'NativeMacGuest/project.yml').read_text()):
    path = (ROOT/'NativeMacGuest'/source).resolve()
    if path.is_file(): sources.append(path)
    elif path == ROOT/'RockNRoll':
        # The native target selects only the shared Localizable tables from the iOS source directory.
        for filename in ('Localizable.strings', 'Localizable.stringsdict'):
            sources += sorted(path.glob('*.lproj/' + filename))
    elif path.is_dir(): sources += sorted(x for x in path.rglob('*') if x.is_file() and '__pycache__' not in x.parts)
sources += sorted((ROOT/'ConferenceCore/Sources').rglob('*.swift'))+[ROOT/'ConferenceCore/Package.swift']
for resource_root in (ROOT/'NativeMacGuest/Resources', ROOT/'ConferenceCore/Sources/ConferenceCore/Resources'):
    sources += sorted(resource_root.glob('*.lproj/*.strings'))
sources = sorted(set(sources))
sources += [ROOT/'NativeMacGuest/VoiceWorker/Worker.entitlements', ROOT/'NativeMacGuest/Package.resolved']
sources += [ROOT/'NativeMacGuest/Info.plist',ROOT/'NativeMacGuest/PrivacyInfo.xcprivacy',ROOT/'NativeMacGuest/NativeGuest.entitlements',ROOT/'NativeMacGuest/project.yml',ROOT/'NativeMacGuest/build.py']
sources += [ROOT/'NativeMacGuest/prepare-livekit.py',dependency_root/'native-livekit.json']
sources += sorted((ROOT/'Dependencies/native-macos/livekit-patches').glob('*.patch'))
sources += [ROOT/'NativeMacGuest/native_dependencies.py', ROOT/'Dependencies/native-macos/sdk.unified.lock.json']
if a.distribution == 'direct':
    sources += sorted(path for path in (ROOT/'NativeMacGuest/AuthorSupport').rglob('*')
                      if path.is_file() and path.suffix != '.swift' and not path.name.startswith('.'))
    sources += audio_route_recovery_lock_paths(ROOT)
    sources += [ROOT/'Dependencies/native-macos/webrtc-patches'/(name+'.patch') for name in AUDIO_ROUTE_RECOVERY_PATCHES]
sources += [ROOT/'NativeMacGuest/prepare-sherpa.py', ROOT/'Dependencies/native-macos/sherpa-onnx.lock.json']
sources += sorted(x for x in (ROOT/'Dependencies/SherpaOnnxKit').rglob('*') if x.is_file() and x.suffix in {'.swift'} and '.build' not in x.parts)
sources += sorted(x for x in (ROOT/'Dependencies/MLXAudioVoice').rglob('*') if x.is_file() and '.build' not in x.parts)
resolved_packages = project/'RockNativeGuest.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
if not resolved_packages.is_file() or json.loads(resolved_packages.read_text()) != json.loads((ROOT/'NativeMacGuest/Package.resolved').read_text()):
    raise SystemExit('Swift package resolution differs from the checked-in lock')
sources += [ROOT/'Dependencies/SherpaOnnxKit/Artifacts/evidence.json']
sources += sorted(x for x in (ROOT/'NativeMacGuest/distribution').rglob('*')
                  if x.is_file() and x.suffix in {'.py', '.txt'} and '__pycache__' not in x.parts) + distribution_inputs
sources += sorted(x for x in (ROOT/'NativeMacGuest/ThirdPartyNotices').rglob('*') if x.is_file())
sources += sorted(x for x in (ROOT/'NativeMacGuest/Assets.xcassets').rglob('*') if x.is_file())
sources += sorted(x for x in (ROOT/'RockNRoll/Assets.xcassets/AdditionalRootCA.dataset').rglob('*') if x.is_file())
metal_library = pathlib.Path('Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib')
if not (app / metal_library).is_file():
    raise SystemExit('The GPU voice Metal library is missing from the application')
artifacts = [executable, app / voice_worker_path, app / gpu_voice_worker_path, app / metal_library, app/'Contents/MacOS'/(EXECUTABLE_NAME+'.debug.dylib'), app/'Contents/Info.plist']
artifacts += [app/'Contents/Resources/Assets.car', app/'Contents/Resources/AppIcon.icns']
artifacts += [x for x in (app/'Contents/Frameworks').rglob('LiveKitWebRTC') if x.is_file() and not x.is_symlink()]
if sparkle_evidence:
    artifacts += [x for x in (app/'Contents/Frameworks/Sparkle.framework').rglob('*') if x.is_file() and not x.is_symlink()]
manifest = {'artifacts':{str(x.relative_to(app)):hashlib.sha256(x.read_bytes()).hexdigest() for x in artifacts if x.exists()}, 'bundleIdentifier' :'dev.vsmirn0v.conferenceguest.nativeguest',
            'swiftPackages': json.loads(resolved_packages.read_text()),
            'configuration':a.configuration, 'distribution':a.distribution, 'version':a.version, 'buildNumber':a.build_number,
            'nativeFramework':framework_evidence,
            'sources':{str(x.relative_to(ROOT)):hashlib.sha256(x.read_bytes()).hexdigest() for x in sources},
            'executableSHA256':hashlib.sha256(executable.read_bytes()).hexdigest()}
if sparkle_evidence: manifest['sparkle'] = sparkle_evidence
if archive is not None:
    archived_app = find_application(archive/'Products/Applications')
    archived_info = plistlib.loads((archived_app/'Contents/Info.plist').read_bytes())
    if (archived_info.get('CFBundleIdentifier') != manifest['bundleIdentifier'] or
        archived_info.get('CFBundleShortVersionString') != a.version or
        archived_info.get('CFBundleVersion') != a.build_number or
        archived_info.get('LSApplicationCategoryType') != 'public.app-category.video' or
        any(archived_info.get(key) != APP_NAME for key in ('CFBundleName', 'CFBundleDisplayName'))):
        raise SystemExit('Archived app identity or Mac category differs from the requested build')
    archived_files = [str(voice_worker_path), str(gpu_voice_worker_path), str(metal_library), str(application_executable(archived_app).relative_to(archived_app)), 'Contents/Info.plist',
        'Contents/Resources/AppIcon.icns', 'Contents/Resources/Assets.car',
        'Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC']
    subprocess.run(['codesign','--verify','--deep','--strict',str(archived_app)],check=True)
    manifest['archive'] = {'path':str(archive.relative_to(ROOT)),
        'artifacts':{name:hashlib.sha256((archived_app/name).read_bytes()).hexdigest() for name in archived_files}}
    if sparkle_evidence:
        manifest['archive']['artifacts'].update({str(x.relative_to(archived_app)):hashlib.sha256(x.read_bytes()).hexdigest()
            for x in (archived_app/'Contents/Frameworks/Sparkle.framework').rglob('*') if x.is_file() and not x.is_symlink()})
(build/'build-evidence.json').write_text(json.dumps(manifest,indent=2)+'\n')
if a.install:
    try:
        destination = installation_destination('/Applications', subprocess.check_output(['ps','-axo','comm='],text=True))
    except (ValueError, OSError) as error:
        raise SystemExit(str(error)) from error
    destination.parent.mkdir(exist_ok=True)
    if destination.exists():
        # Keep any prior development companion recoverable; never replace a running instance.
        archives = build/'archives'; archives.mkdir(exist_ok=True)
        import uuid
        previous = archives/(str(uuid.uuid4())+'.app')
        subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister','-u',str(destination)],check=True)
        destination.rename(previous)
    shutil.copytree(app,destination,symlinks=True)
    if a.archive:
        subprocess.run(['codesign','--force','--sign',a.identity,'--preserve-metadata=identifier,entitlements,flags,runtime',str(destination)],check=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(destination)],check=True)
    subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister','-f',str(destination)],check=True)
    print(destination)
else: print(app)
