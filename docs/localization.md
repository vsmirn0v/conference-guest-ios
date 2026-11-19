# App localization

Rock’n’Roll follows the app language selected in macOS or iOS. The app includes English,
Russian, Spanish, Arabic, Hindi, French, German, Simplified Chinese (Mandarin) and
Indonesian. English is the development-language fallback. The direct Mac builds also
include translated donation options in all nine app languages. Providers control the
languages available on their own checkout screens.

Own interface copy includes joining, saved rooms, profile/settings, chat and
transcript controls, missed sections, participants, video modes, sharing previews,
PiP microphone status, continuation, sync, errors, keyboard shortcuts and
accessibility labels. Permission explanations and extension display names are
localized for all nine supported languages. Meeting names, aliases, names entered by users,
invitations, messages and transcripts remain verbatim. External pages and
provider-supplied content retain their own language.

## Adding or changing copy

- Use `L("English source key")` for app and guest broadcast copy. Shared
  `Localization.swift` resolves the current process's main bundle. ConferenceCore
  errors use `CoreL` with its package resource bundle.
- Add matching entries for all nine app languages. Preserve identifiers,
  protocol fields, enum raw values or stored user data. Local screen-source enums
  keep their raw values and expose a separate localized presentation title.
- Pass strings as `%@` arguments and integers as `%ld`. User content must be a
  format argument rather than part of a format string.
- Use `Localizable.stringsdict` for participant, musician, unread-message,
  missed-section, recent-room and over-limit character counts. Russian needs
  one/few/many/other forms. Arabic also has zero and two forms, while Chinese and Indonesian use other. Formatters use the app language for grammar and
  preserve the device's region for formatting.
- Visible call/preview captions are short. VoiceOver retains full action labels.
  Accessibility identifiers stay stable across languages.
- Regenerate the project with XcodeGen when adding localization resources.

## Validation

`NativeInterfaceLocalizationTests` reads the installed Mac app bundle, compares every
language’s complete key set, checks printf argument positions and types, and verifies
permission prompts and interpolation with mixed-script names. ConferenceCore tests check
the localized package errors, language-to-prompt mapping and preservation of the Chinese
script with a different device region.

The checks below record earlier English and Russian qualification runs.

Resource tests check English/Russian key and argument parity, integer plural
forms (including 0, 11, 21, 22 and 111), mixed-language names, fallback strings,
permissions and embedded broadcast resources. Simulator UI tests force Russian
with a US region, check rotation, chat/transcript content and preview actions,
then relaunch in English. This exercises app-language selection independently
of regional settings without changing the Simulator's global language.

- 39 ConferenceCore tests passed.
- iOS 27: 93 app tests and eight selected UI tests passed; one opt-in live-cloud
  case skipped. English regressions include conversation/call rotation, sharing
  preview and continuation. Results: `/tmp/rock-russian-final27.xcresult`.
- iOS 17.5 / iPhone SE: five resource tests and four Russian UI tests passed before
  the final short preview-caption change. The final preview check passed
  separately in `/tmp/rock-russian-preview17.xcresult`.
- iOS 17.5 / iPad mini: all four Russian UI tests passed. The final narrow
  conversation-toolbar check and English sharing-preview regression passed
  separately in `/tmp/rock-russian-ipad-label-final.xcresult`.
- Final iOS 27 resource tests and Russian sharing-preview check passed in
  `/tmp/rock-russian-final-resources27.xcresult`.
- Release device build passed without signing. English/Russian app, core and
  extension resources were verified in the built bundle. Minimum iOS remains
  16.0; the existing published version/build was not changed.

Screenshots are retained in `/tmp/rock-russian-screenshots27` and
`/tmp/rock-russian-screenshots17`. No physical device, media stack, hosted service
or TestFlight distribution was changed for this task.
