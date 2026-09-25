# Rock’n’Roll submission copy

Use this copy only with a build that passes the final device and service checks. It describes the same app available to all users and reviewers.

- **Name:** Rock’n’Roll
- **Subtitle:** Jam rooms for music groups
- **Primary category:** Music
- **Support URL:** https://rock.glowsoft.ru/support
- **Marketing URL:** https://rock.glowsoft.ru/
- **Privacy policy URL:** https://rock.glowsoft.ru/privacy
- **Support and privacy email:** devcore@gmail.com

## Description

Rock’n’Roll is a place for small music groups in Yerevan to meet between rehearsals. Open a shared jam link, choose a display name once and join live audio and video with your microphone and camera off. Keep favorite jams at the top of your recent list, chat with the group, talk through arrangements, share an idea or plan the next in-person session.

Choose your audio output, turn on your microphone or camera when you want to contribute, and leave at any time. See who is speaking and which musicians have audio, video or screen sharing on. Pin a camera or screen share, and pinch to zoom a shared screen. In Rock jam rooms, choose all video, screen shares only or audio only. The app can keep your jam connected while the screen is locked and resumes after a telephone call. It also opens compatible guest meeting invitations shared by your group. No account is required.

The Catch up panel marks times when a call or network interruption may have caused you to miss audio. It displays transcript lines only when the room service actually supplies them; it does not record the call or create a recap of speech it could not receive.

## TestFlight beta description

Rock’n’Roll is a jam room for small music groups in Yerevan. Join by link without an account, chat, see who is speaking, and pin or zoom a shared screen. Microphone and camera start off. Please test audio routes, background playback and call recovery with another participant.

## Build 0.2.0 (7): What to Test

Join the public test jam with microphone and camera off, then open a second browser participant at https://rock.glowsoft.ru/jams/test. Share the demo card and check All video, Screen shares, and Audio only. Open consecutive invitations and confirm the latest room connects with your saved name. Rotate the phone, use chat and Catch up, rename a starred recent jam, and verify that meeting audio returns after a call. For a compatible guest invitation, check that Screen shares follows an active share, hides camera video, and shows a clear empty state when sharing stops. Pinch to zoom a shared screen.

## Build 0.2.0 (11): What to Test

Join a room where another participant is sharing a screen. Pinch to zoom and pan the shared screen, then ask the participant to turn their camera on or off. The screen should remain at the chosen zoom level. Rotate the iPhone and check that zoom remains in place; use **Fit shared screen** to reset it. If sharing stops and starts again, the new share should begin fitted. Also check muted joining, chat, and audio recovery after a call.

## App Review notes

Rock’n’Roll supports more than one jam engine. The public test jam exercises our self-hosted engine and is available in the same production build as every other supported link. No reviewer account, payment, or private access is needed.

1. Launch the app, keep the suggested name or choose another, and tap **Try the test jam**, or paste `https://rock.glowsoft.ru/jams/test`.
2. Tap **Join with mic and camera off**. The room is a public demo. Open the same URL in a second browser/device, enter a different name, and join there. Its **Share demo card** button publishes a sample screen without capturing private content; **Send test tone** briefly exercises the speaking indicator.
3. In the app, open **Musicians** to inspect audio/video status and speaking activity. A screen share automatically becomes the main view. Pin its stream, pinch to zoom it, switch between all video, screen shares and audio only, and send chat. Turn on microphone and camera explicitly, select an audio output, then turn media off and leave. The joined jam appears in Recent jams and can be starred. On a physical iPhone, lock the screen to check background audio. During an ordinary incoming phone call, the jam is held and resumes after the call.
4. Other compatible guest invitations can be pasted or passed with `conferenceguest://join?url=<encoded HTTPS invitation>`. A current guest invitation should be supplied privately in review notes when that engine is tested; do not put a private invitation in screenshots or public pages.
5. The Catch up panel identifies possibly missed sections. The public test jam does not supply a transcript, so it accurately reports that no speech was recovered.

Contact: devcore@gmail.com. Privacy: https://rock.glowsoft.ru/privacy.

## Follow-ups before public App Store release

- Public test room is reachable from the reviewer’s region and remains available during review.
- All requested media, background and interruption behavior is retested for the new engine on the distribution build.
- Privacy questionnaire covers both engines and their SDKs; third-party notices are included as required.
- The guest-integration SDK’s service terms permit App Store distribution.
- Screenshots come from the signed release build and contain no private invitations.
