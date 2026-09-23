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
let demoTrack;
let demoTimer;
let toneTrack;
let toneContext;
let toneOscillator;
let toneTimer;
const chatTopic = 'rock.chat.v1';
let room;

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
  if (!room) return;
  const text = chatInput.value.trim();
  if (!text || [...text].length > 2000) return;
  const packet = {id: crypto.randomUUID(), text};
  try {
    await room.localParticipant.publishData(new TextEncoder().encode(JSON.stringify(packet)),
      {reliable:true, topic:chatTopic});
    addChat(room.localParticipant.name || 'You', text);
    chatInput.value = '';
  } catch (error) { status.textContent = 'Chat could not send: ' + error.message; }
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

function updatePeople() {
  if (!room) return;
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
        video.autoplay = true;
        video.playsInline = true;
        if (participant === room.localParticipant) video.muted = true;
        tile.prepend(video);
      }
    }
    people.append(tile);
  }
}

function updateOwnMediaStatus() {
  if (!room) return;
  const microphone = room.localParticipant.isMicrophoneEnabled ? 'on' : 'off';
  const camera = room.localParticipant.isCameraEnabled ? 'on' : 'off';
  const sharing = room.localParticipant.isScreenShareEnabled;
  shareButton.textContent = sharing ? 'Stop screen share' : 'Share screen';
  demoButton.textContent = demoTrack ? 'Stop demo card' : 'Share demo card';
  toneButton.textContent = toneTrack ? 'Stop test tone' : 'Send test tone';
  status.textContent = `You are in the jam. Microphone ${microphone}; camera ${camera}${sharing ? '; sharing screen' : ''}.`;
  updatePeople();
}

document.getElementById('join-browser').addEventListener('click', async () => {
  const displayName = name.value.trim();
  if (!displayName || [...displayName].length > 60) {
    status.textContent = 'Enter a name of up to 60 characters.';
    return;
  }
  if (room) return;
  status.textContent = 'Connecting…';
  try {
    const response = await fetch('/api/jams/test/join', {
      method: 'POST', headers: {'Content-Type':'application/json'},
      body: JSON.stringify({name: displayName}), cache: 'no-store'
    });
    if (!response.ok) throw new Error(await response.text());
    const credentials = await response.json();
    room = new Room();
    room.on(RoomEvent.ParticipantConnected, updatePeople);
    room.on(RoomEvent.ParticipantDisconnected, updatePeople);
    room.on(RoomEvent.TrackSubscribed, (track) => {
      if (track.kind === Track.Kind.Audio) {
        const element = track.attach();
        element.dataset.audioTrack = track.sid;
        document.body.append(element);
      }
      updatePeople();
    });
    room.on(RoomEvent.TrackUnsubscribed, (track) => {
      track.detach().forEach(element => element.remove());
      updatePeople();
    });
    room.on(RoomEvent.TrackPublished, updatePeople);
    room.on(RoomEvent.TrackUnpublished, updatePeople);
    room.on(RoomEvent.TrackMuted, updatePeople);
    room.on(RoomEvent.TrackUnmuted, updatePeople);
    room.on(RoomEvent.LocalTrackPublished, updateOwnMediaStatus);
    room.on(RoomEvent.LocalTrackUnpublished, updateOwnMediaStatus);
    room.on(RoomEvent.DataReceived, (payload, participant, _kind, topic) => {
      if (topic !== chatTopic || payload.byteLength > 4096) return;
      try {
        const packet = JSON.parse(new TextDecoder().decode(payload));
        if (typeof packet.id !== 'string' || typeof packet.text !== 'string' ||
            !packet.text || [...packet.text].length > 2000) return;
        addChat(participant?.name || 'Musician', packet.text);
      } catch { /* Ignore malformed room data. */ }
    });
    room.on(RoomEvent.Disconnected, () => { room = undefined; void stopDemoCard(); void stopTone(); controls.hidden = true; chat.hidden = true; chatMessages.textContent = 'No messages yet.'; status.textContent = 'Left the jam.'; people.replaceChildren(); count.textContent = '0 participants'; });
    await room.connect(credentials.server_url, credentials.participant_token);
    await room.startAudio();
    controls.hidden = false;
    shareButton.hidden = !navigator.mediaDevices?.getDisplayMedia;
    demoButton.hidden = typeof HTMLCanvasElement.prototype.captureStream !== 'function';
    toneButton.hidden = typeof (window.AudioContext || window.webkitAudioContext) !== 'function';
    chat.hidden = false;
    updateOwnMediaStatus();
  } catch (error) {
    room?.disconnect(); room = undefined;
    status.textContent = 'Could not join: ' + (error.message || String(error));
  }
});

document.getElementById('microphone').addEventListener('click', async (event) => {
  if (!room) return;
  try {
    const enabled = !room.localParticipant.isMicrophoneEnabled;
    await room.localParticipant.setMicrophoneEnabled(enabled);
    event.target.textContent = enabled ? 'Turn microphone off' : 'Turn microphone on';
    updateOwnMediaStatus();
  } catch (error) { status.textContent = 'Microphone unavailable: ' + error.message; }
});
document.getElementById('camera').addEventListener('click', async (event) => {
  if (!room) return;
  try {
    const enabled = !room.localParticipant.isCameraEnabled;
    await room.localParticipant.setCameraEnabled(enabled);
    event.target.textContent = enabled ? 'Turn camera off' : 'Turn camera on';
    updateOwnMediaStatus();
  } catch (error) { status.textContent = 'Camera unavailable: ' + error.message; }
});
async function stopTone() {
  if (toneTimer) clearTimeout(toneTimer);
  toneTimer = undefined;
  const track = toneTrack;
  toneTrack = undefined;
  try {
    if (track && room) await room.localParticipant.unpublishTrack(track);
  } finally {
    track?.stop();
    try { toneOscillator?.stop(); } catch { /* Already stopped. */ }
    toneOscillator = undefined;
    if (toneContext) await toneContext.close();
    toneContext = undefined;
    if (room) updateOwnMediaStatus();
  }
}
toneButton.addEventListener('click', async () => {
  if (!room) return;
  try {
    if (toneTrack) { await stopTone(); return; }
    if (room.localParticipant.isMicrophoneEnabled) {
      status.textContent = 'Turn off your microphone before sending the test tone.';
      return;
    }
    const AudioContextType = window.AudioContext || window.webkitAudioContext;
    toneContext = new AudioContextType();
    const destination = toneContext.createMediaStreamDestination();
    const volume = toneContext.createGain();
    volume.gain.value = 0.08;
    toneOscillator = toneContext.createOscillator();
    toneOscillator.frequency.value = 440;
    toneOscillator.connect(volume);
    volume.connect(destination);
    toneOscillator.start();
    const track = destination.stream.getAudioTracks()[0];
    await room.localParticipant.publishTrack(track,
      {source: Track.Source.Microphone, name: 'Test tone'});
    toneTrack = track;
    toneTimer = setTimeout(() => { void stopTone(); }, 12000);
    updateOwnMediaStatus();
  } catch (error) {
    await stopTone();
    status.textContent = 'Test tone unavailable: ' + error.message;
  }
});
shareButton.addEventListener('click', async () => {
  if (!room) return;
  try {
    if (demoTrack) { await stopDemoCard(); updateOwnMediaStatus(); return; }
    await room.localParticipant.setScreenShareEnabled(!room.localParticipant.isScreenShareEnabled);
    updateOwnMediaStatus();
  } catch (error) { status.textContent = 'Screen share unavailable: ' + error.message; }
});
async function stopDemoCard() {
  if (demoTimer) clearInterval(demoTimer);
  demoTimer = undefined;
  if (!demoTrack) return;
  const track = demoTrack;
  demoTrack = undefined;
  if (room) await room.localParticipant.unpublishTrack(track);
  track.stop();
  if (room) updateOwnMediaStatus();
}

demoButton.addEventListener('click', async () => {
  if (!room) return;
  try {
    if (demoTrack) { await stopDemoCard(); return; }
    if (room.localParticipant.isScreenShareEnabled) {
      await room.localParticipant.setScreenShareEnabled(false);
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
    await room.localParticipant.publishTrack(track,
      {source: Track.Source.ScreenShare, name: 'Demo score', simulcast: false});
    demoTrack = track;
    demoTimer = setInterval(draw, 100);
    updateOwnMediaStatus();
  } catch (error) { status.textContent = 'Demo card unavailable: ' + error.message; }
});
document.getElementById('leave').addEventListener('click', () => room?.disconnect());
