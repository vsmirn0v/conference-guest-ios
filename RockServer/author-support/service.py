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
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

HEX = re.compile(r'^[0-9a-f]{64}$')
CODE = re.compile(r'^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{5}-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{5}$')
ALPHABET = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ'
LIMIT = 50000
DB = '/var/lib/rock-author-support/claims.sqlite3'

def connect(path):
    db = sqlite3.connect(path, timeout=5, isolation_level=None)
    db.execute('PRAGMA journal_mode=WAL')
    db.execute('PRAGMA max_page_count=8192')
    db.execute('CREATE TABLE IF NOT EXISTS claims (device TEXT NOT NULL, nonce TEXT NOT NULL, code_hash TEXT NOT NULL UNIQUE, expires INTEGER NOT NULL, envelope TEXT, PRIMARY KEY(device,nonce))')
    return db

def codehash(code): return hashlib.sha256(code.encode('ascii')).hexdigest()
def valid_pair(device, nonce): return isinstance(device, str) and isinstance(nonce, str) and bool(HEX.fullmatch(device) and HEX.fullmatch(nonce))
def new_code():
    s = ''.join(secrets.choice(ALPHABET) for _ in range(10))
    return s[:5] + '-' + s[5:]

def register(db, device, nonce, now):
    if not valid_pair(device, nonce): raise ValueError('invalid request')
    db.execute('BEGIN IMMEDIATE')
    try:
        # Codes cannot be reconstructed from hashes, so store them separately only for the active window.
        row = db.execute('SELECT code,claims.expires,envelope FROM claim_codes JOIN claims USING(device,nonce) WHERE device=? AND nonce=?', (device, nonce)).fetchone()
        if row:
            if row[1] <= now or row[2] is not None: raise ValueError('claim expired or consumed')
            db.commit(); return {'code': row[0], 'expires': row[1]}
        if db.execute('SELECT 1 FROM claims WHERE device=? AND nonce=?',(device,nonce)).fetchone(): raise ValueError('claim expired or consumed')
        db.execute('DELETE FROM claims WHERE expires<=? AND envelope IS NULL', (now,))
        db.execute('DELETE FROM claim_codes WHERE expires<=?', (now,))
        if db.execute('SELECT count(*) FROM claims').fetchone()[0] >= LIMIT: raise OverflowError('capacity')
        for _ in range(8):
            code = new_code(); expiry = now + 1800
            try:
                db.execute('INSERT INTO claims(device,nonce,code_hash,expires) VALUES(?,?,?,?)',(device,nonce,codehash(code),expiry))
                db.execute('INSERT INTO claim_codes VALUES(?,?,?,?)',(device,nonce,code,expiry))
                break
            except sqlite3.IntegrityError: continue
        else: raise OverflowError('capacity')
        db.commit(); return {'code':code,'expires':expiry}
    except Exception:
        db.rollback(); raise

def init(db):
    db.execute('CREATE TABLE IF NOT EXISTS claim_codes (device TEXT NOT NULL, nonce TEXT NOT NULL, code TEXT NOT NULL, expires INTEGER NOT NULL, PRIMARY KEY(device,nonce))')

def lookup(db, code, now, update=False):
    if not isinstance(code,str) or not CODE.fullmatch(code): raise ValueError('invalid code')
    row=db.execute('SELECT device,nonce,expires,envelope FROM claims WHERE code_hash=?',(codehash(code),)).fetchone()
    if not row or (update and row[3] is None) or (not update and (row[2] <= now or row[3] is not None)): raise ValueError('unknown, expired or consumed code')
    revision = json.loads(base64.b64decode(json.loads(row[3])['payload']))['revision'] if row[3] else 0
    return {'device':row[0], 'nonce':row[1], 'expires':row[2], 'revision':revision}

def consume(db, code, envelope, now, update=False):
    db.execute('BEGIN IMMEDIATE')
    try:
        claim=lookup(db,code,now,update)
        if not isinstance(envelope,dict) or set(envelope)!={'payload','signature'}: raise ValueError('invalid envelope')
        raw=base64.b64decode(envelope['payload'],validate=True); signature=base64.b64decode(envelope['signature'],validate=True)
        if len(raw)>1024 or len(signature)!=64: raise ValueError('invalid envelope')
        p=json.loads(raw)
        if set(p)!={'kind','schema','device','nonce','issued','through','revision'} or p['kind']!='membership' or p['schema']!=1 or p['device']!=claim['device'] or p['nonce']!=claim['nonce'] or any(type(p[k]) is not int or p[k]<0 for k in ('issued','through','revision')): raise ValueError('invalid payload')
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
    def do_POST(self):
        if self.path!='/author-support/claims': return self.reply(404,{'error':'not found'})
        ip=self.headers.get('X-Real-IP','')
        if len(ip)>64 or not ip: return self.reply(400,{'error':'bad request'})
        now=time.time(); rates=self.server.rates
        while rates and rates[0][0] <= now-60: rates.popleft()
        if len(rates)>=100 or sum(x[1]==ip for x in rates)>=10: return self.reply(429,{'error':'rate limited'})
        rates.append((now,ip))
        try:
            if self.headers.get('Transfer-Encoding') or self.headers.get('Content-Type','').split(';')[0].strip()!='application/json': raise ValueError()
            length=int(self.headers.get('Content-Length','0'))
            if not 1<=length<=1024: raise ValueError()
            data=json.loads(self.rfile.read(length))
            if not isinstance(data,dict) or set(data)!={'device','nonce'}: raise ValueError()
            result=register(self.server.db,data['device'],data['nonce'],int(now)); return self.reply(200,result)
        except OverflowError: return self.reply(503,{'error':'capacity'})
        except (ValueError,TypeError,KeyError,json.JSONDecodeError): return self.reply(400,{'error':'bad request'})
    def do_GET(self):
        parts=self.path.split('/')
        if len(parts)!=5 or parts[1:3]!=['author-support','receipts'] or not valid_pair(parts[3],parts[4]): return self.reply(404,{'error':'not found'})
        row=self.server.db.execute('SELECT envelope FROM claims WHERE device=? AND nonce=?',(parts[3],parts[4])).fetchone()
        if not row or row[0] is None: return self.reply(404,{'error':'not found'})
        return self.reply(200,json.loads(row[0]))

def main():
    p=argparse.ArgumentParser(); p.add_argument('--db',default=DB); p.add_argument('command',choices=['serve','lookup','consume','lookup-update','update']); a=p.parse_args()
    db=connect(a.db); init(db)
    if a.command=='serve':
        server=HTTPServer(('127.0.0.1',18792),Handler); server.db=db; server.rates=collections.deque(); server.serve_forever()
    else:
        data=json.load(sys.stdin); now=int(time.time())
        if a.command in ('lookup','lookup-update'): print(json.dumps(lookup(db,data['code'],now,a.command=='lookup-update')))
        else: consume(db,data['code'],data['envelope'],now,a.command=='update'); print('{"ok":true}')
if __name__=='__main__': main()
