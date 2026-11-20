# Rock’n’Roll submission copy

## App Store listing

- Name — Rock’n’Roll
- Subtitle — Video meetings & voice replies
- Primary category — Business
- Secondary category — Productivity
- Keywords — video call,meetings,conference,live transcript,voice reply,screen sharing,calendar,notes,tasks,jam
- Support URL — https://rock.glowsoft.ru/support
- Marketing URL — https://rock.glowsoft.ru/
- Privacy policy URL — https://rock.glowsoft.ru/privacy
- Support and privacy email — devcore@gmail.com

## Description

Join a team call, a class or a rehearsal from one place. Paste your invitation link, enter the name you want people to see, and tap Join. Your microphone and camera start off. Rock’n’Roll is an independent conferencing app for iPhone and iPad.

One app for several meeting services

Join Rock’n’Roll rooms and other LiveKit rooms whose hosts support Rock’n’Roll-compatible invitations. The same invitation field accepts compatible enterprise guest invitations, including Yandex Telemost and TrueConf links. The host controls admission and which features are available. Try the public LiveKit room at rock.glowsoft.ru/jams/test.

During a meeting

See who is speaking, chat, share your screen and pin or zoom a presentation. Switch between camera feeds, shared screens and audio-only listening. Stay connected to more than one meeting and choose which one receives your microphone. Check your camera and sound before joining, choose your audio output and keep listening with the screen locked. Recording controls are available when the meeting service and your role permit them.

Speech and meeting notes

Follow a live transcript with speech recognition in supported languages. Type a reply and send it as speech using a system voice, your authorized Personal Voice, or an optional voice model on a compatible device. A configurable voice server is also available. In supported meetings, the optional assistant can flag mentions, help draft chat or spoken replies, and generate summaries using the provider you configure. Let participants know before transcribing or recording.

Between meetings

Star invitations, find upcoming calls in calendars you choose, and set reminders. Keep meeting history, notes and tasks together. Optional iCloud sync makes selected meeting data available on devices using the same Apple Account.

## Private App Review notes

Rock’n’Roll is a multi-service conferencing client. Version 1.0 previously presented the app primarily as a music community. The third-party conferencing capability identified under Guideline 2.5.19 is a core feature available to every user through the Home screen’s Invitation link field. The app has built-in adapters for compatible LiveKit, Jazz, Yandex Telemost and TrueConf meetings. The MeetingEngine module selects RockAdapter, GuestAdapter, TelemostAdapter or TrueConfAdapter from the invitation. These compiled components handle joining, media and call controls. LiveKit Swift and WebRTC provide media infrastructure. The same Home screen and code paths are used for all users.

To test the LiveKit path, open Home, paste https://rock.glowsoft.ru/jams/test into Invitation link, enter a display name under Your name and tap Join. No Rock’n’Roll account or payment is required for this room. Join the same URL in a second browser under another name. Use its demo card or test tone to check screen sharing and active speaker, or exchange a chat message. The app starts with microphone and camera off. The same invitation field accepts guest links for the other supported services. Room access and features depend on the host.

Open Settings > Transcription & voice to inspect speech recognition and voice generation. In a supported meeting, enter a voice reply and choose to send it. Optional voice models require a download and compatible hardware. In Settings > Assistant & summaries, configure optional assistance. External speech synthesis and external AI each require a separate opt-in for the selected recipient. Settings > About > Third-party notices shows the bundled software licenses. Calendar access, iCloud sync and AI provider setup are optional for joining the public room.

## Build 0.2.0 (7): What to Test

Join the public test jam with microphone and camera off, then open a second browser participant at https://rock.glowsoft.ru/jams/test. Share the demo card and check All video, Screen shares, and Audio only. Open consecutive invitations and confirm the latest room connects with your saved name. Rotate the phone, use chat and Catch up, rename a starred recent jam, and verify that meeting audio returns after a call. For a compatible guest invitation, check that Screen shares follows an active share, hides camera video, and shows a clear empty state when sharing stops. Pinch to zoom a shared screen.

## Build 0.2.0 (11): What to Test

Join a room where another participant is sharing a screen. Pinch to zoom and pan the shared screen, then ask the participant to turn their camera on or off. The screen should remain at the chosen zoom level. Rotate the iPhone and check that zoom remains in place; use **Fit shared screen** to reset it. If sharing stops and starts again, the new share should begin fitted. Also check muted joining, chat, and audio recovery after a call.

## Build 0.2.0 (13): What to Test

Join a jam with a second participant sharing a screen or camera. Check that the focused video has clear blacks, motion stays smooth, and pinch zoom remains in place through participant updates and rotation. Try chat, Catch up, and floating video while multitasking. Switch between jam links, then check that the latest room uses your saved name. On a physical iPhone, check that meeting audio returns after a phone call without rejoining.

## Build 0.2.0 (14): What to Test

Join a compatible guest jam while another participant shares a moving screen. Send the app to Home and leave the floating video visible for at least two minutes, then switch to another app and back. The floating window should remain present and the shared screen should keep updating while the jam stays connected. Return to the jam and check that audio and share zoom still work. If the picture stops moving, report whether the floating window stayed visible or closed.
