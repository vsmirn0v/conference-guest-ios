#!/usr/bin/env python3
"""Build/run provider protocol fixtures against the exact isolated native framework."""
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--framework-root', default='.build/webrtc-m156-port/native-framework')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
scratch = root / '.build/native-desktop-engine-core'
out = root / '.build/native-desktop-external-tests'
out.mkdir(parents=True, exist_ok=True)
subprocess.run(['swift', 'build', '--package-path', str(root / 'ConferenceCore'), '--scratch-path', str(scratch), '-c', 'debug'], check=True)
products = scratch / 'out/Products/Debug'
if not products.exists():
    products = scratch / 'arm64-apple-macosx/debug'
modules = products if (products / 'ConferenceCore.swiftmodule').exists() else products / 'Modules'
framework = (root / args.framework_root).resolve() / 'LiveKitWebRTC.xcframework/macos-arm64'
files = [p for p in (root / 'Experiments/NativeGuest').glob('*.swift') if p.name not in {'Main.swift', 'GuestCompanionPeer.swift'}]
files.append(root / 'Shared/GuestAudioProfile.swift')
files.append(root/'Shared/GuestAudioOwnerLease.swift')
files += [root / 'NativeMacGuest/Engines' / name for name in [
    'NativeDesktopExternalEngine.swift', 'NativeDesktopRTCPeer.swift',
    'NativeDesktopExternalSession.swift', 'NativeDesktopProviderSignals.swift']]
files += [root / p for p in [
    'RockNRoll/Telemost/TelemostBootstrap.swift', 'RockNRoll/Telemost/TelemostTransport.swift',
    'RockNRoll/TrueConf/TrueConfBootstrap.swift', 'RockNRoll/TrueConf/TrueConfTransport.swift',
    'RockNRoll/TrueConf/TrueConfRoster.swift', 'RockNRoll/VendorIntegration/AdditionalRootTrust.swift',
    'RockNRoll/NativeVideoPixelBuffer.swift', 'Shared/Localization.swift',
    'NativeMacGuest/Tests/ExternalEngineProtocolTests.swift']]
binary = out / 'external-engine-tests'
command = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-target', 'arm64-apple-macos13.0',
           '-F', str(framework), '-framework', 'LiveKitWebRTC', '-I', str(modules), '-L', str(products), '-lConferenceCore',
           '-Xlinker', '-rpath', '-Xlinker', str(framework), '-o', str(binary)] + [str(p) for p in files]
result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
(out / 'build.log').write_text(result.stdout)
print(result.stdout)
result.check_returncode()
subprocess.run([str(binary)], check=True)
