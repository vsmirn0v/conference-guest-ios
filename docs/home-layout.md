# Home priorities

Home keeps joining and saved rooms within reach without turning the calendar
into the main navigation.

- Show at most two suggestions: fresh activity on another device, then resolved
  timed events that are ongoing or start within ten minutes. Merge a Calendar
  occurrence and Handoff by canonical room identity. Calendar time alone does
  not establish that anyone is in the room.
- Freeze suggestion membership while typing, dragging, scrolling away from the
  top, joining, or using a modal. Cards still check current source/event state
  before acting; stale activity requires the existing join-here confirmation.
- Keep invitation, Paste/Join, the synced name and private Camera & sound check
  in one compact panel. Microphone and camera still start off. An empty name
  focuses the inline field on first join.
- Preview three favorites in the user's existing synced order and two recent
  rooms. Show all preserves direct dragging, renaming, removal and Undo.
- Put later-today events after saved rooms, with two rows initially. The full
  agenda and stale/companion device actions remain in secondary sheets.
- At 820 points and wider, place the saved-room library beside Join and the
  agenda. Smaller windows and accessibility text sizes use one column.

No permissions, sync defaults, conference transports or backend services change.
Tests use synthetic invitations; Calendar details and real room passwords are
not included in the fixture or captures.
