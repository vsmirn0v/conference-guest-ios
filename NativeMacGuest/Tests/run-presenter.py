#!/usr/bin/env python3
"""Compile the real native Presenter/session/relay against M156; mock capture and signaling."""
from pathlib import Path
import subprocess
import os
os.environ.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
root = Path(__file__).resolve().parents[2]
out = root / '.build/native-desktop-presenter-tests'
out.mkdir(parents=True, exist_ok=True)
framework = root / '.build/webrtc-m156-port/native-framework/LiveKitWebRTC.xcframework/macos-arm64'
products = root / '.build/native-desktop-engine-core/out/Products/Debug'
subprocess.run(['xcrun','swift','build','--package-path',str(root/'ConferenceCore'),'--scratch-path',str(root/'.build/native-desktop-engine-core'),'-c','debug'],check=True)
obj = out/'MacScreenCaptureBridge.o'
subprocess.run(['xcrun','clang','-fobjc-arc','-target','arm64-apple-macos13.0','-c',str(root/'RockNRoll/MacScreenCaptureBridge.m'),'-o',str(obj)],check=True)
files = [p for p in (root/'Experiments/NativeGuest').glob('*.swift') if p.name not in {'Main.swift','GuestCompanionPeer.swift'}]
files.append(root/'Shared/GuestAudioProfile.swift')
files.append(root/'Shared/GuestAudioOwnerLease.swift')
files += [root/'NativeMacGuest/Engines'/name for name in ['NativeDesktopExternalEngine.swift','NativeDesktopRTCPeer.swift','NativeDesktopExternalSession.swift','NativeDesktopProviderSignals.swift']]
files += [root/p for p in ['RockNRoll/Telemost/TelemostBootstrap.swift','RockNRoll/Telemost/TelemostTransport.swift','RockNRoll/TrueConf/TrueConfBootstrap.swift','RockNRoll/TrueConf/TrueConfTransport.swift','RockNRoll/TrueConf/TrueConfRoster.swift','RockNRoll/VendorIntegration/AdditionalRootTrust.swift','RockNRoll/NativeVideoPixelBuffer.swift','RockNRoll/PresenterCompositor.swift','RockNRoll/PresenterCanvasEdit.swift','RockNRoll/H264InputColorSignalling.swift','RockNRoll/VendorIntegration/H264ColorSignalling.swift','Shared/Localization.swift','NativeMacGuest/DesktopShareCapture.swift','NativeMacGuest/DesktopPresenterSession.swift','NativeMacGuest/DesktopPresenterRelay.swift','NativeMacGuest/DesktopPresenterEditor.swift','NativeMacGuest/Tests/NativeDesktopPresenterTests.swift']]
files.append(root/'NativeMacGuest/NativeDesktopCameraLease.swift')
files.append(root/'RockNRoll/CameraReactionObserver.swift')
binary=out/'presenter-tests'
cmd=['xcrun','swiftc','-D','DEBUG','-parse-as-library','-swift-version','5','-target','arm64-apple-macos13.0','-F',str(framework),'-framework','LiveKitWebRTC','-I',str(products),'-L',str(products),'-lConferenceCore','-import-objc-header',str(root/'RockNRoll/MacScreenCaptureBridge.h'),'-Xlinker','-rpath','-Xlinker',str(framework),'-o',str(binary),str(obj)]+[str(p) for p in files]
result=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
(out/'build.log').write_text(result.stdout)
print(result.stdout)
result.check_returncode()
subprocess.run([str(binary)],check=True)
