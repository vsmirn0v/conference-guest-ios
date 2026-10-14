import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { encodeChat, decodeChat, chatTopic } from './chat-packet.js';

const source = readFileSync(new URL('./app.js', import.meta.url), 'utf8')
  .replace("import { Room, RoomEvent, Track, setLogLevel } from 'livekit-client';", '')
  .replace("import { chatTopic, encodeChat, decodeChat } from './chat-packet.js';", '');
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return {promise, resolve, reject};
}
const flush = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };
function fixture() {
  class Element {
    constructor() { this.listeners = new Map(); this.children = []; this.dataset = {}; this.value = ''; this.textContent = ''; }
    addEventListener(name, action) { this.listeners.set(name, action); }
    click() { return this.listeners.get('click')?.({target: this}); }
    append(...items) { for (const item of items) { item.remove(); item.parent = this; this.children.push(item); } }
    prepend(item) { item.remove(); item.parent = this; this.children.unshift(item); }
    replaceChildren(...items) { for (const item of this.children) item.parent = undefined; this.children = []; this.append(...items); }
    remove() { if (this.parent) this.parent.children = this.parent.children.filter(item => item !== this); this.parent = undefined; }
    get childElementCount() { return this.children.length; }
    get firstElementChild() { return this.children[0]; }
  }
  const tracks = [];
  class MediaTrack {
    constructor(kind = 'video') { this.kind = kind; this.stopped = false; this.elements = new Set(); tracks.push(this); }
    stop() { this.stopped = true; }
    attach() { const element = new Element(); this.elements.add(element); return element; }
    detach(element) { const values = element ? [element] : [...this.elements]; for (const item of values) this.elements.delete(item); return values; }
  }
  const canvasContext = new Proxy({}, {get: (object, key) => object[key] ?? (() => {})});
  class Canvas extends Element {
    getContext() { return canvasContext; }
    captureStream() { const track = new MediaTrack(); return {getVideoTracks: () => [track]}; }
  }
  const contexts = [];
  class AudioContext {
    constructor() { this.closed = false; contexts.push(this); }
    createMediaStreamDestination() { const track = new MediaTrack('audio'); return {stream: {getAudioTracks: () => [track]}}; }
    createGain() { return {gain: {}, connect() {}}; }
    createOscillator() { return {frequency: {}, connect() {}, start() {}, stop() {}}; }
    async close() { this.closed = true; }
  }
  const elements = new Map();
  const get = id => { if (!elements.has(id)) elements.set(id, new Element()); return elements.get(id); };
  const rooms = [];
  class Room {
    constructor() {
      rooms.push(this); this.handlers = new Map(); this.remoteParticipants = new Map(); this.disconnects = 0;
      this.localParticipant = {
        identity: 'self', name: 'You', audioTrackPublications: new Map(), videoTrackPublications: new Map(),
        isMicrophoneEnabled: false, isCameraEnabled: false, isScreenShareEnabled: false,
        setMicrophoneEnabled: async enabled => { if (enabled && this.mediaGate) await this.mediaGate.promise; this.localParticipant.isMicrophoneEnabled = enabled; },
        setCameraEnabled: async enabled => { this.localParticipant.isCameraEnabled = enabled; },
        setScreenShareEnabled: async enabled => { this.localParticipant.isScreenShareEnabled = enabled; },
        publishTrack: async track => { this.publishing = track; if (this.publishGate) await this.publishGate.promise; },
        unpublishTrack: async track => { (this.unpublished ??= []).push(track); if (this.unpublishGate) await this.unpublishGate.promise; },
        publishData: async () => { if (this.dataGate) await this.dataGate.promise; }
      };
    }
    on(event, handler) { this.handlers.set(event, handler); }
    emit(event, ...args) { this.handlers.get(event)?.(...args); }
    async connect() { this.connects = (this.connects ?? 0) + 1; if (this.connectGate) await this.connectGate.promise; }
    async startAudio() {}
    async disconnect() { this.disconnects++; }
  }
  const RoomEvent = new Proxy({}, {get: (_, key) => key});
  const timers = new Map(); let nextTimer = 0;
  const schedule = fn => { const id = ++nextTimer; timers.set(id, fn); return id; };
  let fetchGate; let requests = 0;
  const response = {ok: true, json: async () => ({server_url: 'wss://example.test', participant_token: 'token'})};
  const sandbox = {Room, RoomEvent, Track: {Kind: {Audio: 'audio'}, Source: {Camera: 'camera', ScreenShare: 'screen', Microphone: 'microphone'}},
    setLogLevel() {}, chatTopic, encodeChat, decodeChat, AbortController, URL,
    crypto: {randomUUID: () => 'id'}, document: {getElementById: get, createElement: tag => tag === 'canvas' ? new Canvas() : new Element(), body: new Element()},
    navigator: {mediaDevices: {getDisplayMedia() {}}}, HTMLCanvasElement: Canvas, window: {AudioContext},
    location: {origin: 'https://example.test', assign() {}}, setTimeout: schedule, clearTimeout: id => timers.delete(id),
    setInterval: schedule, clearInterval: id => timers.delete(id),
    fetch: async () => { requests++; return fetchGate ? await fetchGate.promise : response; }};
  vm.runInNewContext(source, sandbox, {filename: 'app.js'});
  get('name').value = 'Maya';
  return {get, rooms, tracks, contexts, timers, response, MediaTrack, requests: () => requests,
    delayFetch: () => fetchGate = deferred(), click: id => get(id).click(), join: async () => { await get('join-browser').click(); return rooms.at(-1); }};
}

{
  const f = fixture(), gate = f.delayFetch();
  const first = f.click('join-browser'); await f.click('join-browser');
  assert.equal(f.requests(), 1); assert.equal(f.rooms.length, 1);
  gate.resolve(f.response); await first;
  assert.equal(f.get('media-controls').hidden, false);
}
{
  const f = fixture(), gate = f.delayFetch();
  const pending = f.click('join-browser');
  const old = f.rooms[0]; f.click('leave');
  gate.resolve(f.response); await pending;
  assert.equal(old.connects ?? 0, 0);
  await f.join();
  old.emit('Disconnected');
  assert.equal(f.get('media-controls').hidden, false);
}
{
  const f = fixture(), gate = f.delayFetch();
  const pending = f.click('join-browser');
  const old = f.rooms[0]; old.connectGate = deferred();
  gate.resolve(f.response); await flush();
  f.click('leave'); const second = f.click('join-browser'); await second;
  old.connectGate.resolve(); await pending;
  old.emit('Disconnected');
  assert.equal(f.get('media-controls').hidden, false);
  assert.match(f.get('status').textContent, /You are in the jam/);
  assert.ok(old.disconnects >= 2); assert.equal(f.rooms[1].disconnects, 0);
}
{
  const f = fixture(), gate = f.delayFetch();
  const pending = f.click('join-browser'), room = f.rooms[0];
  room.connectGate = deferred(); gate.resolve(f.response); await flush();
  room.emit('Disconnected');
  room.connectGate.reject(new Error('Signal connection failed')); await pending;
  assert.equal(f.get('status').textContent, 'Could not join: Signal connection failed');
  room.emit('Disconnected');
  assert.equal(f.get('status').textContent, 'Could not join: Signal connection failed');
}
{
  const f = fixture(), gate = f.delayFetch();
  const pending = f.click('join-browser'), room = f.rooms[0];
  room.connectGate = deferred(); gate.resolve(f.response); await flush();
  f.click('leave'); room.emit('Disconnected');
  room.connectGate.reject(new Error('Signal connection failed')); await pending;
  assert.equal(f.get('status').textContent, 'Left the jam.');
}
for (const replacementState of ['connecting', 'connected', 'ended']) {
  const f = fixture(), gate = f.delayFetch();
  const pending = f.click('join-browser'), old = f.rooms[0];
  old.connectGate = deferred(); gate.resolve(f.response); await flush();
  old.emit('Disconnected');
  const replacement = f.click('join-browser'), fresh = f.rooms[1];
  fresh.connectGate = deferred(); await flush();
  if (replacementState !== 'connecting') {
    fresh.connectGate.resolve(); await replacement;
    if (replacementState === 'ended') f.click('leave');
  }
  const expected = f.get('status').textContent;
  old.connectGate.reject(new Error('Old connection failed')); await pending;
  assert.equal(f.get('status').textContent, expected, replacementState);
  if (replacementState === 'connecting') {
    fresh.connectGate.resolve(); await replacement;
  }
}
{
  const f = fixture(); const old = await f.join();
  await f.click('camera'); await f.click('microphone');
  assert.equal(f.get('camera').textContent, 'Turn camera off');
  f.click('leave'); await f.join();
  assert.equal(f.get('camera').textContent, 'Turn camera on');
  assert.equal(f.get('microphone').textContent, 'Turn microphone on');
  old.emit('LocalTrackPublished'); assert.equal(f.get('camera').textContent, 'Turn camera on');
}
{
  const f = fixture(); const old = await f.join(); old.mediaGate = deferred();
  const pending = f.click('microphone'); f.click('leave'); const fresh = await f.join();
  old.mediaGate.resolve(); await pending;
  assert.equal(old.localParticipant.isMicrophoneEnabled, false);
  assert.equal(fresh.localParticipant.isMicrophoneEnabled, false);
  assert.equal(f.get('microphone').textContent, 'Turn microphone on');
}
for (const button of ['demo-tone', 'demo-share']) {
  const f = fixture(); const old = await f.join(); old.publishGate = deferred();
  const pending = f.click(button); const track = f.tracks.at(-1);
  f.click('leave'); assert.equal(track.stopped, true);
  const fresh = await f.join(); await f.click(button);
  const freshTrack = f.tracks.at(-1); const freshContext = f.contexts.at(-1);
  old.publishGate.resolve(); await pending;
  assert.equal(freshTrack.stopped, false); assert.equal(fresh.disconnects, 0);
  if (button === 'demo-tone') assert.equal(freshContext.closed, false);
  assert.ok(old.unpublished.includes(track));
  assert.equal(f.timers.size, 1);
  fresh.unpublishGate = deferred(); const stop = f.click(button);
  assert.equal(freshTrack.stopped, true); assert.equal(f.timers.size, 0);
  fresh.unpublishGate.reject(new Error('Disconnected')); await stop;
}
{
  const f = fixture(); const old = await f.join(); await f.click('demo-tone');
  old.unpublishGate = deferred(); const stopping = f.click('demo-tone');
  f.click('leave'); await f.join(); await f.click('demo-tone');
  const freshTrack = f.tracks.at(-1), freshContext = f.contexts.at(-1);
  old.unpublishGate.resolve(); await stopping;
  assert.equal(freshTrack.stopped, false); assert.equal(freshContext.closed, false);
}
{
  const f = fixture(); const old = await f.join(); old.dataGate = deferred();
  f.get('chat-input').value = 'Old meeting message'; const sending = f.click('chat-send');
  f.click('leave'); await f.join(); f.get('chat-input').value = 'New draft';
  old.dataGate.resolve(); await sending;
  assert.equal(f.get('chat-messages').childElementCount, 0);
  assert.equal(f.get('chat-input').value, 'New draft');
}
{
  const f = fixture(); const room = await f.join();
  const track = new f.MediaTrack();
  room.localParticipant.videoTrackPublications.set('video', {track, isMuted: false, source: 'camera'});
  for (let index = 0; index < 20; index++) room.emit('TrackPublished');
  assert.equal(track.elements.size, 1);
  f.click('leave'); assert.equal(track.elements.size, 0);
}
console.log('Browser session and media lifetime regressions passed');
