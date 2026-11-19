#!/usr/bin/env python3
"""Run locally after verifying a membership; the signing key stays in Keychain."""
import argparse, base64, getpass, json, os, pathlib, re, subprocess, tempfile, time, urllib.request
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('action',choices=['issue','renew','revoke']); p.add_argument('--code',help='private enrollment reference (omit to prompt securely)')
p.add_argument('--through',type=int,help='inclusive Unix expiry; required for issue/renew')
p.add_argument('--host',default='root@kachat.app'); p.add_argument('--sign-tool',default=str(pathlib.Path(__file__).resolve().parents[2]/'.build/native-dmg/Sparkle/bin/sign_update'))
a=p.parse_args()
if a.code is None: a.code=getpass.getpass('Private enrollment reference: ').strip()
if not re.fullmatch(r'[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{5}-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{5}',a.code): p.error('invalid code')
if a.action != 'revoke' and (a.through is None or a.through<=int(time.time())): p.error('--through must be a future Unix timestamp')
if a.action == 'revoke' and a.through is not None: p.error('revocation sets through=0')
def remote(command,data):
    result=subprocess.run(['ssh','-o','BatchMode=yes',a.host,'/usr/bin/python3','/opt/rock-author-support/service.py',command], input=json.dumps(data),text=True,capture_output=True,check=True)
    return json.loads(result.stdout)
public=subprocess.check_output([str(pathlib.Path(a.sign_tool).with_name('generate_keys')),'--account','dev.vsmirn0v.rocknroll.support.receipts','-p'],text=True).strip()
if public != 'SyVA6vPGDZnu7wKtv9iqQM9Cj+zWxg2BdhkUXSH+og0=': raise ValueError('unexpected signing public key')
update=a.action!='issue'; claim=remote('lookup-update' if update else 'lookup',{'code':a.code})
payload={'kind':'membership','schema':1,'device':claim['device'],'nonce':claim['nonce'],'issued':int(time.time()),'through':0 if a.action=='revoke' else a.through,'revision':claim['revision']+1}
raw=json.dumps(payload,separators=(',',':'),sort_keys=True).encode()
with tempfile.TemporaryDirectory() as directory:
    f=pathlib.Path(directory)/'payload.bin'; f.write_bytes(raw); os.chmod(f,0o600)
    sign=[a.sign_tool,'--account','dev.vsmirn0v.rocknroll.support.receipts']
    sig=subprocess.check_output(sign+['-p',str(f)],text=True).strip()
    subprocess.run(sign+['--verify',str(f),sig],check=True,stdout=subprocess.DEVNULL)
    if len(base64.b64decode(sig,validate=True)) != 64: raise ValueError('invalid signature')
envelope={'payload':base64.b64encode(raw).decode(),'signature':sig}
remote('update' if update else 'consume',{'code':a.code,'envelope':envelope})
with urllib.request.urlopen('https://rock.glowsoft.ru/author-support/receipts/'+payload['device']+'/'+payload['nonce'],timeout=10) as response:
    if json.load(response) != envelope: raise ValueError('public receipt readback mismatch')
print(json.dumps({'device':payload['device'],'nonce':payload['nonce'],'revision':payload['revision'],'through':payload['through'],'payloadSHA256':__import__('hashlib').sha256(raw).hexdigest()}))
