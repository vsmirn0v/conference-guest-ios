# Rock'N'Roll MCP

MCP access to the Rock'N'Roll native desktop app (meetings, favorites, calendar,
outcomes, tasks, settings, and the in-app assistant) for AI agents such as Codex
and Claude.

Two profiles ship in this directory:

| Profile | Script | Data source | Write access |
|-|-|-|-|
| Native (loopback) | `rocknroll_native.py` | The running Rock'N'Roll app over `127.0.0.1` HTTP | Yes, scoped + user-approved |
| Offline (read-only) | `rocknroll_local.py` | Fixture files on disk | No, reads only |

Both expose the same 14 tools and speak MCP (protocol version `2025-03-26`)
over stdio, so a client configured for one can be pointed at the other by
changing a single command.

## Tools

| Tool | Scope | Read-only | Purpose |
|-|-|-|-|
| `rocknroll_status` | `meetings:read` | yes | Backend, capabilities, app state |
| `rocknroll_list_meetings` | `meetings:read` | yes | Active, favorite, recent, calendar and outcome meetings |
| `rocknroll_get_meeting` | `meetings:read` | yes | One meeting record with metadata |
| `rocknroll_get_transcript` | `meetings:read` | yes | Authoritative transcript of a meeting |
| `rocknroll_get_outcome` | `meetings:read` | yes | One stored outcome by ID |
| `rocknroll_get_notes` | `meetings:read` | yes | Raw personal-note Markdown for one meeting |
| `rocknroll_list_tasks` | `meetings:read` | yes | Tasks collected from outcomes |
| `rocknroll_search` | `meetings:read` | yes | Search meetings, outcomes, tasks, transcripts, notes |
| `rocknroll_get_settings` | `settings:read` | yes | Allowlisted settings + resolved attention configuration |
| `rocknroll_control_meeting` | `meetings:control` | no | Bound controls (mute/leave/...) with approval |
| `rocknroll_set_favorite` | `favorites:write` | no | Favorite/unfavorite a room |
| `rocknroll_update_task` | `tasks:write` | no | Update an allowlisted task field |
| `rocknroll_update_settings` | `settings:write` | no | Update an allowlisted setting (revision-checked) |
| `rocknroll_run_assistant` | `assistant:run` | no | Run a safe in-app assistant prompt |

Secrets never cross the wire: settings reads report `has_key` booleans, and API
keys stay in the macOS keychain.

## Schemas and validation (server 0.3.0)

Every tool publishes a real, self-contained `inputSchema` (no `$ref`, every
property described, `additionalProperties: false`). Arguments are validated
against that schema **before** dispatch and before any approval prompt, so a
structurally invalid call never reaches the backend, never records an action,
and never asks the user for approval. Validation rejects with a structured
error `details: {field, reason}`:

- unknown fields (`unknown_field`), including unknown keys inside a `sections`
  patch (`sections.attention.bogus`),
- missing required fields (`required`), explicit `null` (`null`), wrong types
  with no coercion (`type`), empty strings (`empty`), out-of-enum values
  (`enum`), and out-of-range limits or malformed dates (`range` / `format`).

`limit` must be 1–100; RFC 3339 timestamps must carry a time-zone offset; when
both bounds are given, `from` must be earlier than `to`. Scope checks run
before validation, so an under-scoped client still gets `SCOPE_DENIED`.

The exact argument contract per tool lives in [CONTRACTS.md](CONTRACTS.md);
a generated example of the live native catalog is checked in at
[examples/tools-list.native.json](examples/tools-list.native.json) and is
asserted to match the server output in
`MCPSchemaContractTests.testToolsListExampleFileMatchesLiveCatalog`.

**Compatibility:** tool names, scope names, and annotations are unchanged from
0.1.0, and tools whose arguments are all optional still accept `{}`. Because
the catalog is static, `listChanged` remains `false`; clients that cached the
0.1.0 catalog (empty schemas) only need to reconnect — restart the app (or
re-pair) so the client fetches a fresh `tools/list`.

## Pairing a real client (native profile)

1. **Run the app.** The MCP listener starts automatically at launch and binds a
   random port on `127.0.0.1` (local connections only). It writes an endpoint
   description to:

   ```
   ~/.config/rocknroll-mcp/endpoint.json
   ```
   (fallback: `~/Library/Application Support/RockNRMCP/endpoint.json` if the
   config directory cannot be created). The file is mode `0600` because it
   carries the one-time pairing secret:
   ```json
   {"host": "127.0.0.1", "port": 51234, "path": "/mcp", "pairing_token": "…"}
   ```

2. **Pair.** The app menu has **Pair MCP Client…**, which shows the endpoint
   file path and the current pairing token. In practice you don't need it: the
   bridge pairs itself on first contact. When `~/.config/rocknroll-mcp/client.json`
   does not exist yet, the bridge calls `POST /pair` with the endpoint's pairing
   token, stores the issued bearer token in `client.json` (mode `0600`), and
   reuses it afterwards. Pairing is single-use: a consumed pairing token
   rotates, and the endpoint file is rewritten with the fresh secret.

   Default grants are read-only (`meetings:read`, `settings:read`). To obtain
   write scopes, pair manually and request them explicitly — unknown scope
   names are dropped:
   ```bash
   curl -s -X POST "http://127.0.0.1:<port>/pair" \
     -H 'Content-Type: application/json' \
     -d '{"pairing_token": "<from endpoint.json>", "client": "codex",
          "scopes": ["meetings:read", "settings:read", "favorites:write", "settings:write"]}'
   # → {"client_token": "…", "scopes": […]}  — store client_token as {"token": "…"} in client.json
   ```

3. **Register the server with your client.** It is a stdio server:

   ```toml
   # ~/.codex/config.toml
   [mcp_servers.rocknroll]
   command = "python3"
   args = ["/abs/path/to/conference-guest-ios/mcp/rocknroll_native.py"]
   ```
   ```jsonc
   // Claude Desktop: claude_desktop_config.json
   {
     "mcpServers": {
       "rocknroll": {
         "command": "python3",
         "args": ["/abs/path/to/conference-guest-ios/mcp/rocknroll_native.py"]
       }
     }
   }
   ```

4. **Try it.** Ask the agent for "my Rock'N'Roll status" or "list my meetings".
   Reads work immediately; writes pop an approval dialog in the app.

### Safety model (native writes)

- Every write takes a client-generated `action_id` (UUID). Re-sending the same
  `action_id` with the same payload replays the recorded result (safe retries);
  the same `action_id` with a different payload fails with `ACTION_ID_REUSED`.
- Every write is recorded in an in-app audit log (client label, status, failure
  code); denied approvals appear as `rejected` / `APPROVAL_DENIED`.
- `rocknroll_update_settings` requires an `expected_revision` obtained from
  `rocknroll_get_settings`; a stale value fails retryably with
  `REVISION_CONFLICT` and touches nothing.
- `rocknroll_run_assistant` never uses the app's "send without asking" bypass:
  actions that would send chat are returned as `needs_native_confirmation`
  for the human to confirm in the app.

## Offline profile

For development and demos without the app running — a read-only server over
fixture data with identical tool names:

```bash
# Diagnose fixture coverage without printing meeting content
python3 mcp/rocknroll_local.py --data-root mcp/fixtures --doctor

# Serve over stdio (point a client at this command)
python3 mcp/rocknroll_local.py --data-root mcp/fixtures
```

## Tests

```bash
python3 -m unittest discover -s mcp/tests -v   # 28 offline protocol + schema-parity tests
```

The native surface is covered in the `RockNativeGuest` Xcode target:
`MCPNativeTests` (12 pairing/transport/backend tests) and
`MCPSchemaContractTests` (15 catalog, drift-guard, validation-matrix, and
side-effect-safety tests).
