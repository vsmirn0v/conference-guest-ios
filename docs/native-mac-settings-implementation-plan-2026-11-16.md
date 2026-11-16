# Native Mac settings implementation plan

Implement the selected **Direct sections** design: search individual settings, use a consistent native settings layout, and expose assistant destinations directly in the sidebar. This covers the native Mac app and its English and Russian interfaces.

Planning baseline: `9ae51735`. This document records the original implementation plan. The interactive design is a visual reference, not a specification of new defaults or engine behavior. Subsequent implementation and validation are recorded separately.

## Scope and invariants

Preserve all existing controls, preference keys, stored values, provider configurations, model selections, credentials, permission checks, and media ownership rules. Reorganizing controls must not change their behavior or automatically enable a feature. No data migration is expected; routing state changes are separate from preferences.

Opening settings, searching, revealing a row, or changing pages must not start capture, record audio, publish media, download models, contact providers, or change update preferences. Continue any existing lifecycle cleanup when leaving a private check. A search index must not construct every settings view or initialize its services.

The browser draft simplifies several areas. Preserve the real memory editor, suggestions, retention choices, export and deletion flows; do not introduce its illustrative “remember context” toggle. Preserve actual readiness modes, model states, supported voice engines and channel restrictions instead of copying sample options or values. Never infer “up to date” or “ready” from a missing error.

## Navigation and ownership

| Sidebar group | Destination | Owned settings |
|---|---|---|
| Meetings | General | Identity, invitation origin, sync, setup and connection options |
| Meetings | Calendars | Calendar selection and automatic joining |
| Meetings | Reminders | Reminder timing, details, sound and notification access |
| Meetings | Camera & audio | Devices, private checks, audio processing, readiness and headset controls |
| Assistant | Meeting alerts | Enablement, battery policy, situation defaults, profile and meeting instructions |
| Assistant | Transcription | Local transcription, microphone inclusion, meeting types, recognition models and detector status |
| Assistant | Replies & actions | Reply drafting, writing style, outcomes, agent tools and send confirmations |
| Assistant | Voice & speaking | Push to talk, headphone answers, speaking voice, saved recording and voice model preparation |
| Assistant | AI providers | Alert, writing and second-opinion providers; endpoints, models, credentials and connection tests |
| Assistant | Memory & privacy | Existing memory management, retention and actual data destinations |
| Connections | Integrations | Existing Obsidian integration and layout settings |
| Connections | MCP server | Existing local server configuration and status |
| App | Updates | Installed version, real updater status, automatic updates and channel |

Move the headset-button control and experimental microphone warm-up control from General to Camera & audio. Keep each distinct microphone readiness/warm-up preference distinct, with its existing explanation; similar names do not imply interchangeable behavior.

Move outcome settings from Attention to Replies & actions, including remote-outcome consent. Preserve the existing conditions: local outcomes can run with alerts off; remote outcomes require alerts and consent. Move writer-provider editing from Replies to AI providers; keep a contextual link and effective-provider summary beside drafting/outcome controls. Transcription and Voice own their model downloads; AI providers links to those owners rather than presenting duplicate editors. Feature pages continue to expose relevant readiness failures.

Remove the assistant section picker and overview as required navigation steps. Existing generic Assistant entry points open Meeting alerts; specific Voice, Transcription and other entry points retain their exact destinations.

## Architecture

Add focused types under `NativeMacGuest/Settings/`; names below are proposed, not existing APIs:

- `SettingsDestination`: a typed page identity replacing integer tabs plus a separate assistant area as the long-term navigation contract.
- `SettingID`: stable, nonlocalized identity for a control or action.
- `SettingsRoute`: destination, optional setting ID, and a request token for repeated reveal requests.
- `SettingDescriptor`: title and explanation localization keys, owning destination, containing section/disclosures, availability metadata and an optional safe value-summary identifier.
- `SettingsCatalog`: descriptors shared by navigation/search and row identification. Feature views retain typed bindings and actions to their existing stores.
- `SettingsSearchIndex`: pure in-memory matching/ranking over descriptor metadata.
- `SettingsRevealCoordinator`: activate the destination, expand its disclosure ancestors, wait for layout, scroll, focus and briefly highlight the target.
- `SettingsPage` and small row/section helpers: consistent native layout and accessibility identifiers without becoming a generic form engine.

The catalog must have no capture, network, keychain or disk side effects. Resolve current-value summaries only for visible results using already-owned state. Never index credentials, user-entered endpoints, names, transcripts, memory contents or other private field values. Mask credential state as “Configured” or “Not configured”. Device names may appear as result values but are not search-index content.

Before splitting views, inventory every existing control and action, recording its owner, preference binding, availability and target ID. This includes nested voice preparation, memory, Obsidian, MCP and provider settings. Each static configurable item needs a searchable route. Dynamic records such as individual memories and instructions are not settings-search documents; index their management entry point.

## Search contract

1. Rename the field to “Search all settings”. Keep the sidebar stable; show results in the detail pane.
2. Build searchable text from localized labels, explanations and breadcrumbs, with canonical English labels also available. Use Unicode normalization, locale-aware case/diacritic folding and token matching. Rank exact title matches first, then title-prefix/token matches, then descriptions and paths. Do not introduce hand-maintained synonym, intent or phrase lists. Fuzzy/semantic search is deferred.
3. Return one result per setting with its title, breadcrumb, safe current value and any disabled-state explanation. Resolve conditional availability through existing capability/state checks.
4. Hide build-unsupported destinations, such as Updates when direct updates are not compiled. Keep temporarily disabled settings discoverable and explain their prerequisites. Do not enable a feature to reveal its setting.
5. For a conditional control that is not mounted, open its owning section and explain the required selection or prerequisite. Do not silently change a provider/engine to make the control appear.
6. Selection opens the correct destination, expands its disclosure ancestors, scrolls to the row, focuses the control when possible, and highlights it without changing the value. Disabled controls receive an accessible row-level announcement.
7. Retain the query and previous destination in transient navigation state. Clear the field when opening a result, with a Back to results action restoring the query and selection. Escape exits search and returns to the previous page; the clear button has the same result. Never persist search text to disk.
8. Support keyboard traversal, Enter to open and focus restoration. Use Command-F only while settings owns focus; retain the app’s existing settings and meeting shortcuts.

## Layout and feature details

Use native SwiftUI/AppKit controls, system typography, semantic colors and SF Symbols. Match the draft’s hierarchy rather than reproducing its HTML styles. Start with a roughly 210–240 point sidebar, 24–32 point detail inset, and a 680–720 point maximum form width. These are implementation starting points, not rigid widths.

Anchor page headers and content to the top. Use one scroll owner per detail page; avoid nested scrolling forms and unbounded spacers in individual rows. Align labels and controls consistently. Let rows grow for Russian text, accessibility and errors; align help text under its owning label. At constrained widths, stack labels above controls and replace the sidebar with a labeled destination picker. Preserve selection, search, disclosure and focus state during resizing. Base the transition on available space and verify the actual supported native window minimum.

**Camera and audio:** give private checks a visible but bounded area. Opening the page leaves devices off. Keep the Mac system-route explanation visible because selection affects system audio routing. Keep privacy descriptions beside the relevant action instead of at the far edge. Distinguish an inactive camera, a private preview and an already-live meeting track; “Only you” must not describe a track already being shared. Keep microphone tests consistent with the current mute state and existing ownership callbacks. Report permission denial, removed devices and start/stop failures in place.

`NativeDesktopDeviceSettings` also appears in the in-meeting Studio panel. Reuse its device sections and model, with explicit page versus panel presentation. The full-page header and sidebar spacing must not leak into the panel. Preserve all cleanup, borrowed-track and live-audio-check behavior.

**Voice:** organize around Talk to Assistant, Hear answers privately, Speaking voice, and model preparation/storage. Preserve headphone approval, push-to-talk warnings, all supported engines, recording replacement confirmation, preparation/download progress, repair, GPU fallback and generation guards. Show diagnostics only when relevant; never conceal a blocking failure under a collapsed disclosure.

**AI providers:** label roles by task rather than Judge/Write/Listen. Show effective provider/model and local versus external processing for each role. Keep provider selection and task-related data destinations visible; reveal endpoint, credential and advanced escalation controls as needed. Reuse actual provider capabilities, keychain methods and validation.

**Updates:** place installed version, actual check/install state and Check for updates above preferences. Use existing Sparkle and `NativeDesktopUpdates` state; add a small typed presentation adapter only where necessary, not a second updater or polling loop. Show a last-checked time only when supplied by a reliable event/API. Preserve `channelLocked`, recovery requirements, newer-than-downloaded handling, busy-meeting deferral and media-cleanup admission gates. Keep Sparkle responsible for its existing installation flow. A stable/beta picker must call the existing channel setter and explain that stable does not downgrade the installed build. Hide unsupported actions and provide reasons for temporarily unavailable ones.

## Delivery sequence

| Step | Change and primary files | Completion evidence |
|---|---|---|
| 1 | Inventory current settings and add typed IDs, descriptors and routes under `Settings/`. Audit `DesktopHomeView.swift`, `DesktopWorkspace.swift` and all existing entry points. | Complete inventory; unique IDs; every supported route has an owner; no side effects from catalog creation. |
| 2 | Extract the shell from `DesktopHomeView.swift`; add the direct sidebar, bounded page layout and compact destination picker. Adapt existing routes before removing old tab/assistant bindings. | Existing home/menu/calendar/device/voice links open the intended page; resizing retains navigation state. |
| 3 | Split `Attention/AttentionViews.swift` settings into focused feature views. Apply ownership moves while preserving bindings and lifecycle hooks. Reuse `TranscriptionSettingsView.swift`, `VoiceCloneViews.swift` and `AssistantMemoryViews.swift`. | All former controls remain reachable; no preference/default changes; visible privacy and prerequisite explanations reflect actual state. |
| 4 | Refactor `DesktopDeviceSettings.swift` for full-page and Studio presentation. Restyle `Updates/NativeDesktopUpdates.swift` through existing updater state. Bring remaining settings pages into the common shell. | Native camera/audio and Updates layouts pass visual checks; Studio remains usable; updater safeguards unchanged. |
| 5 | Implement catalog-backed search, result presentation and reveal/focus behavior across all destination owners. | Exact-setting, advanced, disabled, conditional, repeated-navigation and no-result scenarios pass. |
| 6 | Complete English/Russian copy, accessibility, native acceptance tests and final regression checks. Remove superseded search/picker code and migration adapters. | Acceptance matrix passes with evidence tied to the implemented commit. |

Keep each step reviewable and buildable. Use the existing branch unless instructed otherwise; preserve concurrent work. No push, merge, release or installation is part of this plan.

## Validation and acceptance

Use the existing `RockNRollNativeGuest` scheme and `NativeDesktopTests` target in `NativeMacGuest/project.yml`. New files must be included through the generated-project workflow. The current source path includes the new Settings directory automatically; verify exclusions and both direct-update build configurations. Use the documented `NativeMacGuest/build.py --compile-only` flow for compilation and the repository’s matching XCTest build/run configuration for native tests.

Extend existing meaningful coverage in `Tests/Parity/UpdateAdmissionTests.swift` and `AssistantUIAcceptanceTests.swift`; replace assertions about the removed overview/picker with actual route and control behavior. Retain updater safety/admission and media lifecycle tests. Add focused search/reveal tests rather than source-text or styling assertions.

| Area | Required acceptance |
|---|---|
| Catalog | Unique setting IDs; inventory coverage; every available target resolves; unsupported build destinations absent; construction and queries cause no capture/provider/download calls. |
| Search | English and Russian labels; canonical English queries in Russian UI; whitespace/case/diacritics; exact-title ranking; empty/no results; no private values indexed. |
| Reveal | Microphone, microphone readiness, voice recording, provider credentials, update channel and memory retention; disclosure expansion; keyboard focus; disabled/conditional targets; Back to results; repeated same-target requests. |
| State preservation | Changing page, searching and resizing leave preferences untouched; explicit edits persist across restart; existing deep links reach the same functional settings. |
| Layout | Actual native minimum width, 760-point window, typical laptop and wide window; short window scrolling; English/Russian; light/dark; enlarged text; long device/provider names; progress, warnings and errors. No clipping or excessive blank space above content. |
| Accessibility | VoiceOver reading order and labels, selected sidebar state, result announcements, keyboard navigation, focus restoration and Reduce Motion. Search highlight never becomes the only indication of the destination. |
| Camera and audio | Idle, private preview and live-camera states; denied permissions; device changes; explicit test start/stop; navigate away during startup; microphone mute and shared-track ownership remain correct. Test both Settings and Studio. |
| Assistant | Alert/outcome dependencies, remote consent, local/external providers, stored-key status, supported voice engines, headphone approval, saved voice, download/repair/fallback states, existing memory review and retention flows. |
| Updates | Direct and non-direct builds; check unavailable/failure/success; available/downloaded update; channel lock; active-meeting deferral; failed cleanup; recovery target. No false “up to date” state or bypass of installation admission. |

Update app-owned copy in `RockNRoll/en.lproj/Localizable.strings` and `ru.lproj/Localizable.strings`, which the native project includes. Use `L(...)` consistently, including Updates. Avoid changing shared iOS labels merely to rename the Mac navigation; introduce distinct keys where needed.

The task is complete when all supported settings have an individual search route or an explicit management-entry route, the selected direct navigation replaces the nested picker, native layouts pass the matrix, and existing media/update/provider protections remain intact. Record native screenshots and test results for the exact implementation commit. Browser-draft checks do not satisfy native acceptance.

## Design reference

Selected variant: **Direct sections**. The alternative Assistant hub is not part of implementation scope.

Interactive draft in this chat: `/Users/v.smirnov/.codex/visualizations/2026/11/16/01a1e45b-0750-7c52-935a-bdc48eda0e44/settings-designs.html`.

Primary current owners: `NativeMacGuest/DesktopHomeView.swift`, `DesktopWorkspace.swift`, `DesktopDeviceSettings.swift`, `Attention/AttentionViews.swift`, `Attention/TranscriptionSettingsView.swift`, `Attention/VoiceCloneViews.swift`, `Attention/AssistantMemoryViews.swift`, and `Updates/NativeDesktopUpdates.swift`.
