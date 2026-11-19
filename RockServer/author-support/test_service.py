import base64, importlib.util, json, pathlib, tempfile, unittest
spec=importlib.util.spec_from_file_location('service',pathlib.Path(__file__).with_name('service.py')); s=importlib.util.module_from_spec(spec); spec.loader.exec_module(s)
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

class Claims(unittest.TestCase):
 def setUp(self):
  self.key=Ed25519PrivateKey.generate(); s.VERIFY_KEY=self.key.public_key(); self.tmp=tempfile.TemporaryDirectory(); self.db=s.connect(str(pathlib.Path(self.tmp.name)/'test.db')); s.init(self.db); self.d='a'*64; self.n='b'*64
 def tearDown(self): self.db.close(); self.tmp.cleanup()
 def envelope(self,rev=1,through=10000,device=None,issued=100):
  p={'kind':'membership','schema':1,'device':device or self.d,'nonce':self.n,'issued':issued,'through':through,'revision':rev}
  raw=json.dumps(p).encode(); return {'payload':base64.b64encode(raw).decode(),'signature':base64.b64encode(self.key.sign(raw)).decode()}
 def test_idempotence_consume_and_refresh(self):
  a=s.register(self.db,self.d,self.n,100); self.assertEqual(a,s.register(self.db,self.d,self.n,101)); self.assertEqual(a['expires'],1900)
  self.assertEqual(s.lookup(self.db,a['code'],102)['device'],self.d); s.consume(self.db,a['code'],self.envelope(),103)
  with self.assertRaises(ValueError): s.consume(self.db,a['code'],self.envelope(),104)
  with self.assertRaises(ValueError): s.register(self.db,self.d,self.n,104)
  self.assertEqual(s.lookup(self.db,a['code'],2000,True)['revision'],1)
  with self.assertRaises(ValueError): s.consume(self.db,a['code'],self.envelope(),2000,True)
  s.consume(self.db,a['code'],self.envelope(2,0,issued=2000),2000,True)
  row=self.db.execute('SELECT envelope FROM claims WHERE device=? AND nonce=?',(self.d,self.n)).fetchone()
  self.assertEqual(json.loads(base64.b64decode(json.loads(row[0])['payload']))['through'],0)
 def test_expired_and_payload_binding(self):
  a=s.register(self.db,self.d,self.n,100)
  with self.assertRaises(ValueError): s.lookup(self.db,a['code'],1900)
  with self.assertRaises(ValueError): s.consume(self.db,a['code'],self.envelope(device='c'*64),101)
  self.assertIsNone(self.db.execute('SELECT envelope FROM claims').fetchone()[0])
 def test_rejects_signature_and_long_period(self):
  a=s.register(self.db,self.d,self.n,100); e=self.envelope(); e['signature']=base64.b64encode(b'x'*64).decode()
  with self.assertRaises(ValueError): s.consume(self.db,a['code'],e,101)
  with self.assertRaises(ValueError): s.consume(self.db,a['code'],self.envelope(through=100+32*86400+1),101)
  self.assertIsNone(self.db.execute('SELECT envelope FROM claims').fetchone()[0])
 def test_rejects_invalid_inputs(self):
  for value in ('A'*64,'a'*63,'x'*64,None):
   with self.assertRaises(ValueError): s.register(self.db,value,self.n,0)

 def test_submitting_preserves_one_review_window_and_does_not_grant(self):
  claim = s.register(self.db,self.d,self.n,100)
  last = claim['expires'] - 1
  result = s.mark_sent(self.db,self.d,self.n,last)
  deadline = last + 7 * 86400
  self.assertEqual(result,{'reviewUntil':deadline})
  self.assertEqual(s.mark_sent(self.db,self.d,self.n,deadline-1),result)
  s.register(self.db,'c'*64,'e'*64,last+2)
  self.assertIsNone(self.db.execute('SELECT envelope FROM claims WHERE device=?',(self.d,)).fetchone()[0])
  self.assertIsNone(self.db.execute('SELECT code FROM claim_codes WHERE device=?',(self.d,)).fetchone())
  self.assertEqual(s.lookup(self.db,claim['code'],deadline-1)['reviewUntil'],deadline)
  with self.assertRaises(ValueError): s.lookup(self.db,claim['code'],deadline)
  with self.assertRaises(ValueError): s.mark_sent(self.db,self.d,self.n,deadline)
  s.register(self.db,'a'*64,'e'*64,deadline)
  self.assertIsNone(self.db.execute('SELECT 1 FROM claims WHERE nonce=?',(self.n,)).fetchone())

 def test_late_first_submission_wrong_nonce_and_consumed_claim_do_not_extend(self):
  claim=s.register(self.db,self.d,self.n,100)
  for device,nonce,when in [(self.d,self.n,claim['expires']),('f'*64,self.n,102),(self.d,'e'*64,102)]:
   with self.assertRaises(ValueError): s.mark_sent(self.db,device,nonce,when)
  self.assertIsNone(self.db.execute('SELECT review_until FROM claims').fetchone()[0])
  s.consume(self.db,claim['code'],self.envelope(),102)
  with self.assertRaises(ValueError): s.mark_sent(self.db,self.d,self.n,103)

 def test_deferred_approval_requires_in_time_subscriber_message_and_signature(self):
  claim=s.register(self.db,self.d,self.n,100); code=claim['code']
  s.mark_sent(self.db,self.d,self.n,125)
  review_time=100+3*86400; envelope=self.envelope(issued=review_time,through=review_time+86400)
  for invalid in (None,False,99,claim['expires'],review_time):
   with self.assertRaises(ValueError): s.consume(self.db,code,envelope,review_time,message_at=invalid)
  with self.assertRaises(ValueError):
   s.consume(self.db,code,dict(envelope,signature=base64.b64encode(b'x'*64).decode()),review_time,message_at=101)
  s.consume(self.db,code,envelope,review_time,message_at=claim['expires']-1)
  with self.assertRaises(ValueError): s.consume(self.db,code,envelope,review_time,message_at=101)
  # Normal renewal and revocation still work after the pending review has ended.
  later=100+9*86400
  s.consume(self.db,code,self.envelope(rev=2,issued=later,through=later+86400),later,update=True)
  s.consume(self.db,code,self.envelope(rev=3,issued=later,through=0),later,update=True)
  self.assertEqual(s.lookup(self.db,code,later,update=True)['revision'],3)

 def test_additive_migration_preserves_existing_code_and_signed_receipt(self):
  db=s.sqlite3.connect(':memory:',isolation_level=None)
  self.addCleanup(db.close)
  db.execute('CREATE TABLE claims(device TEXT,nonce TEXT,code_hash TEXT UNIQUE,expires INTEGER,envelope TEXT,PRIMARY KEY(device,nonce))')
  active=s.new_code(); unused=s.new_code(); envelope=json.dumps(self.envelope())
  db.executemany('INSERT INTO claims VALUES(?,?,?,?,?)',[(self.d,self.n,s.codehash(active),120,envelope),
                 ('c'*64,'d'*64,s.codehash(unused),250,None)])
  s.init(db); s.init(db)
  self.assertEqual(s.lookup(db,active,1000,update=True)['revision'],1)
  self.assertEqual(s.mark_sent(db,'c'*64,'d'*64,200),{'reviewUntil':200+s.REVIEW_PERIOD})
  self.assertEqual(db.execute('SELECT envelope FROM claims WHERE device=?',(self.d,)).fetchone()[0],envelope)

class HTTPClaims(unittest.TestCase):
 def test_http_end_to_end(self):
  import threading, urllib.request, urllib.error
  with tempfile.TemporaryDirectory() as tmp:
   db=s.connect(str(pathlib.Path(tmp)/'test.db')); s.init(db)
   db.close()
   ready=threading.Event(); holder={}
   def run():
    db=s.connect(str(pathlib.Path(tmp)/'test.db')); server=s.HTTPServer(('127.0.0.1',0),s.Handler); server.db=db; server.rates=s.collections.deque(); holder['server']=server; ready.set(); server.serve_forever(); db.close()
   t=threading.Thread(target=run); t.start(); ready.wait(); server=holder['server']; base='http://127.0.0.1:'+str(server.server_port)
   try:
    d='c'*64; n='d'*64; data=json.dumps({'device':d,'nonce':n}).encode(); req=urllib.request.Request(base+'/author-support/claims',data=data,headers={'Content-Type':'application/json','X-Real-IP':'127.0.0.1'})
    with urllib.request.urlopen(req) as r: claim=json.load(r)
    with urllib.request.urlopen(req) as r: self.assertEqual(json.load(r),claim)
    sent=urllib.request.Request(base+'/author-support/claims/sent',data=data,headers={'Content-Type':'application/json','X-Real-IP':'127.0.0.1'})
    with urllib.request.urlopen(sent) as r:
     pending=json.load(r)
     self.assertEqual(set(pending),{'reviewUntil'})
    with urllib.request.urlopen(sent) as r: self.assertEqual(json.load(r),pending)
    url=base+'/author-support/receipts/'+d+'/'+n
    with self.assertRaises(urllib.error.HTTPError) as e: urllib.request.urlopen(url)
    self.assertEqual(e.exception.code,404)
    for _ in range(6):
     with urllib.request.urlopen(req): pass
    with self.assertRaises(urllib.error.HTTPError) as e: urllib.request.urlopen(sent)
    self.assertEqual(e.exception.code,429)
   finally:
    server.shutdown(); server.server_close(); t.join()

if __name__=='__main__': unittest.main()
