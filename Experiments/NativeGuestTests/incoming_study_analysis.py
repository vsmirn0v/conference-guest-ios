"""Offline classification of retained incoming-video runs; never launches media."""
import json

def analyze(run,engine,source_transport):
 result={}
 windows=[]
 for line in (run/'receiver.log').read_text(errors='replace').splitlines():
  try:
   row=json.loads(line.split('ORIGINAL_SDK_UDP ',1)[1]) if 'ORIGINAL_SDK_UDP ' in line else json.loads(line)
  except (ValueError,IndexError):continue
  if isinstance(row,dict) and row.get('event') in ['native-incoming-window','original-sdk-window']:windows.append(row)
 sender=[]
 for line in (run/'source.jsonl').read_text(errors='replace').splitlines():
  try:sample=json.loads(line)
  except ValueError:continue
  if isinstance(sample,dict) and sample.get('event')=='companion-sender-sample':sender.append(sample)
 def source_window(start,end):
  leading=[s for s in sender if s['sampleUptime']<=start]
  trailing=[s for s in sender if s['sampleUptime']>=end]
  if not leading or not trailing:return {'qualified':False,'reason':'missing bracketing sender samples'}
  first,last=leading[-1],trailing[0];seconds=last['sampleUptime']-first['sampleUptime']
  samples=[s for s in sender if first['sampleUptime']<=s['sampleUptime']<=last['sampleUptime']]
  def counter(sample,key):return sum(s.get(key,0) for s in sample['evidence']['stats'] if s['type']=='outbound-rtp' and s.get('kind')=='video')
  generated=(last['evidence']['localVideo']['generatedFrames']-first['evidence']['localVideo']['generatedFrames'])/seconds
  encoded=(counter(last,'framesEncoded')-counter(first,'framesEncoded'))/seconds
  sent=(counter(last,'framesSent')-counter(first,'framesSent'))/seconds
  relays=sorted({s.get('relayProtocol',s.get('protocol','unknown')) for sample in samples for s in sample['evidence']['stats'] if s['type']=='local-candidate' and s.get('target')=='PUBLISHER'})
  fresh=all(sample['evidence']['publisherStatsFresh'] and not sample['evidence']['failed'] and sample['connections']==first['connections'] and 0<=sample['sampleUptime']-sample['evidence']['localVideo']['generatedLastUptime']<.5 for sample in samples)
  maximum_sample_gap=max(b['sampleUptime']-a['sampleUptime'] for a,b in zip(samples,samples[1:]))
  return dict(qualified=fresh and maximum_sample_gap<2 and start-first['sampleUptime']<2 and last['sampleUptime']-end<2 and min(generated,encoded,sent)>=12 and (source_transport!='tcp-relay' or bool(relays) and set(relays)<={'tcp','tls'}),
              generatedFPS=generated,encodedFPS=encoded,sentFPS=sent,selectedRelay=relays,maximumSampleGap=maximum_sample_gap)
 churn=[]
 for row in windows:
  if not row.get('captureChurn'):continue
  before={(s['peer'],s['id']):s for s in row.get('captureBefore',[])}
  def observed(kind,intent,key):
   tracks=[s for peer in row['peers'] for s in peer.get('senders',[]) if s['kind']==kind]
   if not intent:return all(not track['enabled'] for track in tracks)
   if not any(track['enabled'] for track in tracks):return False
   for peer in row['peers']:
    for stat in peer['stats']:
     if stat['type']!='outbound-rtp' or stat.get('kind')!=kind:continue
     baseline=before.get((peer['peer'],stat['id']))
     if baseline is None:continue
     progress=stat.get(key,0)-baseline.get(key,0)
     packets=stat.get('packetsSent',0)-baseline.get('packetsSent',0)
     if kind=='video':
      if progress/(row['end']-row['start'])>=8 and packets>0:return True
     elif progress>0:return True
   return False
  mic=observed('audio',row['microphoneIntent'],'packetsSent')
  camera=row.get('cameraAuthorization')==3 and observed('video',row['cameraIntent'],'framesEncoded')
  timing='controlsReturnedUptime' in row and row['start']<=row['controlsReturnedUptime']<=row['end']
  sequence=row.get('window') is not None and row['microphoneIntent']==(row['window']%4!=0) and row['cameraIntent']==(row['window']%4!=2)
  row['captureQualification']=dict(microphoneStateAndTransport=mic,cameraStateAndTransport=camera,toggleTimingIncluded=timing,completeCycleSchedule=sequence)
  churn.append(bool(before) and mic and camera and timing and sequence)
 ordered=[row.get('window') for row in windows]==list(range(12))
 result['physicalChurnQualified']=len(churn)==12 and all(churn) and ordered if churn else None
 qualified=[];transports=set();dimensions=set()
 for row in windows:
  if engine=='native':
   qualified.append(bool(row.get('cadencePass')))
   stats=row['after']['stats']
  else:
   taps=row['frames']
   qualified.append(row['applicationState']==0 and row['active'] and not row['ended'] and len(taps)==1 and
                    all(t['completeWindow'] and t['fps']>=12 and t['maximumGap']<1 and t['endFrameAge']<.5 for t in taps))
   receive_peers={tap['peer'] for tap in taps}
   stats=[s for peer in row['peers'] if peer['peer'] in receive_peers for s in peer['stats']]
  row['sourceQualification']=source_window(row['start'],row['end'])
  qualified[-1]=qualified[-1] and row['sourceQualification']['qualified']
  for stat in stats:
   if stat['type']=='local-candidate' and (engine=='sdk' or stat.get('target')=='SUBSCRIBER'):
    transports.add(stat.get('relayProtocol',stat.get('protocol','unknown')))
   if stat['type']=='inbound-rtp' and stat.get('kind')=='video':dimensions.add((stat.get('frameWidth'),stat.get('frameHeight')))
 result['senderSamples']=len(sender)
 result.update(observationWindows=len(windows),qualifiedWindows=sum(qualified),
               allCadencePassed=len(windows)==12 and all(qualified) and ordered,actualReceiveTransport=sorted(transports),
               receivedDimensions=sorted(dimensions),requestedSourceTransport=source_transport)
 (run/'observations.json').write_text(json.dumps(windows,indent=2))
 return result
