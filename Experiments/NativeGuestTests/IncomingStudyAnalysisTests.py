import json
import pathlib
import tempfile
import unittest
from incoming_study_analysis import analyze

class AnalysisTests(unittest.TestCase):
 def fixture(self,run,engine='native'):
  samples=[]
  for tick in range(64):
   samples.append(dict(event='companion-sender-sample',sampleUptime=tick,connections=1,
    evidence=dict(publisherStatsFresh=True,failed=False,localVideo=dict(generatedFrames=tick*15,generatedLastUptime=tick-.01),
     stats=[dict(type='outbound-rtp',kind='video',framesEncoded=tick*15,framesSent=tick*15),dict(type='local-candidate',target='PUBLISHER',relayProtocol='tls')])))
  windows=[]
  for i in range(12):
   window=dict(window=i,start=1+i*5,end=6+i*5)
   if engine=='native':window.update(event='native-incoming-window',cadencePass=True,after=dict(stats=[dict(type='local-candidate',target='SUBSCRIBER',relayProtocol='udp')]))
   else:window.update(event='original-sdk-window',applicationState=0,active=True,ended=False,
    frames=[dict(peer='receiver',completeWindow=True,fps=15,maximumGap=.07,endFrameAge=.02)],
    peers=[dict(peer='receiver',stats=[dict(type='local-candidate',relayProtocol='tcp')]),dict(peer='publisher',stats=[dict(type='local-candidate',relayProtocol='udp')])])
   windows.append(window)
  (run/'source.jsonl').write_text('\n'.join(json.dumps(s) for s in samples))
  (run/'receiver.log').write_text('"unrelated JSON string"\n[]\n'+ '\n'.join(json.dumps(w) for w in windows))
  return samples,windows
 def test_healthy_native_and_missing_trailing_bracket(self):
  with tempfile.TemporaryDirectory() as root:
   run=pathlib.Path(root);samples,_=self.fixture(run)
   self.assertTrue(analyze(run,'native','tcp-relay')['allCadencePassed'])
   (run/'source.jsonl').write_text('\n'.join(json.dumps(s) for s in samples[:61]))
   result=analyze(run,'native','tcp-relay')
   self.assertFalse(result['allCadencePassed']);self.assertEqual(result['qualifiedWindows'],11)
 def test_sender_encode_stall_cannot_qualify(self):
  with tempfile.TemporaryDirectory() as root:
   run=pathlib.Path(root);samples,_=self.fixture(run)
   for sample in samples:sample['evidence']['stats'][0]['framesEncoded']=0
   (run/'source.jsonl').write_text('\n'.join(json.dumps(s) for s in samples))
   self.assertEqual(analyze(run,'native','tcp-relay')['qualifiedWindows'],0)
 def test_sdk_transport_only_comes_from_observed_receive_peer(self):
  with tempfile.TemporaryDirectory() as root:
   run=pathlib.Path(root);self.fixture(run,'sdk')
   result=analyze(run,'sdk','tcp-relay')
   self.assertTrue(result['allCadencePassed']);self.assertEqual(result['actualReceiveTransport'],['tcp'])

 def test_intent_without_observed_camera_cannot_qualify_capture(self):
  with tempfile.TemporaryDirectory() as root:
   run=pathlib.Path(root);_,windows=self.fixture(run,'sdk')
   for i,row in enumerate(windows):row.update(window=i,captureChurn=True,microphoneIntent=i%4!=0,cameraIntent=i%4!=2)
   (run/'receiver.log').write_text('\n'.join(json.dumps(w) for w in windows))
   result=analyze(run,'sdk','tcp-relay')
   self.assertTrue(result['allCadencePassed']);self.assertFalse(result['physicalChurnQualified'])

 def churn_fixture(self,run):
  _,windows=self.fixture(run,'sdk')
  for i,row in enumerate(windows):
   mic=i%4!=0;camera=i%4!=2
   row.update(captureChurn=True,microphoneIntent=mic,cameraIntent=camera,cameraAuthorization=3,controlsReturnedUptime=row['start']+.01,
    captureBefore=[dict(peer='publisher',id='audio',packetsSent=100),dict(peer='publisher',id='video',framesEncoded=100,packetsSent=100)])
   row['peers'][1]['senders']=[dict(kind='audio',enabled=mic),dict(kind='video',enabled=camera)]
   row['peers'][1]['stats'] += [dict(type='outbound-rtp',id='audio',kind='audio',packetsSent=120 if mic else 100),dict(type='outbound-rtp',id='video',kind='video',framesEncoded=175 if camera else 100,packetsSent=200 if camera else 100)]
  return windows
 def test_observed_capture_cycles_need_exact_baselines_and_unique_indices(self):
  with tempfile.TemporaryDirectory() as root:
   run=pathlib.Path(root);windows=self.churn_fixture(run)
   def check():
    (run/'receiver.log').write_text('\n'.join(json.dumps(w) for w in windows))
    return analyze(run,'sdk','tcp-relay')
   self.assertTrue(check()['physicalChurnQualified'])
   windows[1]['captureBefore'].pop() # Unrelated audio baseline cannot validate cumulative video counters.
   self.assertFalse(check()['physicalChurnQualified'])
   windows=self.churn_fixture(run)
   windows[:]=[windows[0]]*12
   self.assertFalse(check()['physicalChurnQualified'])
   self.assertFalse(check()['allCadencePassed'])

if __name__=='__main__':unittest.main()
