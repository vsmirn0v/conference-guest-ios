import { Room, RoomEvent, Track, setLogLevel } from 'livekit-client';

setLogLevel('warn');

const status = document.getElementById('status');
const people = document.getElementById('participants');
const count = document.getElementById('participant-count');
const controls = document.getElementById('media-controls');
const name = document.getElementById('name');
const chat = document.getElementById('chat');
const chatMessages = document.getElementById('chat-messages');
const chatInput = document.getElementById('chat-input');
const shareButton = document.getElementById('screen-share');
const demoButton = document.getElementById('demo-share');
const toneButton = document.getElementById('demo-tone');
import { chatTopic, encodeChat, decodeChat } from './chat-packet.js';
let session, pendingJoin;
const microphoneButton = document.getElementById('microphone');
const cameraButton = document.getElementById('camera');
function current(value) { return session === value && !value.closed; }
function clearVideos(value) {
  for (const [track, element] of value.videos) { track.detach(element); element.remove(); }
  value.videos = [];
}
function finishSession(value) {
  if (value.closed) return;
  value.closed = true;
  value.abort.abort();
  void stopDemoCard(value);
  void stopTone(value);
  clearVideos(value);
  for (const [track, element] of value.audio) { track.detach(element); element.remove(); }
  value.audio.clear();
  if (session !== value) return;
  session = undefined;
  controls.hidden = true; chat.hidden = true;
  chatMessages.textContent = 'No messages yet.';
  status.textContent = 'Left the jam.';
  people.replaceChildren(); count.textContent = '0 participants';
  microphoneButton.textContent = 'Turn microphone on'; cameraButton.textContent = 'Turn camera on';
}
function disconnect(value) {
  if (pendingJoin === value) pendingJoin = undefined;
  finishSession(value);
  void Promise.resolve(value.room.disconnect()).catch(() => {});
}

function addChat(sender, text) {
  if (chatMessages.textContent === 'No messages yet.') chatMessages.replaceChildren();
  const line = document.createElement('p');
  const heading = document.createElement('strong');
  heading.textContent = sender + ' · ' + new Date().toLocaleTimeString([], {hour:'2-digit', minute:'2-digit'});
  const body = document.createElement('span');
  body.textContent = text;
  line.append(heading, body);
  chatMessages.append(line);
  while (chatMessages.childElementCount > 200) chatMessages.firstElementChild.remove();
  chatMessages.scrollTop = chatMessages.scrollHeight;
}

async function sendChat() {
  const value = session;
  if (!value || value.closed) return;
  const text = chatInput.value.trim();
  if (!text || [...text].length > 2000) return;
  const packet = {id: crypto.randomUUID(), text};
  try {
    await value.room.localParticipant.publishData(encodeChat(packet),
      {reliable:true, topic:chatTopic});
    if (!current(value)) return;
    addChat(value.room.localParticipant.name || 'You', text);
    if (chatInput.value.trim() === text) chatInput.value = '';
  } catch (error) { if (current(value)) status.textContent = 'Chat could not send: ' + error.message; }
}

document.getElementById('chat-send').addEventListener('click', sendChat);
chatInput.addEventListener('keydown', (event) => {
  if (event.key === 'Enter') { event.preventDefault(); sendChat(); }
});

document.getElementById('join-app').addEventListener('click', () => {
  const link = new URL('conferenceguest://join');
  link.searchParams.set('url', location.origin + '/jams/test');
  location.assign(link.href);
  status.textContent = 'If the app did not open, paste this jam address into Rock’n’Roll on iPhone.';
});

function updatePeople(value) {
  if (!current(value)) return;
  const room = value.room;
  clearVideos(value);
  const remote = [...room.remoteParticipants.values()];
  count.textContent = `${remote.length + 1} participant${remote.length ? 's' : ''}`;
  people.replaceChildren();
  const all = [room.localParticipant, ...remote];
  for (const participant of all) {
    const tile = document.createElement('div');
    tile.className = 'participant';
    tile.dataset.identity = participant.identity;
    const label = document.createElement('span');
    label.textContent = participant.name || 'Musician';
    tile.append(label);
    const audioOn = [...participant.audioTrackPublications.values()]
      .some((publication) => !publication.isMuted);
    const videoOn = [...participant.videoTrackPublications.values()]
      .some((publication) => !publication.isMuted && publication.source === Track.Source.Camera);
    const screenOn = [...participant.videoTrackPublications.values()]
      .some((publication) => !publication.isMuted && publication.source === Track.Source.ScreenShare);
    tile.dataset.audio = audioOn ? 'on' : 'off';
    tile.dataset.video = videoOn || screenOn ? 'on' : 'off';
    const media = document.createElement('small');
    media.textContent = `${audioOn ? 'Mic on' : 'Mic off'} · ${videoOn ? 'Camera on' : 'Camera off'}${screenOn ? ' · Screen sharing' : ''}`;
    tile.append(media);
    for (const publication of participant.videoTrackPublications.values()) {
      if (publication.track && !publication.isMuted) {
        const video = publication.track.attach();
        value.videos.push([publication.track, video]);
        video.autoplay = true;
        video.playsInline = true;
        if (participant === room.localParticipant) video.muted = true;
        tile.prepend(video);
      }
    }
    people.append(tile);
  }
}

function updateOwnMediaStatus(value) {
  if (!current(value)) return;
  const participant = value.room.localParticipant;
  const microphone = participant.isMicrophoneEnabled ? 'on' : 'off';
  const camera = participant.isCameraEnabled ? 'on' : 'off';
  const sharing = participant.isScreenShareEnabled;
  microphoneButton.textContent = `Turn microphone ${microphone === 'on' ? 'off' : 'on'}`;
  cameraButton.textContent = `Turn camera ${camera === 'on' ? 'off' : 'on'}`;
  microphoneButton.disabled = value.microphonePending;
  cameraButton.disabled = value.cameraPending;
  shareButton.disabled = value.sharePending;
  shareButton.textContent = sharing ? 'Stop screen share' : 'Share screen';
  demoButton.textContent = value.demo ? 'Stop demo card' : 'Share demo card';
  toneButton.textContent = value.tone ? 'Stop test tone' : 'Send test tone';
  status.textContent = `You are in the jam. Microphone ${microphone}; camera ${camera}${sharing ? '; sharing screen' : ''}.`;
  updatePeople(value);
}

document.getElementById('join-browser').addEventListener('click', async () => {
  const displayName = name.value.trim();
  if (!displayName || [...displayName].length > 60 || /\p{Cc}/u.test(displayName)) {
    status.textContent = 'Enter a name of up to 60 characters.';
    return;
  }
  if (session) return;
  // Own this attempt before the first await. Every callback retains its room.
  const value = {room: new Room(), abort: new AbortController(), closed: false,
    videos: [], audio: new Map(), seenChatIDs: new Set(),
    microphonePending: false, cameraPending: false, sharePending: false};
  session = value;
  pendingJoin = value;
  const room = value.room;
  status.textContent = 'Connecting…';
  try {
    room.on(RoomEvent.ParticipantConnected, () => updatePeople(value));
    room.on(RoomEvent.ParticipantDisconnected, () => updatePeople(value));
    room.on(RoomEvent.TrackSubscribed, (track) => {
      if (!current(value)) return;
      if (track.kind === Track.Kind.Audio && !value.audio.has(track)) {
        const element = track.attach();
        element.dataset.audioTrack = track.sid;
        value.audio.set(track, element);
        document.body.append(element);
      }
      updatePeople(value);
    });
    room.on(RoomEvent.TrackUnsubscribed, (track) => {
      track.detach().forEach(element => element.remove());
      value.audio.delete(track);
      updatePeople(value);
    });
    for (const event of [RoomEvent.TrackPublished, RoomEvent.TrackUnpublished,
      RoomEvent.TrackMuted, RoomEvent.TrackUnmuted, RoomEvent.LocalTrackPublished, RoomEvent.LocalTrackUnpublished]) {
      room.on(event, () => updateOwnMediaStatus(value));
    }
    room.on(RoomEvent.DataReceived, (payload, participant, _kind, topic) => {
      if (!current(value) || topic !== chatTopic) return;
      try {
        const packet = decodeChat(payload);
        const identity = (participant?.identity || '') + ':' + packet.id;
        if (value.seenChatIDs.has(identity)) return;
        value.seenChatIDs.add(identity);
        if (value.seenChatIDs.size > 2048) value.seenChatIDs.delete(value.seenChatIDs.values().next().value);
        addChat(participant?.name || 'Musician', packet.text);
      } catch { /* Ignore malformed room data. */ }
    });
    room.on(RoomEvent.Disconnected, () => finishSession(value));
    const response = await fetch('/api/jams/test/join', {
      method: 'POST', headers: {'Content-Type':'application/json'},
      body: JSON.stringify({name: displayName}), cache: 'no-store', signal: value.abort.signal
    });
    if (!current(value)) return;
    if (!response.ok) throw new Error(await response.text());
    const credentials = await response.json();
    if (!current(value)) return;
    await room.connect(credentials.server_url, credentials.participant_token);
    if (!current(value)) { disconnect(value); return; }
    await room.startAudio();
    if (!current(value)) { disconnect(value); return; }
    controls.hidden = false;
    shareButton.hidden = !navigator.mediaDevices?.getDisplayMedia;
    demoButton.hidden = typeof HTMLCanvasElement.prototype.captureStream !== 'function';
    toneButton.hidden = typeof (window.AudioContext || window.webkitAudioContext) !== 'function';
    chat.hidden = false;
    updateOwnMediaStatus(value);
    if (pendingJoin === value) pendingJoin = undefined;
  } catch (error) {
    const report = pendingJoin === value;
    disconnect(value);
    if (report) status.textContent = 'Could not join: ' + (error.message || String(error));
  }
});

function mediaToggle(button, property, method, pending, label) {
  button.addEventListener('click', async () => {
    const value = session;
    if (!value || value.closed || value[pending]) return;
    const participant = value.room.localParticipant;
    const enabled = !participant[property];
    value[pending] = true; updateOwnMediaStatus(value);
    try {
      await participant[method](enabled);
      // A permission prompt can outlive Leave. Retire capture on that room only.
      if (!current(value) && enabled) await participant[method](false);
    } catch (error) {
      if (current(value)) {
        updateOwnMediaStatus(value);
        status.textContent = label + ' unavailable: ' + error.message;
      }
      return;
    } finally {
      value[pending] = false;
      if (current(value)) button.disabled = false;
    }
    updateOwnMediaStatus(value);
  });
}
mediaToggle(microphoneButton, 'isMicrophoneEnabled', 'setMicrophoneEnabled', 'microphonePending', 'Microphone');
mediaToggle(cameraButton, 'isCameraEnabled', 'setCameraEnabled', 'cameraPending', 'Camera');
async function stopTone(value) {
  const resource = value.tone;
  if (!resource) return;
  value.tone = undefined;
  resource.stopped = true;
  if (resource.timer) clearTimeout(resource.timer);
  resource.track?.stop();
  try { resource.oscillator?.stop(); } catch { /* Already stopped. */ }
  if (resource.context) void resource.context.close().catch(() => {});
  updateOwnMediaStatus(value);
  if (resource.published) {
    try { await value.room.localParticipant.unpublishTrack(resource.track); } catch { /* Track is already stopped. */ }
  }
}
toneButton.addEventListener('click', async () => {
  const value = session;
  if (!value || value.closed) return;
  if (value.tone) { await stopTone(value); return; }
  if (value.room.localParticipant.isMicrophoneEnabled) {
    status.textContent = 'Turn off your microphone before sending the test tone.';
    return;
  }
  const resource = {stopped: false, published: false};
  value.tone = resource;
  try {
    const AudioContextType = window.AudioContext || window.webkitAudioContext;
    resource.context = new AudioContextType();
    const destination = resource.context.createMediaStreamDestination();
    const volume = resource.context.createGain();
    volume.gain.value = 0.08;
    resource.oscillator = resource.context.createOscillator();
    resource.oscillator.frequency.value = 440;
    resource.oscillator.connect(volume);
    volume.connect(destination);
    resource.oscillator.start();
    const track = destination.stream.getAudioTracks()[0];
    resource.track = track;
    await value.room.localParticipant.publishTrack(track,
      {source: Track.Source.Microphone, name: 'Test tone'});
    resource.published = true;
    if (!current(value) || resource.stopped || value.tone !== resource) {
      track.stop();
      try { await value.room.localParticipant.unpublishTrack(track); } catch { /* Retired room. */ }
      return;
    }
    resource.timer = setTimeout(() => { if (value.tone === resource) void stopTone(value); }, 12000);
    updateOwnMediaStatus(value);
  } catch (error) {
    if (value.tone === resource) await stopTone(value);
    if (current(value)) status.textContent = 'Test tone unavailable: ' + error.message;
  }
});
shareButton.addEventListener('click', async () => {
  const value = session;
  if (!value || value.closed || value.sharePending) return;
  if (value.demo) { await stopDemoCard(value); return; }
  value.sharePending = true; updateOwnMediaStatus(value);
  try {
    await value.room.localParticipant.setScreenShareEnabled(!value.room.localParticipant.isScreenShareEnabled);
    if (!current(value)) await value.room.localParticipant.setScreenShareEnabled(false);
    updateOwnMediaStatus(value);
  } catch (error) { if (current(value)) status.textContent = 'Screen share unavailable: ' + error.message; }
  finally { value.sharePending = false; if (current(value)) shareButton.disabled = false; }
});
async function stopDemoCard(value) {
  const resource = value.demo;
  if (!resource) return;
  value.demo = undefined;
  resource.stopped = true;
  if (resource.timer) clearInterval(resource.timer);
  resource.track?.stop();
  updateOwnMediaStatus(value);
  if (resource.published) {
    try { await value.room.localParticipant.unpublishTrack(resource.track); } catch { /* Track is already stopped. */ }
  }
}

demoButton.addEventListener('click', async () => {
  const value = session;
  if (!value || value.closed || value.sharePending) return;
  if (value.demo) { await stopDemoCard(value); return; }
  const resource = {stopped: false, published: false};
  value.demo = resource;
  try {
    if (value.room.localParticipant.isScreenShareEnabled) {
      await value.room.localParticipant.setScreenShareEnabled(false);
      if (!current(value) || resource.stopped) return;
    }
    const canvas = document.createElement('canvas');
    canvas.width = 1280;
    canvas.height = 720;
    const context = canvas.getContext('2d');
    const draw = () => {
      const time = Date.now() / 1000;
      context.fillStyle = '#171726';
      context.fillRect(0, 0, canvas.width, canvas.height);
      context.fillStyle = '#d6fc62';
      context.font = 'bold 66px system-ui';
      context.fillText('Rock’n’Roll', 90, 132);
      context.fillStyle = '#e9e9f2';
      context.font = '34px system-ui';
      context.fillText('Screen-share demo · zoom in on the score', 90, 208);
      context.strokeStyle = '#8d8da8';
      context.lineWidth = 3;
      for (let line = 0; line < 5; line++) {
        const y = 320 + line * 50;
        context.beginPath(); context.moveTo(90, y); context.lineTo(1190, y); context.stroke();
      }
      const step = Math.floor(time * 2) % 8;
      for (let note = 0; note < 8; note++) {
        context.fillStyle = note === step ? '#d6fc62' : '#e9e9f2';
        context.beginPath(); context.ellipse(160 + note * 140, 420 - (note % 4) * 50,
          23, 17, -0.35, 0, Math.PI * 2); context.fill();
      }
    };
    draw();
    const track = canvas.captureStream(10).getVideoTracks()[0];
    resource.track = track;
    await value.room.localParticipant.publishTrack(track,
      {source: Track.Source.ScreenShare, name: 'Demo score', simulcast: false});
    resource.published = true;
    if (!current(value) || resource.stopped || value.demo !== resource) {
      track.stop();
      try { await value.room.localParticipant.unpublishTrack(track); } catch { /* Retired room. */ }
      return;
    }
    resource.timer = setInterval(draw, 100);
    updateOwnMediaStatus(value);
  } catch (error) {
    if (value.demo === resource) await stopDemoCard(value);
    if (current(value)) status.textContent = 'Demo card unavailable: ' + error.message;
  }
});
document.getElementById('leave').addEventListener('click', () => { if (session) disconnect(session); });
