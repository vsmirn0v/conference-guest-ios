#!/usr/bin/env python3
"""One authorized generated sender, one receiver; never change OS audio/network settings."""
import argparse,datetime,hashlib,json,os,pathlib,re,signal,subprocess,time
from incoming_study_analysis import analyze
ROOT=pathlib.Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--engine',choices=['native','sdk'],required=True)
p.add_argument('--transport',choices=['auto','tcp-relay','udp-relay'],default='auto')
p.add_argument('--source-transport',choices=['auto','tcp-relay'],default='tcp-relay')
p.add_argument('--churn',action='store_true',help='SDK control with three physical microphone/camera toggle cycles')
p.add_argument('--pixels',choices=['on','off'],default='off')
a=p.parse_args()
if a.churn and a.engine!='sdk':p.error('Physical native churn uses the installed capture supervisor')
if a.engine=='sdk' and a.transport=='udp-relay':p.error('SDK only supports auto or TCP control')
os.umask(0o077)
run=ROOT/'.build/native-guest'/('incoming-'+a.engine+'-'+a.transport+'-'+a.pixels+'-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'));run.mkdir(mode=0o700)
probe=ROOT/'.build/native-guest/NativeGuestProbe';study=ROOT/'.build/native-guest/IncomingVideoStudy';dd=ROOT/'.build/udp-sdk-comparison/DerivedData'
invite=run/'invitation.txt';ipc=run/'source-control';ipc.mkdir(mode=0o700)
paths=[probe,study] if a.engine=='native' else [probe,dd/'Build/Products/Debug-iphoneos/RockNRoll.app/RockNRoll',dd/'Build/Products/Debug-iphoneos/RockNRoll.app/PlugIns/RockNRollTests.xctest/RockNRollTests']
paths += sorted((ROOT/'Experiments/NativeGuest').glob('*.swift'))
paths += [ROOT/'Experiments/NativeGuestTests/incoming_study_analysis.py',ROOT/'Experiments/NativeGuestTests/IncomingVideoStudy.swift', pathlib.Path(__file__), ROOT/'RockNRollTests/VendorIntegration/GuestMediaResponsivenessLiveTests.swift', ROOT/'NativeMacGuest/VideoTile.swift', ROOT/'.build/native-guest/duplex-framework-r1/LiveKitWebRTC.xcframework/macos-arm64/LiveKitWebRTC.framework/LiveKitWebRTC']
identity={str(path):hashlib.sha256(path.read_bytes()).hexdigest() for path in paths};(run/'artifact-identity.json').write_text(json.dumps(identity,indent=2))
with (run/'bootstrap.log').open('w') as log:subprocess.run([str(probe),'--create-room','https://salutejazz.ru','--output',str(invite)],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=35)
def stop(process):
 if process is not None and process.poll() is None:
  process.terminate()
  try:process.wait(timeout=12)
  except subprocess.TimeoutExpired:process.kill();process.wait(timeout=5)
source=receiver=None;failure=None;result={}
with (run/'source.jsonl').open('w') as source_log,(run/'receiver.log').open('w') as receiver_log:
 try:
  source=subprocess.Popen([str(probe),'--invite-file',str(invite),'--companion-peer','--evidence-directory',str(ipc),'--seconds','300','--companion-ice',a.source_transport],stdout=source_log,stderr=subprocess.STDOUT)
  deadline=time.monotonic()+35
  while not (ipc/'ready.json').exists():
   if source.poll() is not None or time.monotonic()>deadline:raise RuntimeError('Independent sender not ready')
   time.sleep(.2)
  if a.engine=='native':cmd=[str(study),str(invite),a.transport,a.pixels];env=os.environ.copy()
  else:
   env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',TEST_RUNNER_ROCKNROLL_TEST_GUEST_UDP_INVITE=invite.read_text().strip(),TEST_RUNNER_ROCKNROLL_TEST_GUEST_UDP_TRANSPORT=a.transport,TEST_RUNNER_ROCKNROLL_TEST_GUEST_UDP_CHURN='1' if a.churn else '0')
   cmd=['xcodebuild','test-without-building','-project',str(ROOT/'RockNRoll.xcodeproj'),'-scheme','RockNRoll','-destination','platform=macOS,id=00008132-000C10683650401C,arch=arm64','-derivedDataPath',str(dd),'-parallel-testing-enabled','NO','-only-testing:RockNRollTests/GuestUDPComparisonLiveTests','-resultBundlePath',str(run/'receiver.xcresult')]
  receiver=subprocess.Popen(cmd,cwd=ROOT,env=env,stdout=receiver_log,stderr=subprocess.STDOUT)
  deadline=time.monotonic()+175
  while receiver.poll() is None:
   if source.poll() is not None:raise RuntimeError('Independent sender stopped before receiver finished')
   if time.monotonic()>deadline:raise RuntimeError('Bounded receiver timeout')
   time.sleep(.2)
  result['receiverExit']=receiver.returncode
  result['physicalSDKChurnRequested']=a.churn
  if receiver.returncode:raise RuntimeError('Receiver failed; retain partial windows')
 except BaseException as error:failure=repr(error)
 finally:
  stop(receiver)
  if source is not None and source.poll() is None:
   # Keep sampling past the receiver's last window edge before stopping the source.
   # One interval plus margin supplies a real trailing RTP sample, never a synthetic one.
   time.sleep(1.5)
   temporary=ipc/'stop.json';temporary.write_text(json.dumps(dict(sequence=1,operation='stop',phase='finished',audio=False,video=False,remoteParticipants=0)));temporary.replace(ipc/'command.json')
   try:source.wait(timeout=15)
   except subprocess.TimeoutExpired:stop(source)
  try:
   result['independentCleanup']=False
   for attempt in range(3):
    with (run/('cleanup-'+str(attempt)+'.jsonl')).open('w') as log:
     checked=subprocess.run([str(probe),'--invite-file',str(invite),'--expect-alone','--seconds','5'],stdout=log,stderr=subprocess.STDOUT,timeout=45)
    if checked.returncode==0:
     result['independentCleanup']=True;break
    time.sleep(3)
   if not result['independentCleanup']:raise RuntimeError('Independent observer still sees a participant after bounded cleanup grace')
  except BaseException as error:
   result['independentCleanup']=False
   if failure is None:failure=repr(error)
  result.update(analyze(run,a.engine,a.source_transport))
  result['artifactIdentityUnchanged']=all(hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()==digest for path,digest in identity.items())
  result['failure']=failure
  (run/'summary.json').write_text(json.dumps(result,indent=2))
print(run);print(json.dumps(result))
if failure or not result['artifactIdentityUnchanged'] or not result['allCadencePassed'] or (a.churn and not result['physicalChurnQualified']):raise SystemExit(1)
