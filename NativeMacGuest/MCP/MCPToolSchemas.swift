import Foundation

// MARK: - Declarative tool schemas
//
// This file is the single source of truth for what each MCP tool accepts.
// `tools/list` renders these declarations verbatim and `MCPSchemaValidator`
// enforces them before any handler runs, so the published contract and the
// enforced contract cannot drift apart. Keep `mcp/CONTRACTS.md` in sync.

final class MCPToolProperty {
    enum ValueType: String {
        case string, boolean, integer, object, array
    }

    let type: ValueType
    let description: String
    var minLength: Int? = nil
    var format: String? = nil
    var minimum: Int? = nil
    var maximum: Int? = nil
    var `default`: Any? = nil
    var enumValues: [String]? = nil
    var items: MCPToolProperty? = nil
    var properties: [String: MCPToolProperty]? = nil
    var required: [String] = []

    init(type: ValueType, description: String) {
        self.type = type; self.description = description
    }

    static func string(_ description: String, minLength: Int? = nil, format: String? = nil,
                       enumValues: [String]? = nil, default defaultValue: String? = nil) -> MCPToolProperty {
        let property = MCPToolProperty(type: .string, description: description)
        property.minLength = minLength; property.format = format; property.enumValues = enumValues
        if let defaultValue { property.default = defaultValue }
        return property
    }

    static func boolean(_ description: String) -> MCPToolProperty {
        MCPToolProperty(type: .boolean, description: description)
    }

    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil,
                        default defaultValue: Int? = nil) -> MCPToolProperty {
        let property = MCPToolProperty(type: .integer, description: description)
        property.minimum = minimum; property.maximum = maximum
        if let defaultValue { property.default = defaultValue }
        return property
    }

    static func array(_ description: String, items: MCPToolProperty) -> MCPToolProperty {
        let property = MCPToolProperty(type: .array, description: description)
        property.items = items
        return property
    }

    static func object(_ description: String, properties: [String: MCPToolProperty] = [:],
                       required: [String] = []) -> MCPToolProperty {
        let property = MCPToolProperty(type: .object, description: description)
        property.properties = properties; property.required = required
        return property
    }

    /// Rendered into `tools/list`. Schemas are self-contained: no `$ref`, no network.
    var json: MCPJSON {
        var output: MCPJSON = ["type": type.rawValue, "description": description]
        if let minLength { output["minLength"] = minLength }
        if let format { output["format"] = format }
        if let minimum { output["minimum"] = minimum }
        if let maximum { output["maximum"] = maximum }
        if let `default` { output["default"] = `default` }
        if let enumValues { output["enum"] = enumValues }
        if let items { output["items"] = items.json }
        if let properties {
            output["properties"] = properties.mapValues { $0.json }
            output["required"] = required
            output["additionalProperties"] = false
        }
        return output
    }
}

struct MCPToolSchema {
    var properties: [String: MCPToolProperty] = [:]
    var required: [String] = []
    var additionalProperties = false

    var json: MCPJSON {
        [
            "type": "object",
            "properties": properties.mapValues { $0.json },
            "required": required,
            "additionalProperties": additionalProperties,
        ]
    }
}

struct MCPToolDefinition {
    let name: String
    let description: String
    let readOnly: Bool
    let scope: String
    let schema: MCPToolSchema
}

private let timeRange: [String: MCPToolProperty] = [
    "from": .string("RFC 3339 lower time bound; a time-zone offset or Z is required. When both bounds are given, from must be earlier than to.", format: "date-time"),
    "to": .string("RFC 3339 exclusive upper time bound; a time-zone offset or Z is required.", format: "date-time"),
]

private let pagination: [String: MCPToolProperty] = [
    "limit": .integer("Maximum number of items to return; values outside 1...100 are rejected. Defaults to 20.", minimum: 1, maximum: 100, default: 20),
    "cursor": .string("Opaque page cursor copied verbatim from a previous response's next_cursor. Reusing a cursor with changed filters fails with CURSOR_EXPIRED."),
]

private let actionID: MCPToolProperty = .string(
    "Client-generated UUID used as an idempotency key. Retrying with the same action_id and identical arguments replays the recorded result; reusing it with different arguments fails with ACTION_ID_REUSED.")

private let expectedRevision: MCPToolProperty = .string(
    "Opaque revision of the target observed before the call. Required unless this action_id replays an already-recorded call; see the tool description for where the current value is published.")

private let meetingIDFromList = "Opaque meeting identifier: the id of an item returned by rocknroll_list_meetings or rocknroll_search — never a meeting title."

func nativeMCPToolDefinitions() -> [MCPToolDefinition] {
    let meetingID = MCPToolProperty.string(meetingIDFromList, minLength: 1)
    let sessionID = MCPToolProperty.string(meetingIDFromList + " Must identify an active session (id starts with session:).", minLength: 1)
    let sectionsRead = MCPToolProperty.array(
        "Settings sections to include. Defaults to all three.",
        items: .string("Section name.", enumValues: ["app", "attention", "meeting"]))

    let attentionPatchKeys: [String: MCPToolProperty] = [
        "judge_enabled": .boolean("Enable the meeting judge."),
        "pause_on_battery": .boolean("Pause attention work while on battery power."),
        "draft_replies": .boolean("Draft replies to messages directed at you."),
        "local_drafts": .boolean("Prefer on-device drafting."),
        "push_to_talk": .boolean("Hold a key to talk back to a meeting."),
        "talk_back": .boolean("Allow spoken assistant replies."),
        "generate_outcomes": .boolean("Summarize meetings into outcomes with tasks."),
        "remote_outcomes": .boolean("Request outcomes from the remote meeting service."),
    ]
    let settingsPatch = MCPToolProperty.object(
        "Settings patch; omitting it applies no changes. Unknown section or field names are rejected.",
        properties: [
            "attention": .object("Attention settings; every field is a boolean.", properties: attentionPatchKeys),
        ])
    let desiredState = MCPToolProperty.object(
        "Requested device state; an empty object is allowed. Joining (room:/occurrence: targets) uses microphone=false to join muted; leave and camera apply to active sessions only.",
        properties: [
            "leave": .boolean("Leave the active session."),
            "microphone": .boolean("Desired microphone state for a session; for a join target, false joins muted."),
            "camera": .boolean("Desired camera state for a session."),
        ])

    return [
        .init(name: "rocknroll_status", description: "Report native backend, capabilities and app state.",
              readOnly: true, scope: "meetings:read",
              schema: .init()),
        .init(name: "rocknroll_list_meetings", description: "List active, favorite, recent, calendar and outcome meetings.",
              readOnly: true, scope: "meetings:read",
              schema: .init(properties: [
                "query": .string("Optional case-insensitive substring filter over titles and summaries; the value is trimmed and a whitespace-only filter is ignored."),
                "kind": .string("Restrict results to one meeting kind.", enumValues: ["active", "favorite", "recent", "calendar", "outcome"]),
                "from": timeRange["from"]!, "to": timeRange["to"]!,
                "limit": pagination["limit"]!, "cursor": pagination["cursor"]!,
              ])),
        .init(name: "rocknroll_get_meeting", description: "Get one native meeting record.",
              readOnly: true, scope: "meetings:read",
              schema: .init(properties: ["meeting_id": meetingID], required: ["meeting_id"])),
        .init(name: "rocknroll_get_transcript", description: "Get the authoritative transcript available to the native meeting.",
              readOnly: true, scope: "meetings:read",
              schema: .init(properties: [
                "meeting_id": sessionID,
                "from": timeRange["from"]!, "to": timeRange["to"]!,
                "limit": pagination["limit"]!, "cursor": pagination["cursor"]!,
              ], required: ["meeting_id"])),
        .init(name: "rocknroll_get_outcome", description: "Get one stored historical outcome by outcome ID. Task items include the current profile’s archived flag.",
              readOnly: true, scope: "meetings:read",
              schema: .init(properties: [
                "outcome_id": .string("Opaque outcome identifier: the id of a kind:outcome item from rocknroll_list_meetings or rocknroll_search, or the meeting_id field of task items. This is not a meeting_id.", minLength: 1),
              ], required: ["outcome_id"])),
        .init(name: "rocknroll_get_notes", description: "Get the raw Markdown note for one meeting by a persisted or active session ID. Notes are user-authored personal records; they are attributed separately from outcomes and transcripts. Never a write: this tool changes nothing.",
              readOnly: true, scope: "meetings:read",
              schema: .init(properties: [
                "meeting_id": .string("Opaque meeting identifier: an id returned by rocknroll_list_meetings or rocknroll_search. Must identify a persisted session (id starts with session:) or an outcome-backed historical session.", minLength: 1),
              ], required: ["meeting_id"])),
        .init(name: "rocknroll_list_tasks", description: "List tasks from native meeting outcomes. Tasks archived by the current profile are excluded by default.",
              readOnly: true, scope: "meetings:read",
              schema: .init(properties: [
                "meeting_id": .string("Filter by outcome id (outcome:…), matching the meeting_id field of task items."),
                "done": .boolean("Filter by completion state."),
                "owner": .string("Case-insensitive substring match on the task owner."),
                "personal_only": .boolean("Only tasks assigned to the current profile by stable ID or confirmed full alias."),
                "include_archived": .boolean("Include tasks archived by the current profile; defaults to false."),
                "limit": pagination["limit"]!, "cursor": pagination["cursor"]!,
              ])),
        .init(name: "rocknroll_search", description: "Search native meetings, outcomes, tasks and transcripts.",
              readOnly: true, scope: "meetings:read",
              schema: .init(properties: [
                "query": .string("Case-insensitive search text, trimmed; must be non-empty after trimming.", minLength: 1),
                "types": .array("Result types to search; defaults to all five. Unknown values are rejected.",
                                items: .string("Result type.", enumValues: ["meeting", "outcome", "task", "transcript", "note"])),
                "personal_only": .boolean("Restrict task results to the current profile's assignments."),
                "include_archived": .boolean("Include task results archived by the current profile; defaults to false."),
                "limit": pagination["limit"]!, "cursor": pagination["cursor"]!,
              ], required: ["query"])),
        .init(name: "rocknroll_get_settings", description: "Read allowlisted native settings and resolved attention configuration.",
              readOnly: true, scope: "settings:read",
              schema: .init(properties: [
                "sections": sectionsRead,
                "meeting_id": .string("Active session id; only consulted when sections includes meeting."),
              ])),
        .init(name: "rocknroll_control_meeting", description: "Request a bound native meeting control. Every call requires native approval; a session target applies device state or leaves, a room or calendar target joins it.",
              readOnly: false, scope: "meetings:control",
              schema: .init(properties: [
                "action_id": actionID,
                "meeting_id": meetingID,
                "desired_state": desiredState,
              ], required: ["action_id", "meeting_id"])),
        .init(name: "rocknroll_set_favorite", description: "Set a favorite room through the native library. expected_revision is required unless action_id replays a recorded call; the current value is published as sections.app.favorite_revision by rocknroll_get_settings.",
              readOnly: false, scope: "favorites:write",
              schema: .init(properties: [
                "action_id": actionID,
                "room_id": .string("Opaque room identifier: the id of a favorite or recent item from rocknroll_list_meetings.", minLength: 1),
                "favorite": .boolean("true stars the room, false unstars it."),
                "expected_revision": expectedRevision,
              ], required: ["action_id", "room_id", "favorite"])),
        .init(name: "rocknroll_update_task", description: "Update an allowlisted task field. expected_revision is the outcome UUID (the middle component of task_id) and is required unless action_id replays a recorded call. An empty patch applies no changes.",
              readOnly: false, scope: "tasks:write",
              schema: .init(properties: [
                "action_id": actionID,
                "task_id": .string("Opaque task identifier: the id of a task item from rocknroll_list_tasks, rocknroll_search or rocknroll_get_outcome.", minLength: 1),
                "expected_revision": expectedRevision,
                "text": .string("New task text; omit to leave unchanged."),
                "owner": .string("New owner; omit to leave unchanged."),
                "done": .boolean("New completion state; omit to leave unchanged."),
              ], required: ["action_id", "task_id"])),
        .init(name: "rocknroll_update_settings", description: "Update an allowlisted native setting. expected_revision is the revision field from rocknroll_get_settings and is required unless action_id replays a recorded call.",
              readOnly: false, scope: "settings:write",
              schema: .init(properties: [
                "action_id": actionID,
                "expected_revision": expectedRevision,
                "sections": settingsPatch,
              ], required: ["action_id"])),
        .init(name: "rocknroll_run_assistant", description: "Run a safe in-app assistant prompt. Actions that need native confirmation are returned as approval-required and are never executed through MCP.",
              readOnly: false, scope: "assistant:run",
              schema: .init(properties: [
                "action_id": actionID,
                "prompt": .string("Assistant instruction, trimmed; must be non-empty after trimming.", minLength: 1),
                "meeting_id": .string("Optional active session id (starts with session:) scoping the assistant to one meeting."),
                "conversation_id": .string("Recognized for compatibility but always rejected with CAPABILITY_UNAVAILABLE: this assistant exposes no external conversation IDs."),
              ], required: ["action_id", "prompt"])),
    ]
}

// MARK: - Pre-dispatch structural validation
//
// Runs after the scope check and before any handler, so a structurally invalid
// call produces no side effect: no action is recorded and no approval is shown.

enum MCPSchemaValidator {
    static func validate(_ arguments: MCPJSON, schema: MCPToolSchema) throws {
        for field in schema.required where arguments[field] == nil {
            throw invalid(field, "required", "\(field) is required.")
        }
        for (field, value) in arguments {
            guard let property = schema.properties[field] else {
                throw invalid(field, "unknown_field", "Unknown argument: \(field).")
            }
            try validateValue(value, property: property, field: field)
        }
        // Cross-field range check for tools that accept a time window.
        if schema.properties["from"] != nil, let fromText = arguments["from"] as? String, let toText = arguments["to"] as? String {
            let from = try MCPValue.date(fromText, key: "from")
            let to = try MCPValue.date(toText, key: "to")
            if let from, let to, from >= to {
                throw invalid("from", "range", "from must be earlier than to.")
            }
        }
    }

    private static func validateValue(_ value: Any, property: MCPToolProperty, field: String) throws {
        if value is NSNull { throw invalid(field, "null", "\(field) must not be null.") }
        switch property.type {
        case .string:
            guard let text = value as? String else { throw invalid(field, "type", "\(field) must be a string.") }
            if let minLength = property.minLength, text.count < minLength {
                throw invalid(field, "empty", "\(field) must not be empty.")
            }
            if let enums = property.enumValues, !enums.contains(text) {
                throw invalid(field, "enum", "\(field) must be one of: \(enums.joined(separator: ", ")).")
            }
        case .boolean:
            guard isBool(value) else { throw invalid(field, "type", "\(field) must be a boolean.") }
        case .integer:
            // Booleans bridge to NSNumber on Darwin and would otherwise parse as 0/1.
            guard let number = value as? Int, !isBool(value) else {
                throw invalid(field, "type", "\(field) must be an integer.")
            }
            if let minimum = property.minimum, number < minimum { throw invalid(field, "range", "\(field) must be at least \(minimum).") }
            if let maximum = property.maximum, number > maximum { throw invalid(field, "range", "\(field) must be at most \(maximum).") }
        case .array:
            guard let elements = value as? [Any] else { throw invalid(field, "type", "\(field) must be an array.") }
            if let items = property.items {
                for (index, element) in elements.enumerated() {
                    try validateValue(element, property: items, field: "\(field)[\(index)]")
                }
            }
        case .object:
            guard let object = value as? MCPJSON else { throw invalid(field, "type", "\(field) must be an object.") }
            for nested in property.required where object[nested] == nil || object[nested] is NSNull {
                throw invalid("\(field).\(nested)", "required", "\(field).\(nested) is required.")
            }
            for (key, nested) in object {
                guard let nestedProperty = property.properties?[key] else {
                    throw invalid("\(field).\(key)", "unknown_field", "Unknown \(field) field: \(key).")
                }
                try validateValue(nested, property: nestedProperty, field: "\(field).\(key)")
            }
        }
    }

    /// Distinguishes real booleans from NSNumber on Darwin, where `NSNumber(value: true) as? Int` yields 1.
    private static func isBool(_ value: Any) -> Bool {
        if let number = value as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() }
        return value is Bool
    }

    private static func invalid(_ field: String, _ reason: String, _ message: String) -> MCPToolFailure {
        MCPToolFailure("INVALID_ARGUMENT", message, details: ["field": field, "reason": reason])
    }
}
