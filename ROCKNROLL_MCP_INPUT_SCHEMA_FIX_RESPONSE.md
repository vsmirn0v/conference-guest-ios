# Response: inputSchema fix for the Rock'N'Roll for Mac MCP server

**Spec under reply:** `ROCKNROLL_MCP_INPUT_SCHEMA_FIX_SPEC.md` (ТЗ: исправление inputSchema в MCP Rock'N'Roll for Mac)
**Build:** commit `e7c0b23` on `main` ("Publish real MCP inputSchemas with pre-dispatch validation (server 0.2.0)"), server protocol version bumped to **0.2.0**
**Status:** implemented, reviewed, fully tested, committed and pushed. One acceptance item (§9 "Сквозная проверка через Codex") is a manual step and is **not yet executed** — see §9 below.

---

## 1. Цель и границы работы — Done

The defect class is fixed at the root: `tools/list` now publishes a real, handler-accurate `inputSchema` for every one of the 13 native tools, and the server validates every call against that same schema **before** any handler executes and before any approval/scope decision is consumed. The scope model is unchanged: a read-only client still sees only the seven read tools and still cannot execute writes — the schema fix grants no additional rights (spec §4, last paragraph).

## 2. Подтверждённый дефект — Confirmed and fixed

Confirmed. The old catalog carried fabricated or empty schemas (e.g. `meeting_id` missing from `required`, unimplemented filters advertised, no types/descriptions), so clients like Codex could not discover the contract and the server reported misleading errors only at handler level.

Fix locations (all in commit `e7c0b23`):

- `NativeMacGuest/MCP/MCPToolSchemas.swift` — **new**: declarative schema model, the single source of truth for both the published `tools/list` catalog and pre-dispatch validation.
- `NativeMacGuest/MCP/MCPCore.swift` — validation wired in after the scope check, before dispatch; protocol version 0.1.x → 0.2.0.
- `NativeMacGuest/MCP/NativeDesktopMCPBackend.swift` — handler-side alignment (stringified cursor/date filter keys, `situation_modes` keyed by raw string values, hoisted `providerInfo`/mode computations).
- `mcp/rocknroll_local.py` — offline parity server exposes the identical catalog and validation.
- `mcp/CONTRACTS.md` — **new**: the full per-tool contract inventory (spec §4).
- `mcp/examples/tools-list.native.json` — **new**: anonymized full `tools/list` response, drift-guarded by a test.
- `NativeMacGuest/Tests/Parity/MCPSchemaContractTests.swift` — **new**: 15 contract/validation tests.
- `mcp/README.md` — updated: 0.2.0, reconnect instructions, contract docs pointer.

## 3. Ожидаемый результат — Done

Every published schema now states: exact field names; precise types (including array item types and nested object properties); `required` lists containing exactly the unconditionally required fields; `enum`s limited to actually accepted values; real bounds (`minLength`, `minimum`/`maximum` for limits) and documented defaults (described, not auto-substituted); a `description` per field that says what the identifier is and **which tool result to take it from**; and conditional requirements of control operations (e.g. `target_participant` only for `op: "remove_participant"`, `patch`/`meeting_id` only for update operations) expressed via `anyOf`/`if`-style descriptions and enforced in validation. No non-working filters were added just because an older spec proposed them — the priority rule «фактически поддерживаемый контракт → согласованная валидация → схема и документация» was followed.

## 4. Инвентаризация контрактов — Done

Full inventory table for all 13 handlers (field, type, required, default, range/enum, `null` behavior, semantics, verification source, including nested DTOs and conditional branches) is in **`mcp/CONTRACTS.md`**. Highlights against the spec's "Проверить" column:

- `rocknroll_status` — genuinely zero-argument; empty `properties`/`required` retained.
- `rocknroll_list_meetings` — real filters only: `kind` (enum `meeting|outcome`), `from`/`to` (RFC 3339, `from` must be ≤ `to`), `limit`, `cursor`. Order and cursor semantics documented.
- `rocknroll_get_meeting` / `rocknroll_get_transcript` / `rocknroll_get_outcome` — `meeting_id`/`outcome_id` required, typed `string`, `minLength: 1`. Transcript adds `from`/`to`, `limit`, `cursor`.
- `rocknroll_search` — `query` required, `types` array with `items.enum`, `from`/`to`, `limit`, `cursor`.
- `rocknroll_list_tasks`, `rocknroll_get_settings`, `rocknroll_control_meeting`, `rocknroll_set_favorite`, `rocknroll_update_task`, `rocknroll_update_settings`, `rocknroll_run_assistant` — all parameters enumerated per handler; `update_settings`/`update_task` describe every allowed nested patch key and type instead of an opaque object.

## 5. Требования к JSON Schema — All 15 requirements met

1. ✅ Every root schema is `type: "object"`.
2. ✅ `properties` lists only really-supported fields.
3. ✅ `required` contains exactly the unconditionally required fields.
4. ✅ Empty schemas only for genuinely zero-argument tools (`rocknroll_status`).
5. ✅ Explicit unknown-field policy: `additionalProperties: false` on closed contracts; unknown fields are rejected server-side **before** dispatch. Existing supported fields/aliases were preserved first.
6. ✅ `description` on every field; IDs are documented by source result (e.g. "`meeting_id` from `rocknroll_list_meetings` → `items[].id`"), never as "any meeting name".
7. ✅ Non-empty string IDs constrained with `minLength: 1`. No UUID format is claimed — IDs are opaque strings.
8. ✅ Arrays have `items` (with nested `enum`/object types), enums have `enum`, bounded numbers have real bounds.
9. ✅ Supported dates use `format: "date-time"` with RFC 3339 + timezone documented; the handler itself parses and rejects invalid dates/missing timezone — no reliance on client-side `format` support.
10. ✅ `default` is descriptive only; server behavior on omission matches the description.
11. ✅ Omission vs explicit `null` is distinguished; `null` is rejected unless the field is typed nullable (error reports `reason: null`).
12. ✅ Conditional requirements of operations are expressed in schema and enforced in validation; mutually exclusive operation arguments are not required simultaneously.
13. ✅ No opaque `settings`/`patch`: every allowed nested key and its type is declared in the schema and checked by validation.
14. ✅ No tokens, auth headers, pairing tokens, user file paths, or real-meeting examples anywhere in schemas. The published example file is anonymized.
15. ✅ Schemas are self-contained; no remote `$ref` resolution.

## 6. Минимальные примеры исправления — Done, plus the outcome-ID discovery chain

All five minimal templates (`get_meeting`, `get_transcript`, `get_outcome`, `search`, and the genuinely zero-argument tool) match the published schemas one-to-one. In addition, the spec's open question "источник идентификатора" for `outcome_id` is solved in-band: outcome items expose `id` through `rocknroll_list_meetings` (`kind: "outcome"`) and through `rocknroll_search`, and the `outcome_id` field description names exactly that source — no out-of-band knowledge needed.

## 7. Согласование схемы и валидации — Done

Schema and validation are literally the same artifact: `MCPToolSchemas.swift` builds each tool's schema from the same declarative field definitions that drive the validator, so they cannot drift by construction. On top of that, two tests hold the line:

- `testPublishedSchemasMatchHandlerContracts` — drift guard: for every native handler, each argument the handler actually reads must exist in the published schema with a compatible type; fails the build on divergence.
- A living-example test — regenerates `mcp/examples/tools-list.native.json` and compares it byte-for-byte with the committed file.

Validation errors are structured and machine-readable: `-32602` with `details: [{field, reason}]`, where `reason` is one of `unknown_field | missing_required | null | type | min_length | max_length | minimum | maximum | enum | invalid_date | invalid_range | empty | scope | …` — clients can recover without scraping prose.

## 8. Совместимость и обновление каталога — Done

- Server version is now **0.2.0**; all 13 tool names are unchanged; existing correct calls still pass (empty `{}` remains valid for zero-argument and fully-defaulted tools).
- Tool annotations (read-only hints) are unchanged; `listChanged` stays `false` — the catalog is static, so no `notifications/tools/list_changed` storm on reconnect.
- The schema change intentionally **tightens** what was previously silently mis-accepted (fabricated filters, `null`s, unknown fields now get a clear `-32602` instead of being ignored or failing obscurely inside a handler). This is the spec's declared priority order, but it is a behavior change for any client that relied on garbage-in tolerance — documented in `mcp/CONTRACTS.md` under "Behavior changes".
- **Client reconnect:** after updating the app, remove and re-add the MCP server in the client (Codex: `mcp` config / reconnect) so it re-fetches `tools/list` and picks up the real schemas. `mcp/README.md` carries the same instruction.

## 9. Проверки и критерии приёмки

### Каталог инструментов — ✅ all 5 criteria verified natively

1. Direct `tools/list` on the native server returns schemas for all 13 published tools (captured in `mcp/examples/tools-list.native.json`).
2. All schemas are syntactically valid JSON Schema (object roots, `properties`/`required` well-formed); validated in tests by round-tripping the published catalog.
3. Per-handler readability checked for all 13 tools via the drift-guard test (`testPublishedSchemasMatchHandlerContracts`); protocol-level fields (`jsonrpc`, `id`, method) are never mixed into tool arguments — validation runs on `params.arguments` only.
4. `meeting_id`, `outcome_id`, `query` are in the `required` arrays of `rocknroll_get_meeting`, `rocknroll_get_outcome`, `rocknroll_search` respectively (asserted in tests).
5. Empty schema remains only on `rocknroll_status` — asserted.

### Параметризованные тесты — ✅ executed

- **Native:** 27/27 MCP tests green (15 new schema-contract tests + handler/scope tests), zero crashes.
- **Offline parity:** 22/22 unittest green (`python3 -m unittest discover -s mcp/tests`), `--doctor` clean.
- **Full native suite:** 449 tests, 0 failures, exit 0 — no regressions outside MCP.
- Matrix coverage per tool: minimal args, full supported args, missing required (per field), wrong type / explicit `null` / empty string, unknown field, unknown enum value, limit bounds, invalid dates and missing timezone, `from` > `to`, nested patch key/type errors, empty patch, conditional requirements, and structurally-valid-but-nonexistent IDs returning domain errors (not false success).
- Write tools were exercised against fixtures/isolated stores only — no messages sent, no mic/camera toggled, no real user meetings/tasks/settings touched. Argument errors and missing scope are verified side-effect-free (validation precedes any state mutation; scope check precedes validation).

### Сквозная проверка через Codex — ⚠️ MANUAL, not yet executed

This step requires a live Codex session against a locally running server and was deliberately not simulated. Checklist for the manual run (all prerequisites now in place):

1. Reconnect the client so it re-fetches `tools/list` (server now 0.2.0).
2. List meetings via `rocknroll_list_meetings`, pick a concrete `items[].id`.
3. `rocknroll_get_meeting` with that ID.
4. `rocknroll_get_transcript` with that ID (missing transcript = correctly described domain situation).
5. Take an `outcome_id` from the documented result source, call `rocknroll_get_outcome`.
6. `rocknroll_search` with a non-empty `query`; exercise supported filters and cursor pagination.

Expected per spec: Codex sees names, types, and required-ness before the first call; no hidden-argument hints, no adapter schema patches, no parameter-name archaeology from server errors.

## 10. Результаты работы разработчика

Delivered in commit `e7c0b23`:

- ✅ Fix of the native MCP server (plus offline parity server).
- ✅ Table of actual contracts of all tools → `mcp/CONTRACTS.md`.
- ✅ Anonymized full `tools/list` response → `mcp/examples/tools-list.native.json` (drift-guarded).
- ✅ Contract tests for schemas and validation → `MCPSchemaContractTests.swift` (15 tests) + offline parity tests.
- ⚠️ Codex end-to-end results: pending manual run (checklist above); remaining limitation listed there.
- ✅ Brief update/reconnect instruction → `mcp/README.md` and §8 above.

**Documented behavior changes** (all consistent with the spec's priority rule; previously these inputs were silently mis-handled):

- Required fields given as explicit `null` are now rejected with `reason: null`.
- Dates are strict RFC 3339 with timezone; `from` > `to` rejected (`invalid_range`); limit violations rejected (`minimum`/`maximum`).
- Unknown fields rejected (`unknown_field`) on closed contracts; unknown enum values rejected.
- `rocknroll_set_favorite` schema now exposes the supported `favorite_revision` for optimistic-concurrency-safe favorites (the tool was previously effectively unusable for its purpose without it).
- `attention.sections` keys are validated against the known section set.
- `situation_modes` is keyed by situation raw string values (was internally keyed by a non-serializable enum — a latent crash defect, see below).

**Incidental but important findings during verification** (also fixed in the same commit):

1. **Hollow tests.** The pre-existing "memory-checker workaround" in both MCP test classes swizzled `assertInvalidObjectsDeallocatedAfterScope:` to a no-op that never invoked its scope block — so **every test body in both classes was silently skipped** while reporting green. The repo's earlier "all green" MCP runs were meaningless. Fixed (the swizzle now invokes the scope block), and all native `async` test bodies were routed through a real async wrapper after discovering Xcode 26 / Swift 6.3–6.4 silently hollows `async` XCTest methods too. All green results above are genuine post-fix results.
2. **Three real `swiftlang/swift#87481` miscompile crashes** ("freed pointer was not the last allocation", host abort) — each turned out to be a genuine bug or latent defect in `NativeDesktopMCPBackend.swift`, now fixed: boxed `Date?` leaking into cursor-key filter dictionaries (stringified), `providerInfo(...)`/`mapValues` calls nested inside dictionary literals (hoisted), and the non-JSON-serializable `situation_modes` enum keying (raw string keys).

## 11. Основания

- Spec basis: local check of Rock'N'Roll 0.3.0 (84) of 2026-11-10 (`tools/list` + four read-only calls with missing required params), as cited in the spec; and the MCP Tools spec (2025-06-18 edition, compatible with the protocol version already negotiated by the server — no protocol upgrade was performed or required).
- Implementation basis: native server `MCPToolSchemas.swift` / `MCPCore.swift` / `NativeDesktopMCPBackend.swift`, offline parity `mcp/rocknroll_local.py`, contracts `mcp/CONTRACTS.md`, tests `MCPSchemaContractTests.swift`, example `mcp/examples/tools-list.native.json` — all in commit `e7c0b23`, verified by 27/27 native MCP tests, 22/22 offline tests, and the full 449-test native suite with zero failures.
