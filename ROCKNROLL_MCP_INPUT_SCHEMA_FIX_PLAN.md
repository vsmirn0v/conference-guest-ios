# Rock'N'Roll MCP — inputSchema fix: implementation plan

Source requirement: `ROCKNROLL_MCP_INPUT_SCHEMA_FIX_SPEC.md` (2026-11-10).
Codebase state: native MCP at `NativeMacGuest/MCP/`, offline profile at `mcp/`, after commit `69317ea`.

## 1. Confirmed defect

`MCPCore.swift` → `MCPJSONRPCServer.handle`, `tools/list` branch publishes the same
placeholder for all 13 native tools:

```swift
"inputSchema": ["type": "object", "properties": [:], "required": []]
```

Handlers in `NativeDesktopMCPBackend.swift` enforce a real contract through shared
`MCPValue` validators, so clients only discover argument names from `INVALID_ARGUMENT`
errors. The offline profile (`mcp/rocknroll_local.py`) already publishes per-tool
properties, but without per-field descriptions, `minLength`, `additionalProperties`
policy, or server-side unknown-field rejection.

## 2. Decisions (agreed at kickoff)

1. **Version:** native `serverInfo` `0.1.0` → `0.2.0`; offline `SERVER_VERSION` bumped likewise.
   `capabilities.tools.listChanged` stays `false` — the catalog is static per launch;
   clients re-read schemas via reconnect + `tools/list`.
2. **Scope of work:** native server **and** offline profile (parity), plus README.
3. **Unknown fields:** `additionalProperties: false` on every tool, enforced server-side,
   **after** the full field inventory (Phase 0). One documented exception:
   `rocknroll_run_assistant` keeps recognizing `conversation_id` in order to reject it
   with `CAPABILITY_UNAVAILABLE` (existing behavior), not with a generic unknown-field error.
4. **Single source of truth (native):** a declarative per-tool schema model generates both
   `tools/list` output and pre-dispatch structural validation. Domain checks (existence,
   state, revision conditionality, idempotent replay) stay in handlers. Contract tests pin
   schema ↔ handler drift.
5. **Permissions unchanged:** read-only clients still see all 13 tools; scope checks happen
   before validation and dispatch, exactly as today. No new tools, filters, transports,
   `outputSchema`, or storage changes.

## 3. Phase 0 — contract inventory (no behavior changes)

Deliverable: a checked-in table `mcp/CONTRACTS.md`, one section per tool, generated from a
manual audit of every handler: field, JSON type, required/optional, default, enum/range,
`null` behavior, semantics, where IDs come from, verification source (file:line).

Already established from the audit so far:

| Tool | Fields read by handler today |
|-|-|
| `rocknroll_status` | none |
| `rocknroll_list_meetings` | `query?`, `kind?`, `from?`, `to?`, `limit` (default 20, max 100), `cursor?` |
| `rocknroll_get_meeting` | `meeting_id` (required) |
| `rocknroll_get_transcript` | `meeting_id` (required) |
| `rocknroll_get_outcome` | `outcome_id` (required) |
| `rocknroll_list_tasks` | `meeting_id?`, `done?`, `owner?`, pagination |
| `rocknroll_search` | `query` (required), `types?` (default meeting/outcome/task/transcript), time range, pagination |
| `rocknroll_get_settings` | `sections?` — **array of strings**, default `["app","attention","meeting"]` |
| `rocknroll_control_meeting` | `action_id`, `meeting_id`, `desired_state` (object; operation keys inside) |
| `rocknroll_set_favorite` | `room_id`, `favorite`, `action_id`, `expected_revision` (required unless replay) |
| `rocknroll_update_task` | `task_id`, `action_id`, `expected_revision` (unless replay), `text?`, `owner?`, `done?` |
| `rocknroll_update_settings` | `action_id`, `expected_revision` (unless replay), `sections` — **object patch** |
| `rocknroll_run_assistant` | `prompt`, `meeting_id?`, `action_id`; `conversation_id` → `CAPABILITY_UNAVAILABLE` |

Phase 0 must additionally resolve:

- **Outcome-ID discovery chain:** confirm `outcome_id` is obtainable from a documented
  response (`rocknroll_search` outcome items and/or meeting records) and write the exact
  source tool + field into the `outcome_id` description. If no chain exists, record a
  separate blocking defect; do **not** alias `meeting_id`.
- **`null` semantics audit:** pin down what each `MCPValue` accessor does with explicit
  `NSNull` vs a missing key, per optional field. Publish `null` support only where the
  handler genuinely accepts it; otherwise reject with `INVALID_ARGUMENT`.
- **Nested DTOs:** enumerate `desired_state` operation keys for `control_meeting`, the
  allowlisted `sections` patch keys per settings area, and `update_task` field rules
  (empty patch behavior). Conditional requirement (`expected_revision` on non-replay) is
  documented in field descriptions and enforced server-side, not via `oneOf`.
- **Offline deltas:** `rocknroll_get_transcript` offline accepts `from`/`to`/pagination
  while native does not — keep per-profile contracts; document the difference.

## 4. Phase 1 — native schema model

Files: `NativeMacGuest/MCP/MCPCore.swift` (model), new `NativeMacGuest/MCP/MCPToolSchemas.swift`.

- Add value types: `MCPToolSchema` (properties, required, additionalProperties = false)
  and `MCPToolProperty` (type, items, enum, minLength, minimum/maximum, default, format,
  description, nested object properties).
- Extend `MCPToolDefinition` with `let schema: MCPToolSchema`; declare all 13 schemas in
  `MCPToolSchemas.swift`, reusing shared fragments (pagination, time range, `action_id`,
  `expected_revision`, `meeting_id`) so list endpoints stay consistent.
- `tools/list` renders the declared schema verbatim, including per-field descriptions that
  state what each ID is and which tool/field supplies it. `annotations` unchanged.
- No secrets, user paths, pairing tokens, or real meeting examples in descriptions.
- Bump `serverInfo.version` to `0.2.0` (native tests asserting `0.1.0` updated).

## 5. Phase 2 — native pre-dispatch validation

File: `MCPCore.swift` (`tools/call` path) + a `MCPSchemaValidator` beside the model.

Order of checks inside `tools/call` (each independently tested):

1. Scope check (unchanged; runs even for structurally invalid calls).
2. Structural validation against the declared schema: arguments must be an object;
   required fields present; declared types exact (no `"true"` → Bool, `"20"` → Int
   coercion); non-empty IDs via `minLength: 1`; enums, numeric bounds, array item types,
   nested `sections`/`desired_state` keys and value types; unknown fields rejected.
   Exception: `run_assistant` + `conversation_id` → `CAPABILITY_UNAVAILABLE`.
3. Handler dispatch (domain errors unchanged: `MEETING_NOT_FOUND`, `REVISION_CONFLICT`,
   `CURSOR_EXPIRED`, conditional `expected_revision`, replay short-circuit).

Error payload: keep `isError: true` + `INVALID_ARGUMENT`, add
`details: {"field": …, "reason": …}` (reason ∈ required/type/unknown_field/enum/range/empty).
Extend `MCPToolFailure` with an optional details object; `MCPValue` validators populate it
so handler-side errors get the same diagnostics. No sensitive values in details.

Validation happens before any action recording or approval prompt, preserving the existing
"refused action leaves no pending record" guarantee.

## 6. Phase 3 — handler alignment (only where the audit shows drift)

- Normalize the audited `null` behavior to match the published schema (reject or accept
  deliberately, per field).
- Document whitespace-only `query` handling as implemented (trim or reject per current
  behavior); `minLength: 1` alone does not reject spaces — assert whichever rule exists.
- Confirm `MCPValue.date` enforces RFC 3339 with a time-zone offset (offline Python already
  does); align if the native parser is more lenient than the published `format: date-time`.
- Keep `default` values descriptive: server behavior on omission must match each default.

## 7. Phase 4 — offline profile parity

Files: `mcp/rocknroll_local.py`, `mcp/tests/test_rocknroll_local.py`.

- Extend `tool_schema()` to emit `additionalProperties: false`, per-field `description`,
  `minLength: 1` for required IDs, and the existing enums/limits; keep offline-only fields.
- Add unknown-field rejection at `tools/call` (same reason codes as native).
- Bump `SERVER_VERSION`; keep `listChanged: false`.
- No native write tools are added offline — the offline profile stays read-only.

## 8. Phase 5 — tests

Native (`NativeMacGuest/Tests/Parity/MCPNativeTests.swift` + new
`MCPSchemaContractTests.swift`, same memory-checker workaround):

- **Catalog:** all 13 tools have non-placeholder schemas; every required field is in
  `properties`; `meeting_id`/`outcome_id`/`query` required where expected; `status` and
  other truly no-argument tools keep empty properties; every property has a description;
  schemas are self-contained (no `$ref`).
- **Drift guard:** for each tool, the set of fields the handler reads (from the Phase 0
  table, encoded as test expectations) equals the published property set; required sets
  match the handlers' unconditional requirements.
- **Parameterized behavior matrix per tool** through the real `MCPJSONRPCServer.handle`:
  minimal valid args; full valid args; each required field omitted; wrong type; `null`;
  empty string; unknown field; unknown enum value; limit bounds (0, 1, 100, 101);
  invalid/zone-less/reversed dates where accepted; nested patch wrong key/type and empty
  patch; valid-but-nonexistent ID → domain error (not success, not INVALID_ARGUMENT).
- **Side-effect safety:** invalid write calls record no action, show no approval, change
  no store state; scope denial still precedes validation; exact replay still replays after
  validation passes.
- Update the two version-sensitive assertions and any transport fixtures.

Offline (`mcp/tests/test_rocknroll_local.py`): mirror the catalog and behavior matrix for
the 7 read tools; doctor stays clean.

## 9. Phase 6 — docs and acceptance

- `mcp/README.md`: argument summary per tool (or link to `mcp/CONTRACTS.md`), version note,
  reconnect instructions (restart app → client reconnect → `tools/list`).
- Sanitized full `tools/list` sample checked in as `mcp/examples/tools-list.native.json`
  (no real meeting data).
- Manual Codex end-to-end checklist executed on test data and reported with results:
  list meetings → pick ID → `get_meeting` → `get_transcript` (missing transcript allowed as
  a described domain case) → discover outcome ID from a documented response → `get_outcome`
  → `search`. Success means Codex uses correct field names with no hints and no error-driven
  discovery. This step is manual and will be reported as such, not inferred from unit tests.
- Short "update & reconnect" note for users.

## 10. Out of scope

New tools/filters/transports, `outputSchema`, storage changes, permission changes for
connected clients, write-scope acquisition for verification, MCP protocol version upgrade,
`listChanged` notifications, renaming any tool or argument.

## 11. Risks and mitigations

| Risk | Mitigation |
|-|-|
| `additionalProperties: false` breaks a supported field | Phase 0 inventory precedes enforcement; drift-guard test covers every handler-read field |
| `conversation_id` starts failing with the wrong error | Explicit exception + dedicated test |
| Conditional `expected_revision` over-declared as required | Only unconditional requirements in `required`; conditional logic stays in handlers + tests |
| `sections` type confusion (array in `get_settings`, object in `update_settings`) | Called out in contracts table, per-tool schemas, and README |
| Schema/handler drift over time | Single declarative model + contract tests, not hand-maintained JSON |
| Offline/native contracts diverge silently | Per-profile contract docs; shared reason codes; parity tests |

## 12. Suggested sequencing

Phase 0 (inventory + open questions resolved) → Phases 1–3 native (one PR) →
Phase 4 offline + Phase 5 remaining tests (same PR) → Phase 6 docs + manual Codex
acceptance. Native and offline changes can ship in one commit; the Codex acceptance report
follows as a comment/document, not as a claim derived from unit tests.
