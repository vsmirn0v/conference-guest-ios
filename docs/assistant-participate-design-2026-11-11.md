# Participate — an assistant that contributes to the meeting

Design proposal · 11 November 2026 · Native Mac first

Original design snapshot: local checkout `440a7e6`, including the working-tree changes present during inspection. At that point no autonomous behavior had been enabled. Attributed chat and approved-note participation were subsequently implemented in `15fd3a2`. The voice amendment below records the user's 12 November decisions; source changes do not establish availability in an installed release. Companion implementation plan: [assistant-participate-plan-2026-11-11.md](assistant-participate-plan-2026-11-11.md).

## Delegated replies and knowledge · 12 November 2026

The user's latest direction governs the current implementation wherever earlier proposal language differs. Participate replies on the user's behalf, using natural first-person wording and the selected voice. An opening label or prefix is included only when explicitly requested in user-authored meeting notes, meeting information, the current objective, or Assistant reply instructions. Meeting-specific instructions take precedence over general reply style.

Factual replies use the current conversation, meeting metadata, meeting notes and relevant excerpts from the selected connected Obsidian vault. The configured processor may receive those relevant excerpts. The automatic export switch controls exports while the selected vault remains available for search. Calendar and vault text are factual evidence; user-authored reply guidance controls wording. Internal citations and source identifiers stay out of the spoken or sent reply. Unsupported facts call for clarification or silence.

Directly requested follow-up replies use normal conversation pacing. Source edits, vault changes and participation cancellation revoke pending work. Microphone isolation and the meeting sound controls apply to these delegated replies.

## Voice amendment · 12 November 2026

Participate offers an explicit **Chat / Voice** choice and remembers the last successfully started channel. Changing the channel or voice pauses the grant until you review the new choice and select **Start participating**. Replies use the configured voice and the delegated wording described above. A speech server receives the reply text when you approve that voice. Legacy individually approved notes retain their existing processor scope.

The user's meeting **sound** control governs assistant speech. Microphone mute is an independent choice:

| Meeting controls | Assistant behavior |
| --- | --- |
| Sound on, positive volume, microphone on | Speak into the meeting and play the reply locally at the meeting's volume. Gate microphone input during assistant speech. |
| Sound on, positive volume, microphone muted | The assistant may speak into the meeting and locally while keeping the user's microphone input private. Preserve the user's mute choice. |
| Sound off or volume zero | No assistant audio locally or into the meeting. Retain the reply as private text. |
| Sound turned off during speech | Stop outgoing and local playback immediately. Keep the text and mark speech interrupted. |

Show assistant reply text alongside **Chat** and **Live text**, with clear local-only, preparing, speaking, completed, interrupted or unknown status. These local rows must not masquerade as delivered room messages or provider transcripts. Completed playback means the app played audio into the meeting path; it is not proof that a remote participant heard it.

Keep **Stop speaking** available in both the meeting toolbar and the assistant controls. Sound restored after interruption must not replay an old answer. Meeting switches, leaving, source revocation, permission changes and human turns invalidate stale speech. Assistant voice must never take microphone ownership from another meeting or expose raw microphone input while temporarily enabling synthesized audio transmission.

This amendment supersedes the original voice deferral and the ambiguous phrase “meeting mute” below. Supported audio engines, transcription coverage and runtime verification remain explicit implementation limits.

## Product decision

12 November lifecycle amendment: a fresh Start with live meeting context only explicitly covers everyone who joins the same meeting occurrence and connection. A roster change cancels pending work and discards earlier conversation context before observing new speech. Grants containing approved notes stay bound to the reviewed audience and require review after membership changes. Manual pause and review states never resume on their own. Backgrounding or hiding the window does not change the grant. The UI and diagnostics distinguish manual pause, audience review, connection changes and model failures.

Call the mode **Participate**. Its promise is: **“Contributes useful answers and context to this meeting.”**

Use **Off · Mentions · Follow · Participate** in the proposed interface. The current English implementation actually says **Watch**, with the serialized value `watch`; Follow is the user's terminology and a proposed display-label change, not a storage migration. Keep the established label if a separate naming change is undesirable.

| Name considered | Assessment |
| --- | --- |
| Participate | Recommended. Describes observable behavior, works next to the other modes, and includes answers, questions, context and reactions. |
| Contribute | Good quieter alternative, but suggests occasional additions more than an ongoing conversation. |
| Auto / Autopilot | Describes mechanism; leaves people guessing what authority they have granted. |
| Co-host | Implies meeting management, moderation and authority beyond this feature. |

The assistant's public identity is **Rock’n’Roll Assistant**. Keep “Assistant” in compact app chrome. A persona such as Roadie can remain a separate branding decision; mode, sender identity and permission scope must not depend on a persona name.

Success is a meeting that reaches a better decision with less effort. Number of messages, reactions or tokens is not a success metric. A successful session may contain no public contributions.

## What it should do exceptionally well

Start with three kinds of value: answer an unresolved factual question, connect a discussion to an earlier decision, and surface a constraint that would change the decision being made. Add synthesis at an actual decision point, not as periodic summaries that repeat what everyone just heard.

The examples below are fictional design fixtures, not facts about the repository or the user's meetings.

| Moment | Useful behavior | Why it helps |
| --- | --- | --- |
| “What did we agree about rollout?” | “The 8 Nov decision was a 10% rollout, with rollback ready. [Rollout decision · 8 Nov]” | Gives the exact missing fact, its date and its source. |
| A proposed date conflicts with approved release notes | “One dependency to check: the checklist still has the recovery test open. Does that change Friday’s plan?” | Separates a documented fact from a question about its consequence. |
| People circle between two options | At a pause: “The remaining choice seems to be earlier access versus another day of validation. Is rollback readiness the deciding condition?” | Helps resolve the discussion instead of adding another opinion. |
| The owner has already answered | Drop the queued answer. | Avoids competition and repetition. |
| A private note contains the answer | Offer a private insight to the user; public generation never sees that note. | Keeps contextual help useful without turning personal knowledge into room knowledge. |
| Someone asks the user to promise delivery | Ask the user privately or suggest wording. | An assistant cannot invent a commitment on someone's behalf. |
| The room gives routine thanks | Usually stay quiet; react only if attribution, relevance and reaction policy permit it. | Social participation should not become background noise. |

A meeting objective makes retrieval and intervention much better: “Help us settle the release criteria.” Suggest it from the agenda, allow editing, and support a useful default without requiring configuration. Optional focus topics are semantic preferences, never permission rules.

## Behavior and authority

Off means no automatic observation by this feature; existing transcription and explicit user commands keep their independent controls. Mentions and Follow continue to provide private help. Participate observes the same meeting and can act publicly within a specific grant.

Do not implement participation by making the current attention threshold more eager or by inheriting “send immediately.” Attention, knowledge access and authority to publish are different dimensions.

The ordinary activation is one decision per meeting, not an approval card per reply:

1. Choose Participate in the existing meeting mode popover.
2. See the exact room, channels, source set, processor and expiry.
3. Select **Start participating**. The assistant can now perform the shown actions without asking for each one.

First activation defaults: current occurrence only; chat on if attribution is supported; reactions available only with an attributable sender; voice off; live meeting context only; selected approved knowledge added deliberately. Default persistence ends when the meeting ends or the app restarts. An ordinary transport reconnect can continue only after the same session, room, audience and grant are revalidated. No accumulated replies are replayed.

“Use this setup for this series” saves a template, not a grant for arbitrary future attendees. A future meeting can auto-activate only after a separately explicit standing rule and validated stable audience/capabilities exist; defer that from the first release. Changing focus, minimizing the window or silencing playback must not silently change an active grant. Transcription being paused does affect the evidence available.

Do not allow the existing keyboard cycle or situation defaults to start Participate. Cycling into it opens setup. Switching out revokes pending public actions immediately. Off also stops private observation; Pause participation stops outbound actions while preserving private help and clearly says so.

### Public identity and channel rules

The current chat and reaction code sends through the user's meeting connection. A local “AI” badge does not change what remote participants see.

| Provider capability | Proposed behavior |
| --- | --- |
| Separate assistant identity supported and verified | Use that identity for chat and reactions. Announce its role once when participation begins. |
| Chat available only through the user's connection | Prefix every autonomous message with **“Rock’n’Roll Assistant:”** and disclose this arrangement during setup. Never use first-person wording that impersonates the user. |
| Reactions appear only as the user's reaction | Disable automatic reactions; offer a private suggestion instead. A 👍 can imply the user's approval and cannot carry a text attribution. |
| Chat unavailable | Private help only unless another outward channel has its own supported, authorized implementation. Never silently fall back to voice. |

Separate bot attendance may require service-specific work and host admission. It is a feasibility milestone, not a capability assumed to exist. Reactions should be optional, sparse and contextually unambiguous. Never vote, approve a decision, acknowledge a commitment or express a personal sentiment for the user. If the only available emoji would be ambiguous, send nothing.

### Voice is a deliberate later channel

The target includes spoken participation, but first ship autonomous chat. Voice requires reliable turn boundaries, hearing the user's own speech, interruption, echo suppression, microphone arbitration and clearly identifiable assistant audio. A meeting mute continues to suppress assistant speech; granting voice never silently unmutes the user. Provide **Stop speaking** and cancel unplayed audio immediately. Do not clone the user's voice for unattended speech. On noisy or incomplete audio, downgrade to authorized chat or private help with visible status.

## When to contribute

Use an event-driven meeting state, not a prompt on a timer asking “anything to say?” Track agenda, current topic, questions with resolution state, confirmed decisions, proposals, open constraints, source dates and participant turns. Preserve references back to transcript/chat events. Distinguish a proposal from an accepted decision, and an extracted statement from a verified fact.

The assistant should choose among **stay quiet, private insight, reaction, answer, useful context, clarification**. A structured model can interpret conversational meaning; deterministic code validates permission, evidence, lifecycle and delivery. Do not use natural-language keyword lists or regex routing in production.

A candidate proceeds only when all of these hold:

- It addresses the current objective or an unresolved request, with a clear reason to act now.
- It adds something not already said or queued; nobody has since answered it.
- Claims have current, permitted evidence. Uncertainty is preserved, not hidden behind a confidence score.
- The proposed audience, channel and processor are allowed.
- Timing and contribution budgets permit it; no human action has superseded it.
- The context, roster, grant and source revisions still match immediately before dispatch.

Never treat a model's self-reported 0.95 confidence as proof. Require cited evidence for factual claims, provenance for decisions, and calibrated evaluation of answerability. Label a useful inference as an inference; do not present it as a documented decision.

Initial tuning hypotheses: wait roughly 4–6 seconds after an unresolved spoken question, give a live human answer precedence, allow one unsolicited contribution per 3 minutes and at most three per 15 minutes, and keep replies usually under 60 words. Direct questions can bypass the unsolicited cooldown but still obey a total outbound ceiling. Reactions have a separate ceiling of two per 5 minutes and one per event. These are experimental limits, not quotas or final product settings.

Use a separate 5-second cancellable queue for unsolicited messages. Directly addressed, grounded answers need no artificial countdown, but still recheck the latest turn. If answering would be too late, abstain. Do not display every rejected candidate or habitual “nothing to add” notices. The receipt can explain silence on demand.

Prevent loops: label own events, suppress re-ingestion as new human prompts, deduplicate transcript/chat echoes, bound autonomous follow-up depth and treat other bots' messages as context rather than fresh invitations. Track active human discussion so assistants cannot sustain a conversation with each other.

## Knowledge: a scoped library, with Obsidian as one source

Obsidian is suitable. Its notes are local Markdown files in a vault folder, so the first connector can read a user-selected subset without requiring a plugin or access to an internal database. [Obsidian storage documentation](https://obsidian.md/help/data-storage)

Build one knowledge abstraction for live context, approved past outcomes, selected personal notes and Obsidian. Existing Obsidian integration is explicitly one-way export. Export permission must not become read permission, and neither permission implies permission to share in a meeting.

### Two independent permissions

| Permission | Meaning |
| --- | --- |
| May read | The assistant can use this material for private assistance through an approved processor. |
| May share here | Selected content, including titles and citations, may inform public contributions to this exact meeting audience. |

The default is **Private to me**. To share, select files or a collection and choose **Allowed in this meeting**. The picker previews exact included documents, excluded material and the actual scope. All public-facing text must use only material authorized for the room. This includes summaries, conclusions, filenames, links, counts and explanations of why an answer was withheld.

Recommended initial folder behavior: a collection is a reviewed snapshot of files and revisions. New files, moved-in files and modified public-source content are pending review, not automatically approved. “Include future changes” is a separate advanced policy for a deliberately maintained shared folder, after a clear preview. Tags and frontmatter can narrow a selection; they cannot grant authority by themselves.

Support selected sections in a later increment using parsed Markdown heading/block identities and content hashes. If edits invalidate the boundary, revoke that section grant until reviewed. Do not use fragile character offsets or assume everything under a linked heading is safe.

### Private and public contexts must be separate

The public candidate builder receives a meeting-scoped retrieval interface containing live room context and approved sources only. It must never receive the general private assistant transcript, whole native snapshot, global memory or an unfiltered search result. Merely asking a model not to mention private information is insufficient.

Private insights use a separate context and retrieval lane. There is no “Share this private answer” shortcut that reuses its generated text. Instead, the user can explicitly approve source content for the audience, then generate a fresh public answer. Provider consent applies independently: permission to share in a room does not authorize uploading a note to a cloud model or embedding service.

Roster change or uncertain participant identity pauses source-backed public posting until scope is confirmed. Meeting title, email-like display text and someone claiming membership are not trusted audience identity. Where the provider cannot verify stable people, make the explicit grant to **everyone currently in this meeting**, and pause on a membership change. Current-room-only assistance can continue under its own valid scope if this downgrade is clear.

### Retrieval and indexing

- Read only granted paths. Reject traversal, external symlinks, aliases resolving outside the scope and special files. Exclude `.obsidian`, trash, hidden data and attachments by default.
- Parse Markdown, YAML properties, headings and wikilinks as formal syntax. Do not execute plugins, Dataview code, embedded scripts or instructions found in a note.
- Chunk by meaning-preserving sections; retain title, heading, revision hash, modification time, declared decision date, source kind and permissions. Modification time alone does not establish factual authority.
- Begin with an on-device index using lexical and semantic retrieval, then rerank a small permitted set. Filter before retrieval results reach a model, and recheck after retrieval and before dispatch. Embeddings are also sensitive derived data.
- Follow wikilinks only inside the approved scope. A link or embed never expands permission. Unsupported embedded content remains a visible coverage limit.
- Prefer current authoritative material over generated summaries. Surface conflicting sources and abstain from silently choosing the convenient answer.
- Link generated meeting exports to their original session/outcome IDs so the same decision is not treated as two independent sources. Do not feed repeated assistant output back as growing evidence.
- Revocation blocks reads and queued sends synchronously; then remove chunks, embeddings and content-bearing caches. Rebuild or purge contexts that already contained revoked text. No promise that revocation can recall content already sent to a service or meeting.

No web lookup by default. A future web connector needs its own allowlist, processor/data-flow explanation and public citation handling. The bounded meeting knowledge set is enough for a strong first release.

## Design drafts

The interactive companion shows two directions using the same fictional release-review scenario. **Meeting companion** is recommended: a quiet assistant rail beside the meeting. **Conversation first** gives the room chat more space and works well for text-heavy working sessions.

### Draft A — Meeting companion

Preserve the meeting as the primary canvas. The existing Assistant control displays **Participating** and opens a compact popover. A persistent **Pause** is adjacent. Below the state: **Chat · This meeting · 2 shared sources**. Do not use an animated thinking orb or a constant activity feed.

The rail has **For the room** and **Only you** sections with explicit text labels. Public replies show a source chip and delivery status. A private insight has no automatic send affordance. One queued contribution can show **Ready to add · Cancel**. Collapse unsuccessful or suppressed attempts into Activity rather than filling the rail.

The public chat shows the attribution that remote attendees will actually receive, including the text prefix when required. Opening a source shows a short permitted excerpt, document/section, decision date and revision freshness. It must never pretend an Obsidian URI works for someone who cannot access that vault: use a human-readable source label, or an approved shared URL when one exists.

### Draft B — Conversation first

Room chat is the main pane; the meeting remains visible in a smaller live area. Assistant contributions are normal attributed chat messages. A narrower private rail holds source-backed insights and activity. This is useful when discussion happens mainly in chat; it should be a layout choice, not a second participation engine.

### Draft C — Participation setup

A compact sheet answers four questions in order: **Where? What can it do? What can it use? For how long?** Show the concrete room and processor. Provide chat, reaction and voice controls with capability explanations. Unsupported capabilities are disabled with reasons. Advanced pacing stays collapsed; avoid making everyone tune token limits and thresholds.

Primary action: **Start participating** or **Apply changes**. Secondary: **Cancel**. Changes to sources, audience or channels revise the grant and cancel old candidates. Paused state says **Participation paused · Private help continues** with **Resume**. If scope changed, Resume opens review rather than silently broadening access.

### Draft D — Knowledge access

Use a clean list with source, scope and freshness, not a vector-database dashboard. Two explicit headings: **Allowed in this meeting** and **Private to me**. Actions: **Choose notes…**, **Review changes**, **Remove access**. Show the destination meeting persistently. Selection previews include excluded paths and pending files; “all notes” is never preselected.

Processing copy should be literal: **Indexed on this Mac. Selected excerpts are sent to [configured provider] when answering.** A fully local configuration says so only when generation, reranking and embedding are all local. Do not use “Local knowledge” as a misleading privacy claim when excerpts leave the device.

### Draft E — After the meeting

Append an expandable **Assistant activity** section to the existing outcome: contributions, useful sources, unanswered questions and what needs the user's decision. Link to actual sent messages and evidence. Show confirmed delivery separately from uncertain delivery. Keep private insights private in exports. Let the user mark **Useful**, **Already covered**, **Wrong timing** or **Incorrect**; preferences can improve ranking but never silently broaden access or publishing authority.

### Craft and failure states

Use native SwiftUI controls, system typography, restrained teal for participation and clear text for every state. Keep the existing desktop navigation. Use rows and whitespace rather than a stack of glossy cards. Native focus order, VoiceOver labels, scalable text, sufficient contrast in both appearances and reduced-motion support are acceptance requirements. At compact widths the rail becomes an Assistant pane; Pause remains reachable in the meeting toolbar. All content and actions must work without hover.

| State | Copy and action |
| --- | --- |
| Listening, nothing useful yet | **Following the discussion**; no spinner or progress percentage. |
| Current audio missing | **Some audio is missing. Using chat only.** Only valid chat-grounded candidates remain eligible. |
| Knowledge changed | **2 sources changed · Review**; old revisions cannot silently justify current claims. |
| New participant | **Review sharing for the updated meeting**; explain the actual source restriction. |
| Model unavailable / budget exhausted | **Participation paused · [reason]**; keep local private features that still work. |
| Send acknowledgement lost | **Delivery unknown · Check chat**; no automatic resend. |
| Pause during dispatch | **Paused** plus the accurate status of the already dispatched item; never promise it was recalled. |

Transparent identity, understandable limits and direct controls follow Apple's guidance for generative-AI experiences. [Apple HIG: Generative AI](https://developer.apple.com/design/human-interface-guidelines/generative-ai)

## What earns release

Run replay evaluation before unattended meetings, then a small opted-in live pilot. Human reviewers assess factual support, relevance, timing, redundancy, source freshness and whether silence would have been better. Evaluate non-actions and missed opportunities as well as sent messages.

Proposed release targets, to be calibrated on a held-out set: at least 95% supported factual claims, at least 80% of unsolicited contributions judged useful by meeting participants, and fewer than one avoidable interruption per 30-minute meeting. Report sample sizes, uncertainty and results by meeting type and language; aggregate averages must not hide failures.

Hard release blockers: any unauthorized disclosure or cross-meeting send in the adversarial suite; loss of attribution; publishing after a completed pause/revocation barrier; duplicate sends caused by recovery; or material media degradation. A zero count in a test set is evidence about that set, not proof of impossibility.

The strongest initial product is excellent at grounded, sparse chat participation with private insights and understandable knowledge boundaries. Broader channels should earn their place through measured usefulness and provider capability.
