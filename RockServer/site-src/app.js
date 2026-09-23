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
      .some((publication) => !publication.isMuted);
    tile.dataset.audio = audioOn ? 'on' : 'off';
    tile.dataset.video = videoOn ? 'on' : 'off';
    const media = document.createElement('small');
    media.textContent = `${audioOn ? 'Mic on' : 'Mic off'} · ${videoOn ? 'Camera on' : 'Camera off'}`;
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
  status.textContent = `You are in the jam. Microphone ${microphone}; camera ${camera}.`;
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
    room.on(RoomEvent.DataReceived, (payload, participant, _kind, topic) => {
      if (topic !== chatTopic || payload.byteLength > 4096) return;
      try {
        const packet = JSON.parse(new TextDecoder().decode(payload));
        if (typeof packet.id !== 'string' || typeof packet.text !== 'string' ||
            !packet.text || [...packet.text].length > 2000) return;
        addChat(participant?.name || 'Musician', packet.text);
      } catch { /* Ignore malformed room data. */ }
    });
    room.on(RoomEvent.Disconnected, () => { room = undefined; controls.hidden = true; chat.hidden = true; chatMessages.textContent = 'No messages yet.'; status.textContent = 'Left the jam.'; people.replaceChildren(); count.textContent = '0 participants'; });
    await room.connect(credentials.server_url, credentials.participant_token);
    await room.startAudio();
    controls.hidden = false;
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
document.getElementById('leave').addEventListener('click', () => room?.disconnect());
