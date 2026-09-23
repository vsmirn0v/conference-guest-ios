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

Rock’n’Roll is a place for small music groups in Yerevan to meet between rehearsals. Open a shared jam link, enter a display name and join live audio and video with your microphone and camera off. Talk through arrangements, share an idea or plan the next in-person session.

Choose your audio output, turn on your microphone or camera when you want to contribute, and leave at any time. The app can keep your jam connected while the screen is locked and resumes after a telephone call. It also opens compatible guest meeting invitations shared by your group. No account is required.

The Catch up panel marks times when a call or network interruption may have caused you to miss audio. It displays transcript lines only when the room service actually supplies them; it does not record the call or create a recap of speech it could not receive.

## Internal beta description

Join a public test jam or a compatible invitation with native audio and video. Microphone and camera start off. Please test routes, background audio, call interruptions and recovery with another participant.

## App Review notes

Rock’n’Roll supports more than one jam engine. The public test jam exercises our self-hosted engine and is available in the same production build as every other supported link. No reviewer account, payment, or private access is needed.

1. Launch the app, enter any display name, and tap **Try the test jam**, or paste `https://rock.glowsoft.ru/jams/test`.
2. Tap **Join with mic and camera off**. The room is a public demo. To inspect two-way media, open the same URL in a second browser/device, enter a different name, and join there.
3. Turn on the microphone and camera explicitly, select an audio output, then turn them off and leave. On a physical iPhone, lock the screen to check background audio. During an ordinary incoming phone call, the jam is held and resumes after the call.
4. Other compatible guest invitations can be pasted or passed with `conferenceguest://join?url=<encoded HTTPS invitation>`. A current guest invitation should be supplied privately in review notes when that engine is tested; do not put a private invitation in screenshots or public pages.
5. The Catch up panel identifies possibly missed sections. The public test jam does not supply a transcript, so it accurately reports that no speech was recovered.

Contact: devcore@gmail.com. Privacy: https://rock.glowsoft.ru/privacy.

## Claims to verify before external submission

- Public test room is reachable from the reviewer’s region and remains available during review.
- All requested media, background and interruption behavior is retested for the new engine on the distribution build.
- Privacy questionnaire covers both engines and their SDKs; third-party notices are included as required.
- The guest-integration SDK’s service terms permit App Store distribution.
- Screenshots come from the signed release build and contain no private invitations.
