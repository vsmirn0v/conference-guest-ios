# App localization

Rock’n’Roll supports English and Russian through the standard iOS app-language
preference. Without an override it follows the preferred supported device
language; English is the development-language fallback. No account, server request
or in-app language setting is required. The existing guest SDK already includes
English and Russian resources.

Own interface copy includes joining, saved rooms, profile/settings, chat and
transcript controls, missed sections, participants, video modes, sharing previews,
PiP microphone status, continuation, sync, errors, keyboard shortcuts and
accessibility labels. Permission explanations and both broadcast extension names
also have Russian resources. Meeting names, aliases, names entered by users,
invitations, messages and transcripts remain verbatim. External pages and
provider-supplied content retain their own language.

## Adding or changing copy

- Use `L("English source key")` for app and guest broadcast copy. Shared
  `Localization.swift` resolves the current process's main bundle. ConferenceCore
  errors use `CoreL` with its package resource bundle.
- Add matching entries in `en.lproj` and `ru.lproj`; do not translate identifiers,
  protocol fields, enum raw values or stored user data. Local screen-source enums
  keep their raw values and expose a separate localized presentation title.
- Pass strings as `%@` arguments and integers as `%ld`. User content must be a
  format argument rather than part of a format string.
- Use `Localizable.stringsdict` for participant, musician, unread-message,
  missed-section, recent-room and over-limit character counts. Russian needs
  one/few/many/other variants. Formatters use the app language for grammar and
  preserve the device's region for formatting.
- Visible call/preview captions are short. VoiceOver retains full action labels.
  Accessibility identifiers stay stable across languages.
- Regenerate the project with XcodeGen when adding localization resources.

## Validation

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
