#!/usr/bin/env python3
"""Synthetic capture lifecycle tests; no picker, screen recording or camera access."""
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[2]
out = root / '.build/native-desktop-share-tests'
out.mkdir(parents=True, exist_ok=True)
framework = root / '.build/webrtc-m156-desktop-audio/native-framework-r4/LiveKitWebRTC.xcframework/macos-arm64'
products = root / '.build/native-desktop-engine-core/out/Products/Debug'
subprocess.run(['swift', 'build', '--package-path', str(root/'ConferenceCore'), '--scratch-path', str(root/'.build/native-desktop-engine-core'), '-c', 'debug'], check=True)
obj = out / 'MacScreenCaptureBridge.o'
subprocess.run(['xcrun','clang','-fobjc-arc','-target','arm64-apple-macos13.0','-c',str(root/'RockNRoll/MacScreenCaptureBridge.m'),'-o',str(obj)],check=True)
files = [p for p in (root/'Experiments/NativeGuest').glob('*.swift') if p.name not in {'Main.swift','GuestCompanionPeer.swift'}]
files.append(root/'Shared/GuestAudioProfile.swift')
files.append(root/'Shared/GuestAudioOwnerLease.swift')
files += [root/'NativeMacGuest/Engines'/name for name in ['NativeDesktopExternalEngine.swift','NativeDesktopRTCPeer.swift','NativeDesktopExternalSession.swift','NativeDesktopProviderSignals.swift']]
files += [root/p for p in ['RockNRoll/Telemost/TelemostBootstrap.swift','RockNRoll/Telemost/TelemostTransport.swift','RockNRoll/TrueConf/TrueConfBootstrap.swift','RockNRoll/TrueConf/TrueConfTransport.swift','RockNRoll/TrueConf/TrueConfRoster.swift','RockNRoll/VendorIntegration/AdditionalRootTrust.swift','RockNRoll/NativeVideoPixelBuffer.swift','RockNRoll/PresenterCompositor.swift','Shared/Localization.swift','NativeMacGuest/DesktopShareCapture.swift','NativeMacGuest/Tests/NativeDesktopShareCaptureTests.swift']]
files.append(root/'RockNRoll/H264InputColorSignalling.swift')
files.append(root/'RockNRoll/VendorIntegration/H264ColorSignalling.swift')
binary=out/'share-capture-tests'
cmd=['xcrun','swiftc','-D','DEBUG','-parse-as-library','-swift-version','5','-target','arm64-apple-macos13.0','-F',str(framework),'-framework','LiveKitWebRTC','-framework','CoreMedia','-I',str(products),'-L',str(products),'-lConferenceCore','-import-objc-header',str(root/'RockNRoll/MacScreenCaptureBridge.h'),'-Xlinker','-rpath','-Xlinker',str(framework),'-o',str(binary),str(obj)]+[str(p) for p in files]
result=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
(out/'build.log').write_text(result.stdout)
print(result.stdout)
result.check_returncode()
subprocess.run([str(binary)],check=True)
