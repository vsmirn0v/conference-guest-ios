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
if __name__=='__main__': unittest.main()

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
    url=base+'/author-support/receipts/'+d+'/'+n
    with self.assertRaises(urllib.error.HTTPError) as e: urllib.request.urlopen(url)
    self.assertEqual(e.exception.code,404)
    for _ in range(8):
     with urllib.request.urlopen(req): pass
    with self.assertRaises(urllib.error.HTTPError) as e: urllib.request.urlopen(req)
    self.assertEqual(e.exception.code,429)
   finally:
    server.shutdown(); server.server_close(); t.join()
