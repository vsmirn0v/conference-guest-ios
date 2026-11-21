#!/usr/bin/env python3
"""Loopback claim registry. Operator commands are only accessible through host SSH."""
import argparse
import base64
import collections
import hashlib
import json
import os
import re
import secrets
import sqlite3
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer, ThreadingHTTPServer
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

HEX = re.compile(r'^[0-9a-f]{64}$')
CODE = re.compile(r'^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{5}-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{5}$')
ALPHABET = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ'
LIMIT = 50000
MAX_PERIOD = 32 * 86400
CODE_LIFETIME = 30 * 60
REVIEW_PERIOD = 7 * 86400
IP_PENDING_LIMIT = 20
VERIFY_KEY = Ed25519PublicKey.from_public_bytes(base64.b64decode('SyVA6vPGDZnu7wKtv9iqQM9Cj+zWxg2BdhkUXSH+og0='))
DB = '/var/lib/rock-author-support/claims.sqlite3'

def connect(path):
    db = sqlite3.connect(path, timeout=5, isolation_level=None, check_same_thread=False)
    db.execute('PRAGMA journal_mode=WAL')
    db.execute('PRAGMA max_page_count=8192')
    db.execute('CREATE TABLE IF NOT EXISTS claims (device TEXT NOT NULL, nonce TEXT NOT NULL, code_hash TEXT NOT NULL UNIQUE, expires INTEGER NOT NULL, envelope TEXT, PRIMARY KEY(device,nonce))')
    return db

def codehash(code): return hashlib.sha256(code.encode('ascii')).hexdigest()
def valid_pair(device, nonce): return isinstance(device, str) and isinstance(nonce, str) and bool(HEX.fullmatch(device) and HEX.fullmatch(nonce))
def new_code():
    s = ''.join(secrets.choice(ALPHABET) for _ in range(10))
    return s[:5] + '-' + s[5:]

def register(db, device, nonce, now, client_ip=None):
    if not valid_pair(device, nonce): raise ValueError('invalid request')
    db.execute('BEGIN IMMEDIATE')
    try:
        # Codes cannot be reconstructed from hashes, so store them separately only for the active window.
        row = db.execute('SELECT code,claims.expires,envelope FROM claim_codes JOIN claims USING(device,nonce) WHERE device=? AND nonce=?', (device, nonce)).fetchone()
        if row:
            if row[1] <= now or row[2] is not None: raise ValueError('claim expired or consumed')
            db.commit(); return {'code': row[0], 'expires': row[1]}
        if db.execute('SELECT 1 FROM claims WHERE device=? AND nonce=?',(device,nonce)).fetchone(): raise ValueError('claim expired or consumed')
        db.execute('DELETE FROM claims WHERE COALESCE(review_until,expires)<=? AND envelope IS NULL', (now,))
        db.execute('DELETE FROM claim_codes WHERE expires<=?', (now,))
        if db.execute('SELECT count(*) FROM claims').fetchone()[0] >= LIMIT: raise OverflowError('capacity')
        if client_ip is not None and 'client_ip' in {r[1] for r in db.execute('PRAGMA table_info(claims)')}:
            active_for_ip = db.execute(
                'SELECT count(*) FROM claims WHERE client_ip=? AND envelope IS NULL AND COALESCE(review_until,expires)>?',
                (client_ip, now)
            ).fetchone()[0]
            if active_for_ip >= IP_PENDING_LIMIT:
                raise OverflowError('capacity')
        for _ in range(8):
            code = new_code(); expiry = now + CODE_LIFETIME
            try:
                has_ip = 'client_ip' in {r[1] for r in db.execute('PRAGMA table_info(claims)')}
                if has_ip:
                    db.execute('INSERT INTO claims(device,nonce,code_hash,expires,client_ip) VALUES(?,?,?,?,?)',(device,nonce,codehash(code),expiry,client_ip))
                else:
                    db.execute('INSERT INTO claims(device,nonce,code_hash,expires) VALUES(?,?,?,?)',(device,nonce,codehash(code),expiry))
                db.execute('INSERT INTO claim_codes VALUES(?,?,?,?)',(device,nonce,code,expiry))
                break
            except sqlite3.IntegrityError: continue
        else: raise OverflowError('capacity')
        db.commit(); return {'code':code,'expires':expiry}
    except Exception:
        db.rollback(); raise

def init(db):
    # Both the HTTP service and SSH operator can start against an existing
    # registry. Serialize the additive migration with live claim operations.
    db.execute('BEGIN IMMEDIATE')
    try:
        columns = {row[1] for row in db.execute('PRAGMA table_info(claims)')}
        if 'review_until' not in columns:
            db.execute('ALTER TABLE claims ADD COLUMN review_until INTEGER')
        if 'client_ip' not in columns:
            db.execute('ALTER TABLE claims ADD COLUMN client_ip TEXT')
        db.execute('CREATE TABLE IF NOT EXISTS claim_codes (device TEXT NOT NULL, nonce TEXT NOT NULL, code TEXT NOT NULL, expires INTEGER NOT NULL, PRIMARY KEY(device,nonce))')
        db.commit()
    except Exception:
        db.rollback()
        raise

def mark_sent(db, device, nonce, now):
    """Reserve one bounded manual review. Only signed receipts confer membership."""
    if not valid_pair(device, nonce):
        raise ValueError('invalid request')
    db.execute('BEGIN IMMEDIATE')
    try:
        row = db.execute('SELECT expires,review_until,envelope IS NOT NULL FROM claims WHERE device=? AND nonce=?',
                         (device, nonce)).fetchone()
        if row is None:
            raise ValueError('claim unavailable')
        expires, deadline, issued = row
        if deadline is None:
            if issued or now >= expires:
                raise ValueError('claim unavailable')
            deadline = now + REVIEW_PERIOD
            db.execute('UPDATE claims SET review_until=? WHERE device=? AND nonce=?', (deadline, device, nonce))
        elif now >= deadline:
            raise ValueError('claim unavailable')
        db.commit()
        return {'reviewUntil': deadline}
    except Exception:
        db.rollback()
        raise

def lookup(db, code, now, update=False):
    if not isinstance(code,str) or not CODE.fullmatch(code): raise ValueError('invalid code')
    row=db.execute('SELECT device,nonce,expires,envelope,review_until FROM claims WHERE code_hash=?',(codehash(code),)).fetchone()
    if not row or (update and row[3] is None) or (not update and ((row[4] or row[2]) <= now or row[3] is not None)): raise ValueError('unknown, expired or consumed code')
    revision = json.loads(base64.b64decode(json.loads(row[3])['payload']))['revision'] if row[3] else 0
    return {'device':row[0], 'nonce':row[1], 'expires':row[2], 'revision':revision, 'reviewUntil':row[4]}

def consume(db, code, envelope, now, update=False, message_at=None):
    db.execute('BEGIN IMMEDIATE')
    try:
        claim=lookup(db,code,now,update)
        if not update and (now >= claim['expires'] or message_at is not None):
            if type(message_at) is not int or not claim['expires'] - CODE_LIFETIME <= message_at < claim['expires'] or message_at > now:
                raise ValueError('Boosty message must have been sent during code validity')
        if not isinstance(envelope,dict) or set(envelope)!={'payload','signature'}: raise ValueError('invalid envelope')
        raw=base64.b64decode(envelope['payload'],validate=True); signature=base64.b64decode(envelope['signature'],validate=True)
        if len(raw)>1024 or len(signature)!=64: raise ValueError('invalid envelope')
        try: VERIFY_KEY.verify(signature, raw)
        except InvalidSignature: raise ValueError('invalid signature')
        p=json.loads(raw)
        if set(p)!={'kind','schema','device','nonce','issued','through','revision'} or p['kind']!='membership' or p['schema']!=1 or p['device']!=claim['device'] or p['nonce']!=claim['nonce'] or any(type(p[k]) is not int or p[k]<0 for k in ('issued','through','revision')): raise ValueError('invalid payload')
        if abs(p['issued'] - now) > 300 or p['through'] > p['issued'] + MAX_PERIOD: raise ValueError('invalid receipt period')
        if p['revision'] <= claim['revision']: raise ValueError('revision must increase')
        serialized=json.dumps(envelope,separators=(',',':'))
        db.execute('UPDATE claims SET envelope=? WHERE device=? AND nonce=?',(serialized,claim['device'],claim['nonce']))
        db.execute('DELETE FROM claim_codes WHERE device=? AND nonce=?',(claim['device'],claim['nonce']))
        db.commit()
    except Exception:
        db.rollback(); raise

class Handler(BaseHTTPRequestHandler):
    server_version=''; sys_version=''
    def log_message(self,*args): pass
    def setup(self):
        super().setup(); self.connection.settimeout(5)
    def reply(self,status,obj):
        data=json.dumps(obj,separators=(',',':')).encode(); self.send_response(status)
        self.send_header('Content-Type','application/json'); self.send_header('Cache-Control','no-store'); self.send_header('X-Content-Type-Options','nosniff'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def _lock(self):
        lock = getattr(self.server, 'lock', None)
        if lock is None:
            lock = threading.Lock()
            self.server.lock = lock
        return lock

    def do_POST(self):
        operations = {
            '/author-support/claims': lambda db, d, n, ts, ip: register(db, d, n, ts, client_ip=ip),
            '/author-support/claims/sent': lambda db, d, n, ts, _ip: mark_sent(db, d, n, ts),
        }
        if self.path not in operations: return self.reply(404,{'error':'not found'})
        ip=self.headers.get('X-Real-IP','')
        if len(ip)>64 or not ip: return self.reply(400,{'error':'bad request'})
        now=time.time()
        with self._lock():
            rates=self.server.rates
            while rates and rates[0][0] <= now-60: rates.popleft()
            if len(rates)>=100 or sum(x[1]==ip for x in rates)>=10: return self.reply(429,{'error':'rate limited'})
            rates.append((now,ip))
        try:
            if self.headers.get('Transfer-Encoding') or self.headers.get('Content-Type','').split(';')[0].strip()!='application/json': raise ValueError()
            length=int(self.headers.get('Content-Length','0'))
            if not 1<=length<=1024: raise ValueError()
            data=json.loads(self.rfile.read(length))
            if not isinstance(data,dict) or set(data)!={'device','nonce'}: raise ValueError()
            with self._lock():
                result=operations[self.path](self.server.db,data['device'],data['nonce'],int(now),ip)
            return self.reply(200,result)
        except OverflowError: return self.reply(503,{'error':'capacity'})
        except sqlite3.Error: return self.reply(503,{'error':'unavailable'})
        except (ValueError,TypeError,KeyError,json.JSONDecodeError): return self.reply(400,{'error':'bad request'})
    def do_GET(self):
        parts=self.path.split('/')
        if len(parts)!=5 or parts[1:3]!=['author-support','receipts'] or not valid_pair(parts[3],parts[4]): return self.reply(404,{'error':'not found'})
        try:
            with self._lock():
                row=self.server.db.execute('SELECT envelope FROM claims WHERE device=? AND nonce=?',(parts[3],parts[4])).fetchone()
        except sqlite3.Error:
            return self.reply(503,{'error':'unavailable'})
        if not row or row[0] is None: return self.reply(404,{'error':'not found'})
        return self.reply(200,json.loads(row[0]))

def main():
    p=argparse.ArgumentParser(); p.add_argument('--db',default=DB); p.add_argument('command',choices=['serve','lookup','consume','lookup-update','update']); a=p.parse_args()
    db=connect(a.db); init(db)
    if a.command=='serve':
        server=ThreadingHTTPServer(('127.0.0.1',18792),Handler); server.db=db; server.rates=collections.deque(); server.lock=threading.Lock(); server.serve_forever()
    else:
        data=json.load(sys.stdin); now=int(time.time())
        if a.command in ('lookup','lookup-update'): print(json.dumps(lookup(db,data['code'],now,a.command=='lookup-update')))
        else: consume(db,data['code'],data['envelope'],now,a.command=='update',data.get('messageAt')); print('{"ok":true}')
if __name__=='__main__': main()
