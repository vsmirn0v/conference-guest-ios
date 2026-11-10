#!/usr/bin/env python3
"""Offline, read-only Rock'N'Roll MCP server.

The server speaks newline-delimited JSON-RPC over stdio. It reads only the
allowlisted persisted application files and never launches the app.
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import pathlib
import sys
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Iterable

PROTOCOL_VERSION = "2025-03-26"
SERVER_VERSION = "0.3.0"
BUNDLE_ID = "dev.vsmirn0v.conferenceguest.nativeguest"
DEFAULT_RELATIVE_ROOT = pathlib.Path("Library/Containers") / BUNDLE_ID / "Data/Library/Application Support"
MAX_LIMIT = 100
DEFAULT_LIMIT = 20
TRANSCRIPT_BYTES = 64 * 1024
NOTES_BYTES = 12 * 1024
ALLOWED_SOURCES = (
    pathlib.PurePosixPath("Attention/assistant.json"),
    pathlib.PurePosixPath("MeetingReminders/state.json"),
    pathlib.PurePosixPath("MeetingLibrary/notes.json"),
)


class MCPError(Exception):
    def __init__(self, code: str, message: str, retryable: bool = False, details: dict[str, Any] | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details or {}

    def envelope(self) -> dict[str, Any]:
        return {"code": self.code, "message": self.message, "retryable": self.retryable, "details": self.details}


def utc_now() -> str:
    return format_time(dt.datetime.now(dt.timezone.utc).astimezone())


def format_time(value: dt.datetime | str | None) -> str | None:
    if value is None or isinstance(value, str):
        return value
    if value.tzinfo is None:
        value = value.replace(tzinfo=dt.timezone.utc)
    return value.isoformat(timespec="seconds")


def parse_time(value: Any, field: str) -> dt.datetime | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise MCPError("INVALID_ARGUMENT", f"{field} must be an RFC 3339 timestamp.", details={"field": field, "reason": "format"})
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = dt.datetime.fromisoformat(text)
    except ValueError as exc:
        raise MCPError("INVALID_ARGUMENT", f"{field} must be an RFC 3339 timestamp.", details={"field": field, "reason": "format"}) from exc
    if parsed.tzinfo is None:
        raise MCPError("INVALID_ARGUMENT", f"{field} must include a time-zone offset.", details={"field": field, "reason": "format"})
    return parsed


def parse_bool(value: Any, field: str) -> bool | None:
    if value is None:
        return None
    if not isinstance(value, bool):
        raise MCPError("INVALID_ARGUMENT", f"{field} must be a boolean.", details={"field": field, "reason": "type"})
    return value


def clamp_limit(value: Any) -> int:
    if value is None:
        return DEFAULT_LIMIT
    if not isinstance(value, int) or isinstance(value, bool):
        raise MCPError("INVALID_ARGUMENT", "limit must be an integer.", details={"field": "limit", "reason": "type"})
    if value < 1 or value > MAX_LIMIT:
        raise MCPError("INVALID_ARGUMENT", f"limit must be between 1 and {MAX_LIMIT}.", details={"field": "limit", "reason": "range"})
    return value


def stable_id(kind: str, source: str, raw: Any) -> str:
    if isinstance(raw, str) and raw.strip():
        token = raw.strip()
    else:
        token = json.dumps(raw, sort_keys=True, ensure_ascii=False, default=str)
    digest = hashlib.sha256(token.encode("utf-8")).hexdigest()[:24]
    return f"{kind}:{source}:{digest}"


def json_size(value: Any) -> int:
    return len(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


def redact(value: Any) -> Any:
    if isinstance(value, dict):
        blocked = {"invitation", "messages", "instructions", "apiKey", "api_key", "password", "token", "secret"}
        return {key: redact(item) for key, item in value.items() if key not in blocked}
    if isinstance(value, list):
        return [redact(item) for item in value]
    return value


@dataclass
class SourceState:
    code: str = "SOURCE_NOT_FOUND"
    path: str = ""
    available: bool = False
    readable: bool = False
    schema: Any = None
    modified_at: str | None = None
    warning: str | None = None


@dataclass
class Fragment:
    record: dict[str, Any]
    lines: list[dict[str, Any]]
    provenance: dict[str, Any]
    modified_at: str | None


@dataclass
class Snapshot:
    id: str
    created_at: str
    outcomes: list[dict[str, Any]] = field(default_factory=list)
    occurrences: list[dict[str, Any]] = field(default_factory=list)
    fragments: list[Fragment] = field(default_factory=list)
    notes: list[dict[str, Any]] = field(default_factory=list)
    sources: dict[str, SourceState] = field(default_factory=dict)

    def source_provenance(self) -> list[dict[str, Any]]:
        result = []
        for name, state in self.sources.items():
            result.append({
                "type": name,
                "path": state.path,
                "available": state.available,
                "schema": state.schema,
                "modified_at": state.modified_at,
            })
        return result


class OfflineRocknrollBackend:
    def __init__(self, root: pathlib.Path):
        self.root = root.expanduser().resolve()
        self.snapshots: dict[str, Snapshot] = {}
        self.cursors: dict[str, dict[str, Any]] = {}
        self._cursor_key = uuid.uuid4().hex

    def source_path(self, relative: str) -> pathlib.Path:
        try:
            relative_path = pathlib.PurePosixPath(relative)
        except ValueError as exc:
            raise MCPError("INVALID_ARGUMENT", "Invalid source path.") from exc
        if relative_path.is_absolute() or ".." in relative_path.parts:
            raise MCPError("ACCESS_DENIED", "The requested path is outside the allowlisted sources.")
        try:
            resolved_root = self.root.resolve(strict=False)
            resolved = (resolved_root / pathlib.Path(*relative_path.parts)).resolve(strict=False)
            resolved.relative_to(resolved_root)
        except (OSError, ValueError) as exc:
            raise MCPError("ACCESS_DENIED", "The requested path is outside the allowlisted sources.") from exc
        return resolved

    def _read_json(self, relative: str) -> tuple[dict[str, Any] | None, SourceState]:
        path = self.source_path(relative)
        state = SourceState(path=str(path))
        if not self.root.exists():
            state.warning = "Configured data root does not exist."
            return None, state
        if not path.exists():
            state.warning = "Source file does not exist."
            return None, state
        state.available = True
        try:
            stat = path.stat()
            state.modified_at = format_time(dt.datetime.fromtimestamp(stat.st_mtime, dt.timezone.utc))
        except OSError:
            pass
        last_error: Exception | None = None
        for _ in range(3):
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
                if not isinstance(data, dict):
                    raise ValueError("Top-level JSON value must be an object.")
                state.readable = True
                state.code = "OK"
                if relative.endswith("state.json"):
                    state.schema = data.get("schema")
                return data, state
            except (OSError, UnicodeDecodeError, ValueError) as exc:
                last_error = exc
                time.sleep(0.02)
        state.code = "ACCESS_DENIED" if isinstance(last_error, PermissionError) else "CORRUPT_SOURCE"
        state.warning = "Source could not be read as a stable JSON object."
        return None, state

    def _read_journal_files(self) -> tuple[list[Fragment], SourceState]:
        directory_name = "Attention/decisions"
        directory = self.source_path(directory_name)
        state = SourceState(path=str(directory))
        fragments: list[Fragment] = []
        if not self.root.exists():
            state.warning = "Configured data root does not exist."
            return fragments, state
        if not directory.exists():
            state.warning = "Decision journal directory does not exist."
            return fragments, state
        if not directory.is_dir():
            state.code = "CORRUPT_SOURCE"
            state.warning = "Decision journal path is not a directory."
            return fragments, state
        state.available = True
        modified: str | None = None
        try:
            for path in sorted(directory.glob("*.jsonl")):
                try:
                    modified = format_time(dt.datetime.fromtimestamp(path.stat().st_mtime, dt.timezone.utc))
                except OSError:
                    modified = None
                with path.open("r", encoding="utf-8") as handle:
                    for line_number, raw_line in enumerate(handle, 1):
                        line = raw_line.rstrip("\r\n")
                        if not line:
                            continue
                        try:
                            record = json.loads(line)
                        except json.JSONDecodeError:
                            # A process may still be writing the final line. Only a completed
                            # malformed line is reported, so defer until the next attempt.
                            continue
                        if not isinstance(record, dict):
                            continue
                        window = record.get("window") if isinstance(record.get("window"), dict) else {}
                        lines = window.get("lines") if isinstance(window.get("lines"), list) else []
                        clean_lines = [item for item in lines if isinstance(item, dict)]
                        record_id = record.get("id")
                        fragments.append(Fragment(
                            record=record,
                            lines=clean_lines,
                            provenance={
                                "type": "transcript_fragment",
                                "source": path.name,
                                "line": line_number,
                                "record_id": record_id if isinstance(record_id, str) else None,
                            },
                            modified_at=modified,
                        ))
        except OSError as exc:
            state.code = "ACCESS_DENIED"
            state.warning = f"Unable to read the decision journal: {exc}."
        state.readable = state.code != "ACCESS_DENIED"
        if state.code == "SOURCE_NOT_FOUND":
            state.code = "OK"
        return fragments, state

    def load_snapshot(self) -> Snapshot:
        assistant, assistant_state = self._read_json("Attention/assistant.json")
        reminders, reminder_state = self._read_json("MeetingReminders/state.json")
        notes_data, notes_state = self._read_json("MeetingLibrary/notes.json")
        fragments, journal_state = self._read_journal_files()
        snapshot = Snapshot(
            id=uuid.uuid4().hex,
            created_at=utc_now(),
            sources={"assistant": assistant_state, "calendar_cache": reminder_state,
                     "meeting_library": notes_state, "decision_journal": journal_state},
        )
        if assistant is not None:
            outcomes = assistant.get("outcomes", [])
            if isinstance(outcomes, list):
                snapshot.outcomes = [item for item in outcomes if isinstance(item, dict)]
        if reminders is not None:
            occurrences = reminders.get("occurrences", [])
            if isinstance(occurrences, list):
                snapshot.occurrences = [item for item in occurrences if isinstance(item, dict)]
        if notes_data is not None:
            records = notes_data.get("notes", [])
            if isinstance(records, list):
                snapshot.notes = [item for item in records if isinstance(item, dict)]
        snapshot.fragments = fragments
        self.snapshots[snapshot.id] = snapshot
        if len(self.snapshots) > 64:
            for key in list(self.snapshots)[:-64]:
                self.snapshots.pop(key, None)
        return snapshot

    @staticmethod
    def _session_file_id(session_id: Any) -> str | None:
        if not isinstance(session_id, str) or not session_id.strip():
            return None
        return f"session:file:{session_id.strip()}"

    @classmethod
    def _note_record_id(cls, note: dict[str, Any]) -> str | None:
        session_id = note.get("session_id")
        note_id = note.get("note_id")
        if not isinstance(note_id, str) or not note_id.strip():
            return None
        session_part = session_id.strip() if isinstance(session_id, str) else "unknown"
        return f"note:file:{session_part}:{note_id.strip()}"

    def _find_note(self, snapshot: Snapshot, meeting_id: str) -> dict[str, Any]:
        """Resolve a session:<scope>:<uuid>-shaped id against the persisted notes."""
        raw = meeting_id.split(":")[-1]
        for note in snapshot.notes:
            if note.get("session_id") == raw:
                return note
        raise MCPError("MEETING_NOT_FOUND", "The requested meeting is unavailable.")

    def source_status(self) -> dict[str, Any]:
        snapshot = self.load_snapshot()
        categories = {
            "outcomes": any(s.available for n, s in snapshot.sources.items() if n == "assistant"),
            "tasks": any(s.available for n, s in snapshot.sources.items() if n == "assistant"),
            "calendar": any(s.available for n, s in snapshot.sources.items() if n == "calendar_cache"),
            "notes": any(s.available for n, s in snapshot.sources.items() if n == "meeting_library"),
            "transcript_fragments": any(s.available for n, s in snapshot.sources.items() if n == "decision_journal"),
        }
        return {
            "backend": "offline",
            "server": {"name": "rocknroll-local", "version": SERVER_VERSION},
            "app": {"running": None, "bundle_id": BUNDLE_ID},
            "data_root": str(self.root),
            "sources": snapshot.source_provenance(),
            "categories": categories,
            "capabilities": {
                "kinds": ["calendar", "outcome", "note", "transcript_fragment"],
                "search_types": ["meeting", "outcome", "task", "transcript", "note"],
                "controls": [],
                "mutations": [],
                "assistant": False,
                "settings": False,
            },
            "limitations": [
                "Read-only persisted-data projection.",
                "Decision-journal transcripts are observed fragments and are marked partial.",
                "Active meetings, favorites, resolved settings, attention state and the in-app assistant require the native profile.",
            ],
            "observed_at": snapshot.created_at,
        }

    def _cursor(self, snapshot_id: str, kind: str, filters: dict[str, Any], offset: int) -> str | None:
        token = base64.urlsafe_b64encode(json.dumps({
            "k": self._cursor_key,
            "s": snapshot_id,
            "t": kind,
            "f": filters,
            "o": offset,
        }, sort_keys=True, separators=(",", ":")).encode()).decode().rstrip("=")
        self.cursors[token] = {"snapshot_id": snapshot_id, "kind": kind, "filters": filters, "offset": offset}
        if len(self.cursors) > 512:
            for key in list(self.cursors)[:-512]:
                self.cursors.pop(key, None)
        return token

    def _decode_cursor(self, token: Any, kind: str, filters: dict[str, Any]) -> tuple[Snapshot, int]:
        if token is None:
            snapshot = self.load_snapshot()
            return snapshot, 0
        if not isinstance(token, str) or token not in self.cursors:
            raise MCPError("CURSOR_EXPIRED", "The cursor is unknown or has expired.", retryable=True)
        cursor = self.cursors[token]
        snapshot = self.snapshots.get(cursor["snapshot_id"])
        if snapshot is None or cursor["kind"] != kind or cursor["filters"] != filters:
            raise MCPError("CURSOR_EXPIRED", "The cursor no longer matches this query or snapshot.", retryable=True)
        return snapshot, int(cursor["offset"])

    def _page(self, snapshot: Snapshot, kind: str, filters: dict[str, Any], offset: int, limit: int, items: list[Any]) -> dict[str, Any]:
        page = items[offset:offset + limit]
        next_offset = offset + len(page)
        return {
            "items": page,
            "next_cursor": self._cursor(snapshot.id, kind, filters, next_offset) if next_offset < len(items) else None,
            "observed_at": snapshot.created_at,
            "coverage": "partial",
            "sources": snapshot.source_provenance(),
            "warnings": [],
        }

    @staticmethod
    def _record_time(record: dict[str, Any], *keys: str) -> dt.datetime | None:
        for key in keys:
            parsed = parse_time(record.get(key), key)
            if parsed is not None:
                return parsed
        return None

    @staticmethod
    def _in_range(value: dt.datetime | None, start: dt.datetime | None, end: dt.datetime | None) -> bool:
        if start is not None and (value is None or value < start):
            return False
        if end is not None and (value is None or value >= end):
            return False
        return True

    def _outcome_item(self, snapshot: Snapshot, outcome: dict[str, Any]) -> dict[str, Any]:
        outcome_id = stable_id("outcome", "file", outcome.get("id") or outcome)
        ended = self._record_time(outcome, "endedAt", "ended_at")
        return {
            "id": outcome_id,
            "kind": "outcome",
            "title": outcome.get("meetingTitle") or outcome.get("title") or "Untitled meeting",
            "summary": outcome.get("summary") or "",
            "ended_at": format_time(ended),
            "favorite": None,
            "related": {"outcomes": [outcome_id]},
            "coverage": "complete",
            "provenance": {"type": "outcome", "source": "assistant.json", "record_id": outcome.get("id")},
        }

    def _occurrence_item(self, snapshot: Snapshot, occurrence: dict[str, Any]) -> dict[str, Any]:
        occurrence_id = stable_id("occurrence", "file", occurrence.get("id") or occurrence)
        start = self._record_time(occurrence, "start", "startsAt")
        end = self._record_time(occurrence, "end", "endsAt")
        return {
            "id": occurrence_id,
            "kind": "calendar",
            "title": occurrence.get("title") or "Untitled meeting",
            "start": format_time(start),
            "end": format_time(end),
            "tentative": occurrence.get("tentative"),
            "eligible": occurrence.get("eligible"),
            "related": {},
            "coverage": "partial",
            "provenance": {"type": "calendar_cache", "source": "MeetingReminders/state.json", "record_id": occurrence.get("id")},
            "warning": "Calendar cache does not prove attendance.",
        }

    def _fragment_item(self, fragment: Fragment) -> dict[str, Any]:
        record = fragment.record
        fragment_id = stable_id("fragment", "file", fragment.provenance)
        at = self._record_time(record, "at")
        return {
            "id": fragment_id,
            "kind": "transcript_fragment",
            "title": record.get("meetingTitle") or "Transcript fragment",
            "at": format_time(at),
            "line_count": len(fragment.lines),
            "related": {},
            "coverage": "partial",
            "provenance": {"type": "transcript_fragment", **fragment.provenance},
            "warning": "Observed journal window; completeness is not guaranteed.",
        }

    def _note_item(self, note: dict[str, Any]) -> dict[str, Any]:
        session_id = note.get("session_id")
        item_id = self._session_file_id(session_id) or stable_id("session", "file", note)
        updated = self._record_time(note, "updated_at", "updatedAt")
        return {
            "id": item_id,
            "kind": "note",
            "title": note.get("meeting_title") or note.get("meetingTitle") or "Untitled meeting",
            "updated_at": format_time(updated),
            "has_notes": True,
            "related": {},
            "coverage": "complete",
            "provenance": {"type": "meeting_library", "source": "MeetingLibrary/notes.json",
                           "record_id": session_id if isinstance(session_id, str) else None},
        }

    def list_meetings(self, args: dict[str, Any]) -> dict[str, Any]:
        start = parse_time(args.get("from"), "from")
        end = parse_time(args.get("to"), "to")
        query = args.get("query")
        if query is not None and not isinstance(query, str):
            raise MCPError("INVALID_ARGUMENT", "query must be a string.", details={"field": "query", "reason": "type"})
        if isinstance(query, str):
            # The query filter is trimmed; a whitespace-only value is ignored.
            query = query.strip() or None
        kinds = args.get("kind")
        if kinds is None:
            selected = {"calendar", "outcome", "note", "transcript_fragment"}
        else:
            if not isinstance(kinds, str):
                raise MCPError("INVALID_ARGUMENT", "kind must be a string.")
            selected = {kinds}
            unsupported = selected - {"calendar", "outcome", "note", "transcript_fragment"}
            if unsupported:
                raise MCPError("CAPABILITY_UNAVAILABLE", f"Offline profile does not support kind: {sorted(unsupported)[0]}")
        limit = clamp_limit(args.get("limit"))
        filters = {"from": format_time(start), "to": format_time(end), "query": query, "kind": sorted(selected)}
        snapshot, offset = self._decode_cursor(args.get("cursor"), "meetings", filters)
        items: list[dict[str, Any]] = []
        if "calendar" in selected:
            for occurrence in snapshot.occurrences:
                item = self._occurrence_item(snapshot, occurrence)
                item_time = parse_time(item.get("start"), "start")
                if not self._in_range(item_time, start, end):
                    continue
                if query and query.casefold() not in str(item["title"]).casefold():
                    continue
                items.append(item)
        if "outcome" in selected:
            for outcome in snapshot.outcomes:
                item = self._outcome_item(snapshot, outcome)
                item_time = parse_time(item.get("ended_at"), "ended_at")
                if not self._in_range(item_time, start, end):
                    continue
                if query and query.casefold() not in (str(item["title"]) + " " + str(item["summary"])).casefold():
                    continue
                items.append(item)
        if "note" in selected:
            for note in snapshot.notes:
                item = self._note_item(note)
                item_time = parse_time(item.get("updated_at"), "updated_at")
                if not self._in_range(item_time, start, end):
                    continue
                if query and query.casefold() not in str(item["title"]).casefold():
                    continue
                items.append(item)
        if "transcript_fragment" in selected:
            for fragment in snapshot.fragments:
                item = self._fragment_item(fragment)
                item_time = parse_time(item.get("at"), "at")
                if not self._in_range(item_time, start, end):
                    continue
                if query and query.casefold() not in str(item["title"]).casefold():
                    continue
                items.append(item)
        items.sort(key=lambda item: (str(item.get("ended_at") or item.get("start") or item.get("at") or item.get("updated_at") or ""), item["id"]))
        return self._page(snapshot, "meetings", filters, offset, limit, items)

    def _find_outcome(self, snapshot: Snapshot, outcome_id: str) -> dict[str, Any]:
        for outcome in snapshot.outcomes:
            if stable_id("outcome", "file", outcome.get("id") or outcome) == outcome_id:
                return outcome
        raise MCPError("OUTCOME_NOT_FOUND", "The requested outcome is unavailable.")

    def get_meeting(self, args: dict[str, Any]) -> dict[str, Any]:
        meeting_id = args.get("meeting_id")
        if not isinstance(meeting_id, str) or not meeting_id:
            raise MCPError("INVALID_ARGUMENT", "meeting_id is required.")
        snapshot = self.load_snapshot()
        for occurrence in snapshot.occurrences:
            item = self._occurrence_item(snapshot, occurrence)
            if item["id"] == meeting_id:
                return {**item, "observed_at": snapshot.created_at, "sources": snapshot.source_provenance(), "warnings": [item["warning"]]}
        for fragment in snapshot.fragments:
            item = self._fragment_item(fragment)
            if item["id"] == meeting_id:
                return {**item, "observed_at": snapshot.created_at, "sources": snapshot.source_provenance(), "warnings": [item["warning"]]}
        if meeting_id.startswith("outcome:"):
            outcome = self._find_outcome(snapshot, meeting_id)
            item = self._outcome_item(snapshot, outcome)
            tasks = outcome.get("tasks") if isinstance(outcome.get("tasks"), list) else []
            return {
                **item,
                "decisions": outcome.get("decisions") if isinstance(outcome.get("decisions"), list) else [],
                "open_questions": outcome.get("openQuestions") if isinstance(outcome.get("openQuestions"), list) else [],
                "task_ids": [stable_id("task", "file", task.get("id") if isinstance(task, dict) and task.get("id") else f"{meeting_id}:{index}:{(task or {}).get('text', '')}") for index, task in enumerate(tasks)],
                "observed_at": snapshot.created_at,
                "sources": snapshot.source_provenance(),
                "warnings": [],
            }
        if meeting_id.startswith("session:"):
            note = self._find_note(snapshot, meeting_id)
            item = self._note_item(note)
            return {**item, "observed_at": snapshot.created_at,
                    "sources": snapshot.source_provenance(), "warnings": []}
        raise MCPError("MEETING_NOT_FOUND", "The requested meeting is unavailable.")

    def get_transcript(self, args: dict[str, Any]) -> dict[str, Any]:
        meeting_id = args.get("meeting_id")
        if not isinstance(meeting_id, str) or not meeting_id:
            raise MCPError("INVALID_ARGUMENT", "meeting_id is required.")
        start = parse_time(args.get("from"), "from")
        end = parse_time(args.get("to"), "to")
        limit = clamp_limit(args.get("limit"))
        filters = {"meeting_id": meeting_id, "from": format_time(start), "to": format_time(end)}
        snapshot, offset = self._decode_cursor(args.get("cursor"), "transcript", filters)
        fragment = next((candidate for candidate in snapshot.fragments if self._fragment_item(candidate)["id"] == meeting_id), None)
        if fragment is None:
            raise MCPError("TRANSCRIPT_UNAVAILABLE", "No transcript fragment exists for this meeting ID.")
        utterances: list[dict[str, Any]] = []
        seen: set[str] = set()
        for line in fragment.lines:
            line_id = line.get("id")
            identity = line_id if isinstance(line_id, str) and line_id else json.dumps(line, sort_keys=True, ensure_ascii=False)
            if identity in seen:
                continue
            seen.add(identity)
            at = self._record_time(line, "at")
            if not self._in_range(at, start, end):
                continue
            utterances.append({
                "id": stable_id("utterance", "file", identity),
                "speaker": line.get("speaker"),
                "text": line.get("text") or "",
                "at": format_time(at),
                "is_you": line.get("isYou"),
                "mentions_you": line.get("mentionsYou"),
                "provenance": {"type": "transcript_fragment", **fragment.provenance},
            })
        utterances.sort(key=lambda item: (str(item.get("at") or ""), item["id"]))
        selected = utterances[offset:]
        page: list[dict[str, Any]] = []
        total_bytes = json_size({"coverage": "partial", "sources": [], "warnings": []})
        for utterance in selected:
            if len(page) >= limit or total_bytes + json_size(utterance) > TRANSCRIPT_BYTES:
                break
            page.append(utterance)
            total_bytes += json_size(utterance)
        next_offset = offset + len(page)
        result = self._page(snapshot, "transcript", filters, offset, limit if len(page) < limit else limit, utterances)
        result["items"] = page
        result["next_cursor"] = self._cursor(snapshot.id, "transcript", filters, next_offset) if next_offset < len(utterances) else None
        result["coverage"] = "partial"
        return result

    def get_outcome(self, args: dict[str, Any]) -> dict[str, Any]:
        outcome_id = args.get("outcome_id")
        if not isinstance(outcome_id, str) or not outcome_id:
            raise MCPError("INVALID_ARGUMENT", "outcome_id is required.")
        snapshot = self.load_snapshot()
        outcome = self._find_outcome(snapshot, outcome_id)
        tasks = outcome.get("tasks") if isinstance(outcome.get("tasks"), list) else []
        clean_tasks = []
        for index, task in enumerate(tasks):
            if not isinstance(task, dict):
                continue
            task_id = stable_id("task", "file", task.get("id") or f"{outcome_id}:{index}:{task.get('text', '')}")
            clean_tasks.append({
                "id": task_id,
                "text": task.get("text") or "",
                "owner": task.get("owner") or "",
                "done": bool(task.get("done")),
                "due_at": format_time(self._record_time(task, "dueAt", "due_at")),
                "reminder_at": format_time(self._record_time(task, "reminderAt", "reminder_at")),
                "meeting_id": outcome_id,
                "provenance": {"type": "task", "source": "assistant.json", "record_id": task.get("id")},
            })
        return {
            "id": outcome_id,
            "meeting_title": outcome.get("meetingTitle") or "",
            "ended_at": format_time(self._record_time(outcome, "endedAt", "ended_at")),
            "summary": outcome.get("summary") or "",
            "decisions": outcome.get("decisions") if isinstance(outcome.get("decisions"), list) else [],
            "open_questions": outcome.get("openQuestions") if isinstance(outcome.get("openQuestions"), list) else [],
            "tasks": clean_tasks,
            "observed_at": snapshot.created_at,
            "coverage": "complete",
            "sources": snapshot.source_provenance(),
            "warnings": [],
        }

    def get_notes(self, args: dict[str, Any]) -> dict[str, Any]:
        meeting_id = args.get("meeting_id")
        if not isinstance(meeting_id, str) or not meeting_id:
            raise MCPError("INVALID_ARGUMENT", "meeting_id is required.")
        snapshot = self.load_snapshot()
        note = self._find_note(snapshot, meeting_id)
        session_id = note.get("session_id")
        item = self._note_item(note)
        markdown = note.get("markdown") if isinstance(note.get("markdown"), str) else ""
        if not markdown:
            return {
                "meeting_id": item["id"], "note": None, "has_notes": False,
                "meeting_title": item["title"],
                "coverage": "complete", "warnings": ["This meeting has no saved note."],
                "observed_at": snapshot.created_at,
            }
        encoded = markdown.encode("utf-8")
        truncated = len(encoded) > NOTES_BYTES
        if truncated:
            markdown = encoded[:NOTES_BYTES].decode("utf-8", errors="ignore")
        return {
            "meeting_id": item["id"], "note_id": self._note_record_id(note), "has_notes": True,
            "revision": note.get("revision") if isinstance(note.get("revision"), int) else None,
            "updated_at": item["updated_at"],
            "provenance": {"type": "personal_note", "record_id": session_id if isinstance(session_id, str) else None},
            "coverage": "partial" if truncated else "complete",
            "warnings": ["Note exceeds the 12 KB inline cap; content is truncated."] if truncated else [],
            "markdown": markdown,
            "meeting_title": item["title"],
            "observed_at": snapshot.created_at,
        }

    def list_tasks(self, args: dict[str, Any]) -> dict[str, Any]:
        meeting_id = args.get("meeting_id")
        if meeting_id is not None and not isinstance(meeting_id, str):
            raise MCPError("INVALID_ARGUMENT", "meeting_id must be a string.")
        done = parse_bool(args.get("done"), "done")
        owner = args.get("owner")
        if owner is not None and not isinstance(owner, str):
            raise MCPError("INVALID_ARGUMENT", "owner must be a string.")
        limit = clamp_limit(args.get("limit"))
        filters = {"meeting_id": meeting_id, "done": done, "owner": owner}
        snapshot, offset = self._decode_cursor(args.get("cursor"), "tasks", filters)
        tasks: list[dict[str, Any]] = []
        for outcome in snapshot.outcomes:
            outcome_id = stable_id("outcome", "file", outcome.get("id") or outcome)
            if meeting_id is not None and meeting_id != outcome_id:
                continue
            raw_tasks = outcome.get("tasks") if isinstance(outcome.get("tasks"), list) else []
            for index, task in enumerate(raw_tasks):
                if not isinstance(task, dict):
                    continue
                if done is not None and bool(task.get("done")) != done:
                    continue
                task_owner = task.get("owner") or ""
                if owner is not None and owner.casefold() not in task_owner.casefold():
                    continue
                tasks.append({
                    "id": stable_id("task", "file", task.get("id") or f"{outcome_id}:{index}:{task.get('text', '')}"),
                    "text": task.get("text") or "",
                    "owner": task_owner,
                    "done": bool(task.get("done")),
                    "due_at": format_time(self._record_time(task, "dueAt", "due_at")),
                    "reminder_at": format_time(self._record_time(task, "reminderAt", "reminder_at")),
                    "meeting_id": outcome_id,
                    "provenance": {"type": "task", "source": "assistant.json", "record_id": task.get("id")},
                })
        tasks.sort(key=lambda item: (str(item.get("due_at") or ""), item["id"]))
        return self._page(snapshot, "tasks", filters, offset, limit, tasks)

    def search(self, args: dict[str, Any]) -> dict[str, Any]:
        query = args.get("query")
        if not isinstance(query, str) or not query.strip():
            raise MCPError("INVALID_ARGUMENT", "query must be non-empty after trimming.", details={"field": "query", "reason": "empty"})
        query = query.strip()
        start = parse_time(args.get("from"), "from")
        end = parse_time(args.get("to"), "to")
        types = args.get("types")
        if types is None:
            selected = {"meeting", "outcome", "task", "transcript", "note"}
        else:
            if not isinstance(types, list) or not all(isinstance(item, str) for item in types):
                raise MCPError("INVALID_ARGUMENT", "types must be an array of strings.")
            selected = set(types) & {"meeting", "outcome", "task", "transcript", "note"}
        needle = query.casefold()
        limit = clamp_limit(args.get("limit"))
        filters = {"query": query, "from": format_time(start), "to": format_time(end), "types": sorted(selected)}
        snapshot, offset = self._decode_cursor(args.get("cursor"), "search", filters)
        results: list[dict[str, Any]] = []
        if "meeting" in selected:
            for occurrence in snapshot.occurrences:
                item = self._occurrence_item(snapshot, occurrence)
                if needle in str(item["title"]).casefold() and self._in_range(parse_time(item.get("start"), "start"), start, end):
                    results.append({"type": "meeting", "meeting": item, "matched_field": "title"})
        if "outcome" in selected:
            for outcome in snapshot.outcomes:
                item = self._outcome_item(snapshot, outcome)
                haystack = f"{item['title']} {item['summary']}"
                if needle in haystack.casefold() and self._in_range(parse_time(item.get("ended_at"), "ended_at"), start, end):
                    results.append({"type": "outcome", "meeting": item, "matched_field": "title_or_summary"})
        if "task" in selected:
            for outcome in snapshot.outcomes:
                outcome_id = stable_id("outcome", "file", outcome.get("id") or outcome)
                raw_tasks = outcome.get("tasks") if isinstance(outcome.get("tasks"), list) else []
                for index, task in enumerate(raw_tasks):
                    if isinstance(task, dict) and needle in str(task.get("text") or "").casefold():
                        results.append({"type": "task", "task": {
                            "id": stable_id("task", "file", task.get("id") or f"{outcome_id}:{index}:{task.get('text', '')}"),
                            "text": task.get("text") or "",
                            "owner": task.get("owner") or "",
                            "done": bool(task.get("done")),
                            "meeting_id": outcome_id,
                        }, "matched_field": "text"})
        if "transcript" in selected:
            for fragment in snapshot.fragments:
                item = self._fragment_item(fragment)
                if not self._in_range(parse_time(item.get("at"), "at"), start, end):
                    continue
                for line in fragment.lines:
                    if isinstance(line, dict) and needle in str(line.get("text") or "").casefold():
                        results.append({"type": "transcript", "meeting": item, "utterance": {
                            "speaker": line.get("speaker"), "text": line.get("text") or "",
                            "at": format_time(self._record_time(line, "at")),
                            "provenance": {"type": "transcript_fragment", **fragment.provenance},
                        }, "matched_field": "text"})
        if "note" in selected:
            for note in snapshot.notes:
                markdown = note.get("markdown") if isinstance(note.get("markdown"), str) else ""
                if needle not in markdown.casefold():
                    continue
                item = self._note_item(note)
                if not self._in_range(parse_time(item.get("updated_at"), "updated_at"), start, end):
                    continue
                results.append({"type": "note",
                                "meeting": {"id": item["id"], "title": item["title"], "has_notes": True,
                                            "provenance": item["provenance"]},
                                "note": {"id": self._note_record_id(note),
                                         "revision": note.get("revision") if isinstance(note.get("revision"), int) else None,
                                         "excerpt": markdown[:400]},
                                "matched_field": "note"})
        results.sort(key=lambda item: (item["type"], str((item.get("meeting") or item.get("task") or {}).get("id") or "")))
        return self._page(snapshot, "search", filters, offset, limit, results)

    def call_tool(self, name: str, args: dict[str, Any]) -> Any:
        if not isinstance(args, dict):
            raise MCPError("INVALID_ARGUMENT", "Tool arguments must be an object.", details={"field": "arguments", "reason": "type"})
        tools = {
            "rocknroll_status": self.source_status,
            "rocknroll_list_meetings": self.list_meetings,
            "rocknroll_get_meeting": self.get_meeting,
            "rocknroll_get_transcript": self.get_transcript,
            "rocknroll_get_outcome": self.get_outcome,
            "rocknroll_get_notes": self.get_notes,
            "rocknroll_list_tasks": self.list_tasks,
            "rocknroll_search": self.search,
        }
        handler = tools.get(name)
        if handler is None:
            raise MCPError("CAPABILITY_UNAVAILABLE", f"Unsupported tool: {name}")
        # Structural validation runs before any handler, mirroring the native profile.
        validate_arguments(name, args)
        return redact(handler(args))


def _invalid(field: str, reason: str, message: str) -> None:
    raise MCPError("INVALID_ARGUMENT", message, details={"field": field, "reason": reason})


def _validate_value(value: Any, prop: dict[str, Any], field: str) -> None:
    if value is None:
        _invalid(field, "null", f"{field} must not be null.")
    type_ = prop.get("type")
    if type_ == "string":
        if not isinstance(value, str):
            _invalid(field, "type", f"{field} must be a string.")
        if prop.get("minLength") and len(value) < prop["minLength"]:
            _invalid(field, "empty", f"{field} must not be empty.")
        if "enum" in prop and value not in prop["enum"]:
            _invalid(field, "enum", f"{field} must be one of: {', '.join(prop['enum'])}.")
    elif type_ == "boolean":
        if not isinstance(value, bool):
            _invalid(field, "type", f"{field} must be a boolean.")
    elif type_ == "integer":
        if not isinstance(value, int) or isinstance(value, bool):
            _invalid(field, "type", f"{field} must be an integer.")
        if "minimum" in prop and value < prop["minimum"]:
            _invalid(field, "range", f"{field} must be at least {prop['minimum']}.")
        if "maximum" in prop and value > prop["maximum"]:
            _invalid(field, "range", f"{field} must be at most {prop['maximum']}.")
    elif type_ == "array":
        if not isinstance(value, list):
            _invalid(field, "type", f"{field} must be an array.")
        item_prop = prop.get("items")
        if item_prop:
            for index, item in enumerate(value):
                _validate_value(item, item_prop, f"{field}[{index}]")


def validate_arguments(tool: str, args: dict[str, Any]) -> None:
    """Enforce the published inputSchema before dispatch (native parity)."""
    schemas = {item["name"]: item["inputSchema"] for item in offline_tools()}
    schema = schemas.get(tool)
    if schema is None:
        raise MCPError("CAPABILITY_UNAVAILABLE", f"Unsupported tool: {tool}")
    properties = schema.get("properties", {})
    for field in schema.get("required", []):
        if field not in args:
            _invalid(field, "required", f"{field} is required.")
    for field, value in args.items():
        prop = properties.get(field)
        if prop is None:
            _invalid(field, "unknown_field", f"Unknown argument: {field}.")
        _validate_value(value, prop, field)
    if "from" in properties and "to" in properties and args.get("from") is not None and args.get("to") is not None:
        start = parse_time(args["from"], "from")
        end = parse_time(args["to"], "to")
        if start and end and start >= end:
            _invalid("from", "range", "from must be earlier than to.")


def tool_schema(name: str, description: str, properties: dict[str, Any], required: list[str] | None = None) -> dict[str, Any]:
    return {
        "name": name,
        "description": description,
        "inputSchema": {
            "type": "object",
            "properties": properties,
            "required": required or [],
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": True, "destructiveHint": False},
    }


def offline_tools() -> list[dict[str, Any]]:
    time_filter = {
        "from": {"type": "string", "format": "date-time", "description": "RFC 3339 lower time bound; a time-zone offset or Z is required. When both bounds are given, from must be earlier than to."},
        "to": {"type": "string", "format": "date-time", "description": "RFC 3339 exclusive upper time bound; a time-zone offset or Z is required."},
    }
    pagination = {
        "limit": {"type": "integer", "minimum": 1, "maximum": MAX_LIMIT, "default": DEFAULT_LIMIT, "description": f"Maximum number of items to return; values outside 1...{MAX_LIMIT} are rejected. Defaults to {DEFAULT_LIMIT}."},
        "cursor": {"type": "string", "description": "Opaque page cursor copied verbatim from a previous response's next_cursor."},
    }
    meeting_id = {"meeting_id": {"type": "string", "minLength": 1, "description": "Opaque cached record identifier: the id of an item returned by rocknroll_list_meetings or rocknroll_search — never a meeting title."}}
    return [
        tool_schema("rocknroll_status", "Report offline sources, capabilities and limitations.", {}),
        tool_schema("rocknroll_list_meetings", "List cached calendar meetings, outcomes, notes and transcript fragments.",
                    {**time_filter,
                     "query": {"type": "string", "description": "Optional case-insensitive substring filter over titles and summaries; the value is trimmed and a whitespace-only filter is ignored."},
                     "kind": {"type": "string", "enum": ["calendar", "outcome", "note", "transcript_fragment"], "description": "Restrict results to one cached kind; defaults to all four."},
                     **pagination}),
        tool_schema("rocknroll_get_meeting", "Get one cached meeting-like record.", dict(meeting_id), ["meeting_id"]),
        tool_schema("rocknroll_get_transcript", "Get observed transcript fragments with explicit partial coverage.",
                    {**meeting_id, **time_filter, **pagination}, ["meeting_id"]),
        tool_schema("rocknroll_get_outcome", "Get one stored meeting outcome by outcome ID.",
                    {"outcome_id": {"type": "string", "minLength": 1, "description": "Opaque outcome identifier: the id of a kind:outcome item from rocknroll_list_meetings or an outcome result from rocknroll_search. This is not a meeting_id."}},
                    ["outcome_id"]),
        tool_schema("rocknroll_get_notes", "Get the raw Markdown note for one meeting by a persisted session ID. Notes are user-authored personal records; they are attributed separately from outcomes and transcripts. Never a write: this tool changes nothing.",
                    {"meeting_id": {"type": "string", "minLength": 1, "description": "Opaque meeting identifier: an id returned by rocknroll_list_meetings or rocknroll_search. Must identify a persisted note session (id starts with session:)."}},
                    ["meeting_id"]),
        tool_schema("rocknroll_list_tasks", "List stored tasks with optional meeting, owner and completion filters.",
                    {**meeting_id,
                     "done": {"type": "boolean", "description": "Filter by completion state."},
                     "owner": {"type": "string", "description": "Case-insensitive substring match on the task owner."},
                     **pagination}),
        tool_schema("rocknroll_search", "Search meeting titles, outcomes, tasks, note Markdown and observed transcript fragments.",
                    {"query": {"type": "string", "minLength": 1, "description": "Case-insensitive search text, trimmed; must be non-empty after trimming."},
                     "types": {"type": "array", "items": {"type": "string", "enum": ["meeting", "outcome", "task", "transcript", "note"]}, "description": "Result types to search; defaults to all five. Unknown values are rejected."},
                     **time_filter, **pagination}, ["query"]),
    ]


class MCPServer:
    def __init__(self, backend: OfflineRocknrollBackend):
        self.backend = backend

    def handle(self, request: dict[str, Any]) -> dict[str, Any] | None:
        method = request.get("method")
        request_id = request.get("id")
        if method in {"notifications/initialized", "notifications/cancelled", "notifications/progress"}:
            return None
        try:
            if method == "initialize":
                result = {
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": {"name": "rocknroll-local", "version": SERVER_VERSION},
                }
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": offline_tools()}
            elif method == "tools/call":
                params = request.get("params")
                if not isinstance(params, dict) or not isinstance(params.get("name"), str):
                    raise MCPError("INVALID_ARGUMENT", "tools/call requires a tool name.")
                try:
                    payload = self.backend.call_tool(params["name"], params.get("arguments") or {})
                    result = {"content": [{"type": "text", "text": json.dumps(payload, ensure_ascii=False)}], "isError": False}
                except MCPError as exc:
                    result = {"content": [{"type": "text", "text": json.dumps({"error": exc.envelope()}, ensure_ascii=False)}], "isError": True}
            else:
                return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": f"Method not found: {method}"}}
            return {"jsonrpc": "2.0", "id": request_id, "result": result}
        except MCPError as exc:
            return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32602, "message": exc.message, "data": exc.envelope()}}
        except Exception as exc:  # Keep protocol failures safe and structured.
            return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32603, "message": "Internal error", "data": {"code": "INTERNAL_ERROR", "message": str(exc), "retryable": False, "details": {}}}}


def default_data_root() -> pathlib.Path:
    override = os.environ.get("ROCKNROLL_DATA_ROOT")
    if override:
        return pathlib.Path(override)
    return pathlib.Path.home() / DEFAULT_RELATIVE_ROOT


def doctor(backend: OfflineRocknrollBackend) -> int:
    status = backend.source_status()
    issues = []
    if not pathlib.Path(status["data_root"]).exists():
        issues.append({"code": "SOURCE_NOT_FOUND", "path": status["data_root"], "action": "Install or select the Rock'N'Roll data root."})
    for source in status["sources"]:
        if not source["available"]:
            issues.append({"code": source.get("schema") if source.get("schema") else "SOURCE_NOT_FOUND", "path": source["path"], "action": source.get("modified_at") or "Check file access."})
    print(json.dumps({"backend": "offline", "issues": issues, "categories": status["categories"], "data_root": status["data_root"]}, indent=2, ensure_ascii=False))
    return 0 if not issues else 1


def serve(stdin: Iterable[str], stdout) -> None:
    backend = OfflineRocknrollBackend(default_data_root())
    server = MCPServer(backend)
    for line in stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            response = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}
        else:
            response = server.handle(request)
        if response is not None:
            stdout.write(json.dumps(response, ensure_ascii=False, separators=(",", ":")) + "\n")
            stdout.flush()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Rock'N'Roll offline MCP server")
    parser.add_argument("--data-root", type=pathlib.Path, default=None, help="Override the application-support root.")
    parser.add_argument("--doctor", action="store_true", help="Diagnose sources without printing meeting content.")
    args = parser.parse_args(argv)
    root = (args.data_root or default_data_root()).expanduser().resolve()
    backend = OfflineRocknrollBackend(root)
    if args.doctor:
        return doctor(backend)
    serve(sys.stdin, sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
