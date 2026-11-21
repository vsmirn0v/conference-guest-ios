import os, subprocess, time, signal
from pathlib import Path
root=Path('.analysis/p0-live-synthetic')
events=root/'source-events.txt'
invitation=root/'guest-source.txt'
fd=os.open(events,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
env=dict(os.environ,P0_EVENT_FD=str(fd))
start=time.monotonic()
p=None
try:
 p=subprocess.Popen([str(root/'PrivateGuestProbe'),'--invite-file',str(invitation),'--pair','--seconds','65','--codec','h264'],env=env,pass_fds=(fd,),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 ready=False
 while p.poll() is None and time.monotonic()-start<88:
  lines=events.read_text().splitlines()
  if not ready and lines.count('guest-connected')>=2 and 'publishing' in lines:
   ready=True
   print('SYNTHETIC_READY',flush=True)
  time.sleep(0.25)
 if p.poll() is None:
  p.terminate()
  try:p.wait(timeout=1)
  except subprocess.TimeoutExpired:p.kill();p.wait()
 print('probe result:',p.returncode,'ready:',ready,'elapsed_seconds:',round(time.monotonic()-start,1),flush=True)
finally:
 os.close(fd)
 if invitation.exists():
  with invitation.open('r+b',buffering=0) as f:
   n=os.fstat(f.fileno()).st_size; f.write(b'\0'*n); f.flush(); os.fsync(f.fileno())
  invitation.unlink()
