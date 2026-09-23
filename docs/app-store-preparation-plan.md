# Rock’n’Roll: TestFlight and App Store preparation plan

Original plan, 23 September 2026. Implementation is underway: the native dual-engine build, public website, TLS, and isolated Podman services are deployed. See [current submission copy](app-store-metadata.md) and the validation record; the historical baseline and proposed release gates below remain useful, but planned steps are not proof of completion.

## 1. Decisions and product truth

- Keep the app name Rock’n’Roll.
- Present sessions as “jams” in the user interface.
- Intended audience: small music groups, with a proposed Yerevan, Armenia community. No street address is needed on the marketing page. Do not invent an established club, members, venue, or history. Confirm the real operator and support contact before publication.
- Support planning in-person jams, music discussion, and remote playing/demonstration. Do not advertise tightly synchronized ensemble playing until measured on representative networks and audio routes.
- Add an independent provider for `https://rock.glowsoft.ru/jams/...`.
- Preserve the existing provider and invitation support. Adding the rock service must not change how existing provider links join, publish media, route audio, or survive background/phone-call transitions.
- The rock test room is a disclosed, ordinary product demo, available through the same application code to users and reviewers. No reviewer detection, alternate review build, or concealed legacy functionality.
- Keep no-account guest access and no in-app room creation.
- Preserve the previous choice of custom-scheme web handoff. HTTPS pasting works directly; Universal Links are optional future work, not required for this plan.

Suggested positioning, subject to the community actually being the intended audience:

> Rock’n’Roll helps small music groups meet between rehearsals. Built for the Rock’n’Roll community in Yerevan, it lets musicians join a shared jam link, discuss arrangements, and play ideas for one another over live audio and video. It also supports compatible guest meeting invitations shared by the group.

The community purpose must be reflected in actual use and product content. A label change alone does not establish additional utility. Existing native calling, background audio, route control and interruption recovery are substantive functionality. Apple assesses usefulness and accurate presentation; a broad conferencing purpose is not automatically disallowed. See [App Review Guidelines 2.3 and 4.2](https://developer.apple.com/app-store/review/guidelines/).

## 2. Distribution stages

1. **Internal TestFlight:** App Store Connect team members, up to 100 eligible internal testers. This is not public App Store submission. Upload, processing, signing and export-compliance checks still apply.
2. **External TestFlight:** invited club members who are not App Store Connect team members are external testers, even if the group is private. The first external build requires beta review.
3. **App Store release:** separate metadata and review submission after beta acceptance. If the app really serves a limited community, consider unlisted distribution later; it still requires App Review and is not a beta-distribution substitute or an access-control mechanism.

Do not add community members to the developer team just to avoid external review. See [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/), [external testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/), and [unlisted distribution](https://developer.apple.com/support/unlisted-app-distribution).

## 3. Native app changes and provider separation

The app should expose a single session lifecycle, with provider-specific connection details behind adapters.

| Input | Route |
| --- | --- |
| Exact HTTPS host `rock.glowsoft.ru`, path `/jams/<id>` | New Rock service |
| Existing valid provider invitation | Existing adapter and discovery flow |
| Existing custom-scheme handoff | Unwrap once, validate, then use the same router |
| Malformed, unsupported or lookalike URL | Explain the error; do not guess a provider |

Proposed domain objects: `JamInvitation` (parsed public link), `JamDetails` (display metadata), `JoinCredentials` (ephemeral connection credentials), `JamSession` (state and desired/effective media state), and a `ConferenceProvider` contract implemented by two adapters. Use URLComponents and formal path parsing, not keyword inference. The link origin determines the join service; transport endpoints and credentials are returned by that service rather than compiled into the app.

One shared coordinator owns CallKit and AVAudioSession. Only the selected adapter may initialize/connect/start audio. Detach tracks, listeners and pending tasks before switching providers. A session generation prevents callbacks from a previous session altering the new one. The existing provider's global SDK initialization constraints must remain respected; show its existing endpoint limitation rather than claiming unsupported switching works.

Required invariants:

- One active jam and one system call.
- Microphone and camera off on every new join, including cross-provider switches.
- No received URL automatically enables media or leaves an active jam.
- Hold and route changes preserve the user's media intent.
- Closing a jam terminates its transport and releases its audio ownership.
- No private invite, token, transcript or participant name in diagnostics.

User-visible work:

- “Join a jam,” “Jam address,” “Your name,” “Join with mic and camera off,” and “Leave jam.” Update errors, accessibility labels, permission explanations and the system call label consistently.
- Offer a visible “Try a test jam” action that uses the ordinary rock invitation flow. It is available to everyone.
- Show the selected jam's title and community context before joining; preserve paste support for existing invitations.
- Keep participants, microphone/video controls, camera flip, route selection, background operation, and explicit Leave.
- Add native About, Privacy, Support and third-party notices. Do not replace the native conference UI with a website.
- Optional useful community content: organizer-provided session time, agenda/setlist titles, share invitation and Add to Calendar. Only claim scheduling/organization features once implemented and populated with genuine content.

## 4. New provider: self-hosted LiveKit

Recommendation: LiveKit server, native Swift SDK, and a small Go join API. Use the browser SDK only for the optional web join page. Pin tested releases. Retain all required third-party license notices.

This avoids implementing custom signaling, congestion control and a multiparty media router. LiveKit is an open-source SFU with Swift/browser SDKs and explicit CallKit integration. It provides a normal supported guest-token flow, without a provider-account login in the app. See [server](https://github.com/livekit/livekit) and [Swift SDK](https://github.com/livekit/client-sdk-swift).

Proposed flow:

1. User opens or pastes `https://rock.glowsoft.ru/jams/test`.
2. The app retrieves bounded, typed jam metadata from the same HTTPS origin.
3. On Join, it POSTs a guest nickname to `/api/jams/test/join`.
4. The API verifies that this is a configured, available jam, assigns a random session identity and returns a short-lived room-scoped token plus the WSS address.
5. The selected native adapter connects and subscribes. Publishing starts disabled.
6. Leave disconnects and releases transient session state.

Signing keys stay on the server. Clients never receive room administration grants. Reject arbitrary room creation through the token endpoint; use a configured jam registry initially. Bound input/body sizes, request rates, participant counts and idle-room lifetime. Do not cache token responses or log their bodies. Token expiry limits new authorization and must not be mistaken for automatic disconnection of an already connected participant; reconnect and removal behavior need explicit tests. See [LiveKit tokens](https://docs.livekit.io/frontends/build/authentication/).

For internal testing, begin with one small room and a conservative participant cap. The public `test` alias is intentionally a demo and must not contain private sessions. Real private jams require non-guessable invitation capabilities or organizer admission; a short human-readable room name alone is not authorization.

Use speech settings by default. An optional music mode should be tested with actual instruments and headphones, reducing speech-specific processing where the Swift SDK and hardware support it. High audio quality does not prove low enough end-to-end latency for synchronized ensemble performance. See [LiveKit audio options](https://docs.livekit.io/transport/media/advanced/).

This provider replacement does not establish capture during an active cellular call or recovery across an outage. Those remain separate research and consent/retention decisions. No recording, ASR service, capture companion or AI processing is required for this release.

## 5. Hosting without disturbing existing services

Read-only observations on 23 September:

- `rock.glowsoft.ru` resolves through Cloudflare and currently returns the KaChat website.
- `rock.glowlsoft.ru` does not resolve; the confirmed domain is `rock.glowsoft.ru`.
- SSH `root@kachat.app` reaches server `indexer`, IPv4 `46.225.51.10`.
- Nginx 1.24.0 owns 80/443. Existing sites are combined in `/etc/nginx/sites-enabled/default`; there is no rock virtual host.
- `nginx -t` passes with existing duplicate-protocol warnings. Do not “fix” unrelated configuration during this deployment.
- The server exposes 8 CPUs and 15 GiB RAM, with about 9.6 GiB available and 160 GiB disk free at inspection. Several other services are running. This supports a pilot hypothesis, not a concurrency guarantee.
- The existing KaChat certificate does not cover the rock hostname.

Proposed isolation:

- Own directory `/opt/rocknroll/`, own service/container names, restricted configuration/secrets, resource limits, bounded logs and pinned artifacts.
- Own static release directory `/var/www/rocknroll/`.
- Own nginx site `/etc/nginx/sites-available/rock.glowsoft.ru`, enabled separately. Do not modify the default site's contents, proxy targets or document root.
- Join API and LiveKit HTTP/control ports bind locally or on a private container network. Expose only the required client paths through the dedicated rock vhost.
- Obtain a separate certificate; inspect the actual Cloudflare origin TLS mode and use verified origin TLS. Do not run a deployment wizard that takes over ports 80/443 or replaces nginx with Caddy.
- Keep web/API traffic behind Cloudflare. WebRTC media and TURN require direct reachability; ordinary Cloudflare HTTP proxying is not a media relay. Proposed RTC/TURN hostnames are DNS-only and discovered from the join response.
- Start with documented UDP media, ICE/TCP and TURN connectivity. Port 443 TURN/TLS conflicts with existing nginx on this IP. Do not rewire the shared HTTPS listener. Test a supported external TURN endpoint on a separate port for the pilot; if 443-only network compatibility is required, use an additional IP or dedicated TURN relay. Decide that before promising broad-network reliability.
- Keep the initial deployment single-node; no Kubernetes, capture companion or recording service. Add Redis only if the selected deployment mode needs it.

Relevant networking sources: [LiveKit deployment](https://docs.livekit.io/transport/self-hosting/deployment/), [ports](https://docs.livekit.io/transport/self-hosting/ports-firewall/), [external TURN configuration](https://github.com/livekit/livekit/blob/master/config-sample.yaml), and [Cloudflare proxy ports](https://developers.cloudflare.com/fundamentals/reference/network-ports/).

Deployment procedure after approval of the plan: record baseline HTTP/WebSocket probes for every affected existing vhost; back up nginx configuration; start the new services privately; validate the new site; run `nginx -t`; reload gracefully; compare existing-site probes and resource usage. Rollback removes only the rock site/services and reloads the previously valid configuration. No global container cleanup, firewall flush, service restart, or unrelated configuration repair.

## 6. Website, privacy and community safety

Website pages:

- `/`: actual purpose, intended audience, native app capabilities, brief join instructions and community contact. Yerevan, Armenia is sufficient marketing location detail.
- `/privacy`: policy covering both providers, website infrastructure and local storage.
- `/support`: working contact and troubleshooting.
- `/community`: short behavior rules and how to report a problem.
- `/jams/test`: clear demo-room page, Open in Rock’n’Roll, optional Join in browser, and installation guidance appropriate to TestFlight availability.

Host fonts/assets locally, avoid advertising/analytics scripts, and keep secrets out of pages and query-string telemetry. The website must be useful and consistent with the native app, not merely a review facade.

The statement “we collect nothing and store nothing” is not currently supportable. The app saves catch-up intervals/transcripts locally; the existing provider receives guest/media/session information; nginx currently logs requests; Cloudflare processes requests. Apple's definition of collection distinguishes on-device processing and transient request handling from retained off-device data, and includes third-party partners. See [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/) and [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy).

Recommended policy structure:

1. No Rock’n’Roll account, advertising or behavioral analytics.
2. Nickname, enabled audio/video and connection information are processed to operate the selected jam; other participants can receive the media shared with them.
3. Explain separately which infrastructure is used for rock links and for existing provider links. Identify the operator and relevant service providers.
4. No server recording in rock rooms by default. Do not make a blanket no-recording claim about rooms controlled by another provider/organizer.
5. Preserve and describe existing protected local catch-up history, its deletion on Leave, manual deletion and expiry-on-next-launch behavior. Rock rooms have no ASR source in this plan; do not display a transcript-recovery promise there.
6. Specify actual operational-log and voluntary-support-report retention after inspecting/setting the configuration. Redact tokens and invitations. Do not select “Data Not Collected” from an SDK manifest alone.
7. Explain microphone/camera permission controls, support and privacy contacts, and changes to the policy.

For external distribution, implement meaningful report/block controls and organizer removal/admission for guest media rooms. Per-session mute is not a substitute for blocking abusive access. With no accounts, lasting revocation needs a defined invitation-capability/identity scheme and some minimal state; do not claim zero storage or durable bans unless the design actually supports them. The public demo must not become unrestricted stranger matching. See [Guideline 1.2](https://developer.apple.com/app-store/review/guidelines/#user-generated-content).

Retaining the current third-party provider also requires confirming its SDK/service distribution terms. Functional anonymous access is not by itself distribution authorization. See [Guideline 5.2.2](https://developer.apple.com/app-store/review/guidelines/#intellectual-property).

## 7. Review scenario and metadata

Suggested app subtitle: “Jam rooms for music groups”. Primary category: choose Music only if the actual product is music-focused; otherwise Social Networking better describes a general guest calling client. No invented niche to fit a category.

Draft description after the planned features exist:

> Rock’n’Roll is a lightweight meeting space for the Rock’n’Roll music community in Yerevan and the groups it invites. Open a jam link, choose a display name, and join live audio and video with your microphone and camera off. Discuss arrangements, share musical ideas, and stay connected between rehearsals. Native audio controls let you choose your output and keep listening while the screen is locked. The app supports Rock’n’Roll jam rooms and compatible guest meeting invitations. No account is required.

Do not claim synchronized remote ensemble playing, uninterrupted sound during telephone calls, automatic catch-up audio, or absence of all storage.

Reviewer steps:

1. Launch; enter `https://rock.glowsoft.ru/jams/test` and any test display name, or use the same public Try a test jam button.
2. Join with both media controls off. No membership account, payment or organizer approval is required for this demo.
3. Hear/see a clearly labelled, rights-owned diagnostic sample if a demo publisher is provided. It sends sample media and must not record the reviewer. This is an ordinary demo-room facility, not special review behavior.
4. Enable microphone/camera, inspect local preview and controls, change output, then mute and Leave. An optional second browser participant can verify two-way media without being required for basic app operation.
5. Test a separately supplied guest invitation for the preserved provider. Put a dedicated current test invitation in App Review notes, not source control or the public website; keep it available for the review window.
6. Explain background audio/VoIP use, phone-call hold/resume, and the local catch-up history accurately. Provide contact details and both-provider instructions in Review Notes.

The demo must remain available throughout review, including through a second external network. Supply actual screenshots of the submitted build. No live user names or private meeting material in screenshots.

## 8. Build, verification and submission order

1. Confirm operator/community wording, public support contact, tester category and the minimal retention policy.
2. Prove self-hosted transport privately: native phone plus browser, microphone/camera disabled by default, two-way speech/video, and TURN fallback. No change to existing sites beyond the isolated, validated addition.
3. Refactor the app into two adapters; apply jam wording and public demo flow. Keep native calling behavior and the existing invitation path.
4. Build the website/policies from verified data flows and deploy with baseline/rollback checks.
5. Run provider-isolation and cross-provider-switch tests; media publication/permissions; AirPods, receiver and speaker; Wi-Fi/cellular transitions; real outages; 30-minute lock; another app's audio; and an answered cellular call. Re-run for each provider because the old device results do not transfer to the new SDK.
6. Verify iPad layouts or deliberately make the first release iPhone-only before metadata/screenshots. The current target declares both iPhone and iPad.
7. Audit both SDKs and the archive for privacy manifests, required-reason APIs, licenses, telemetry, release logging and embedded credentials. Use App Store distribution signing with team `5V64BP2H3P`; retain the existing bundle identifier unless an explicit change is needed before creating the App Store Connect record.
8. Set the next unique build number, archive and validate. The installed toolchain is Xcode 27.0 build 27A266a; verify the exact upload acceptance at submission time. Apple currently lists Xcode 27/iOS 27 support in [App Store Connect release notes](https://developer.apple.com/help/app-store-connect/release-notes/).
9. Create/configure the App Store Connect app record, export-compliance answers, beta description, feedback/contact details and internal group. Upload for internal testing first; inspect processed-build errors and install via TestFlight on iVitalii.
10. Prepare external beta/App Store review only after both provider routes, safety controls, policies and live review rooms pass. Retain the private repository, source revision, signed archive and validation record.

Acceptance means the submitted build truthfully exposes both providers, joins both from an ordinary invitation, preserves mute/background/route behavior, documents actual data handling, and leaves existing server sites unaffected. Review approval cannot be guaranteed by branding or feature count.

Open inputs before publication: final community/operator identity and public support contact; internal team testers versus external club members; DNS access for RTC/TURN names; a relay strategy if 443-only networks must work; and verified data-retention/third-party terms for the preserved provider. None blocks preparing this plan, and none authorizes changing the server during the planning stage.
