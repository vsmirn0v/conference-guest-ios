from __future__ import annotations

import copy
import importlib.util
import json
import pathlib
import shutil
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "mcp" / "rocknroll_local.py"
SPEC = importlib.util.spec_from_file_location("rocknroll_local", MODULE_PATH)
assert SPEC and SPEC.loader
rocknroll_local = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = rocknroll_local
SPEC.loader.exec_module(rocknroll_local)


class OfflineBackendTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = ROOT / "mcp" / "fixtures"
        self.temp = pathlib.Path(tempfile.mkdtemp(prefix="rocknroll-mcp-test-"))
        self.root = self.temp / "data"
        shutil.copytree(self.fixture, self.root)
        self.backend = rocknroll_local.OfflineRocknrollBackend(self.root)

    def tearDown(self) -> None:
        shutil.rmtree(self.temp)

    def test_status_reports_partial_offline_capabilities(self) -> None:
        status = self.backend.source_status()
        self.assertEqual(status["backend"], "offline")
        self.assertTrue(status["categories"]["outcomes"])
        self.assertTrue(status["categories"]["calendar"])
        self.assertTrue(status["categories"]["transcript_fragments"])
        self.assertFalse(status["capabilities"]["assistant"])
        self.assertEqual(status["capabilities"]["kinds"], ["calendar", "outcome", "transcript_fragment"])

    def test_list_meetings_keeps_same_title_records_separate(self) -> None:
        result = self.backend.list_meetings({"kind": "outcome"})
        titles = [item["title"] for item in result["items"]]
        self.assertEqual(titles.count("Design Sync"), 2)
        self.assertEqual(len({item["id"] for item in result["items"]}), 2)
        self.assertNotIn("invitation", json.dumps(result))

    def test_list_meetings_uses_half_open_range(self) -> None:
        result = self.backend.list_meetings({
            "kind": "calendar",
            "from": "2026-11-09T11:00:00+03:00",
            "to": "2026-11-09T12:00:00+03:00",
        })
        self.assertEqual([item["title"] for item in result["items"]], ["Design Sync"])

    def test_get_outcome_returns_verbatim_tasks_and_redacts_invitation(self) -> None:
        meetings = self.backend.list_meetings({"kind": "outcome"})["items"]
        outcome_id = next(item["id"] for item in meetings if item["ended_at"] == "2026-11-09T10:00:00+03:00")
        outcome = self.backend.get_outcome({"outcome_id": outcome_id})
        self.assertEqual(outcome["summary"], "Reviewed the launch plan and assigned follow-up work.")
        self.assertEqual(outcome["decisions"], ["Ship the beta on Friday", "Use the new onboarding copy"])
        self.assertEqual(len(outcome["tasks"]), 2)
        serialized = json.dumps(outcome)
        self.assertNotIn("secret-calendar", serialized)
        self.assertNotIn("invitation", serialized)

    def test_get_transcript_marks_partial_and_deduplicates_by_line_identity(self) -> None:
        fragments = self.backend.list_meetings({"kind": "transcript_fragment"})["items"]
        complete = [item for item in fragments if item["line_count"] > 0]
        self.assertEqual(len(complete), 2)
        result = self.backend.get_transcript({"meeting_id": complete[0]["id"]})
        self.assertEqual(result["coverage"], "partial")
        texts = [item["text"] for item in result["items"]]
        self.assertEqual(texts.count("Can you review it before lunch?"), 1)
        self.assertTrue(all("provenance" in item for item in result["items"]))

    def test_search_finds_tasks_and_transcripts(self) -> None:
        result = self.backend.search({"query": "release notes", "types": ["task"]})
        self.assertEqual(len(result["items"]), 1)
        self.assertEqual(result["items"][0]["task"]["owner"], "Ana")
        transcript = self.backend.search({"query": "lunch", "types": ["transcript"]})
        self.assertGreaterEqual(len(transcript["items"]), 1)
        self.assertEqual(transcript["items"][0]["utterance"]["speaker"], "Max")

    def test_pagination_is_snapshot_consistent(self) -> None:
        first = self.backend.list_meetings({"kind": "outcome", "limit": 1})
        self.assertEqual(len(first["items"]), 1)
        self.assertIsNotNone(first["next_cursor"])
        second = self.backend.list_meetings({"kind": "outcome", "limit": 10, "cursor": first["next_cursor"]})
        self.assertEqual(len(second["items"]), 1)
        self.assertNotEqual(first["items"][0]["id"], second["items"][0]["id"])
        with self.assertRaises(rocknroll_local.MCPError) as caught:
            self.backend.list_meetings({"kind": "calendar", "cursor": first["next_cursor"]})
        self.assertEqual(caught.exception.code, "CURSOR_EXPIRED")

    def test_sources_are_read_only_and_path_traversal_fails(self) -> None:
        before = (self.root / "Attention" / "assistant.json").read_bytes()
        self.backend.list_meetings({})
        self.assertEqual((self.root / "Attention" / "assistant.json").read_bytes(), before)
        with self.assertRaises(rocknroll_local.MCPError) as caught:
            self.backend.source_path("../outside.json")
        self.assertEqual(caught.exception.code, "ACCESS_DENIED")

    def test_missing_and_corrupt_sources_have_distinct_errors(self) -> None:
        missing = rocknroll_local.OfflineRocknrollBackend(self.temp / "missing")
        self.assertFalse(missing.source_status()["categories"]["outcomes"])
        corrupt_root = self.temp / "corrupt"
        shutil.copytree(self.fixture, corrupt_root)
        (corrupt_root / "Attention" / "assistant.json").write_text("{not-json", encoding="utf-8")
        corrupt = rocknroll_local.OfflineRocknrollBackend(corrupt_root)
        status = corrupt.source_status()
        assistant = next(source for source in status["sources"] if source["type"] == "assistant")
        self.assertEqual(assistant["available"], True)
        self.assertIsNone(assistant["schema"])


class ProtocolTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = ROOT / "mcp" / "fixtures"
        self.temp = pathlib.Path(tempfile.mkdtemp(prefix="rocknroll-mcp-protocol-"))
        self.root = self.temp / "data"
        shutil.copytree(self.fixture, self.root)
        self.server = rocknroll_local.MCPServer(rocknroll_local.OfflineRocknrollBackend(self.root))

    def tearDown(self) -> None:
        shutil.rmtree(self.temp)

    def request(self, method: str, params=None, identifier=1):
        message = {"jsonrpc": "2.0", "id": identifier, "method": method}
        if params is not None:
            message["params"] = params
        return self.server.handle(message)

    def test_initialize_and_tools_list(self) -> None:
        initialized = self.request("initialize", {"protocolVersion": rocknroll_local.PROTOCOL_VERSION, "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}})
        self.assertEqual(initialized["result"]["serverInfo"]["name"], "rocknroll-local")
        tools = self.request("tools/list")
        names = {tool["name"] for tool in tools["result"]["tools"]}
        self.assertEqual(names, {
            "rocknroll_status", "rocknroll_list_meetings", "rocknroll_get_meeting",
            "rocknroll_get_transcript", "rocknroll_get_outcome", "rocknroll_list_tasks",
            "rocknroll_search",
        })
        self.assertTrue(all(tool["annotations"]["readOnlyHint"] for tool in tools["result"]["tools"]))

    def test_tools_call_returns_structured_tool_errors(self) -> None:
        response = self.request("tools/call", {"name": "rocknroll_get_outcome", "arguments": {}})
        self.assertTrue(response["result"]["isError"])
        payload = json.loads(response["result"]["content"][0]["text"])
        self.assertEqual(payload["error"]["code"], "INVALID_ARGUMENT")

    def test_read_tool_returns_success_envelope(self) -> None:
        response = self.request("tools/call", {"name": "rocknroll_list_tasks", "arguments": {"done": False}})
        self.assertFalse(response["result"]["isError"])
        payload = json.loads(response["result"]["content"][0]["text"])
        self.assertEqual(len(payload["items"]), 1)
        self.assertEqual(payload["items"][0]["text"], "Publish release notes")

    def test_notification_gets_no_response(self) -> None:
        self.assertIsNone(self.server.handle({"jsonrpc": "2.0", "method": "notifications/initialized"}))


class SchemaContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = ROOT / "mcp" / "fixtures"
        self.temp = pathlib.Path(tempfile.mkdtemp(prefix="rocknroll-mcp-schema-"))
        self.root = self.temp / "data"
        shutil.copytree(self.fixture, self.root)
        self.server = rocknroll_local.MCPServer(rocknroll_local.OfflineRocknrollBackend(self.root))

    def tearDown(self) -> None:
        shutil.rmtree(self.temp)

    def request(self, name: str, arguments):
        return self.server.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                   "params": {"name": name, "arguments": arguments}})

    def error(self, response) -> dict:
        self.assertTrue(response["result"]["isError"], response)
        return json.loads(response["result"]["content"][0]["text"])["error"]

    def assert_invalid(self, response, field: str, reason: str) -> None:
        error = self.error(response)
        self.assertEqual(error["code"], "INVALID_ARGUMENT", error)
        self.assertEqual(error["details"], {"field": field, "reason": reason})

    def tools_by_name(self) -> dict:
        listed = self.server.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        return {tool["name"]: tool for tool in listed["result"]["tools"]}

    def test_catalog_publishes_described_closed_schemas(self) -> None:
        tools = self.tools_by_name()
        self.assertEqual(len(tools), 7)
        for name, tool in tools.items():
            schema = tool["inputSchema"]
            self.assertEqual(schema["type"], "object", name)
            self.assertFalse(schema["additionalProperties"], name)
            required = schema["required"]
            self.assertEqual(set(required) - set(schema["properties"]), set(), name)
            for field, prop in schema["properties"].items():
                self.assertTrue(prop.get("description"), f"{name}.{field} needs a description")

    def test_initialize_reports_bumped_version(self) -> None:
        initialized = self.server.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                          "params": {"protocolVersion": rocknroll_local.PROTOCOL_VERSION}})
        self.assertEqual(initialized["result"]["serverInfo"]["version"], "0.2.0")

    def test_unknown_fields_are_rejected_before_dispatch(self) -> None:
        self.assert_invalid(self.request("rocknroll_status", {"bogus": 1}), "bogus", "unknown_field")
        listed = self.request("rocknroll_list_meetings", {"kind": "outcome"})
        self.assertFalse(listed["result"]["isError"])

    def test_required_and_min_length_fields(self) -> None:
        self.assert_invalid(self.request("rocknroll_get_meeting", {}), "meeting_id", "required")
        self.assert_invalid(self.request("rocknroll_get_outcome", {}), "outcome_id", "required")
        self.assert_invalid(self.request("rocknroll_search", {}), "query", "required")
        self.assert_invalid(self.request("rocknroll_search", {"query": "   "}), "query", "empty")
        self.assert_invalid(self.request("rocknroll_get_meeting", {"meeting_id": ""}), "meeting_id", "empty")

    def test_types_are_strict_and_null_is_rejected(self) -> None:
        self.assert_invalid(self.request("rocknroll_list_tasks", {"done": "true"}), "done", "type")
        self.assert_invalid(self.request("rocknroll_list_tasks", {"done": 1}), "done", "type")
        self.assert_invalid(self.request("rocknroll_list_tasks", {"done": None}), "done", "null")
        self.assert_invalid(self.request("rocknroll_search", {"query": "x", "limit": "20"}), "limit", "type")
        self.assert_invalid(self.request("rocknroll_search", {"query": "x", "limit": True}), "limit", "type")

    def test_limit_bounds_are_enforced(self) -> None:
        self.assert_invalid(self.request("rocknroll_search", {"query": "x", "limit": 0}), "limit", "range")
        self.assert_invalid(self.request("rocknroll_search", {"query": "x", "limit": 101}), "limit", "range")
        ok = self.request("rocknroll_search", {"query": "x", "limit": 100})
        self.assertFalse(ok["result"]["isError"])

    def test_enums_are_enforced(self) -> None:
        self.assert_invalid(self.request("rocknroll_list_meetings", {"kind": "bogus"}), "kind", "enum")
        self.assert_invalid(self.request("rocknroll_search", {"query": "x", "types": ["bogus"]}), "types[0]", "enum")
        self.assert_invalid(self.request("rocknroll_search", {"query": "x", "types": [7]}), "types[0]", "type")

    def test_dates_require_offsets_and_ordering(self) -> None:
        self.assert_invalid(self.request("rocknroll_list_meetings", {"from": "2026-01-01T09:00:00"}), "from", "format")
        self.assert_invalid(self.request("rocknroll_list_meetings", {
            "from": "2026-02-01T09:00:00+03:00", "to": "2026-01-01T09:00:00+03:00",
        }), "from", "range")
        ok = self.request("rocknroll_list_meetings", {"from": "2026-01-01T00:00:00Z", "to": "2026-12-01T00:00:00+03:00"})
        self.assertFalse(ok["result"]["isError"])

    def test_whitespace_query_filter_is_ignored(self) -> None:
        ignored = json.loads(self.request("rocknroll_list_meetings", {"query": "   "})["result"]["content"][0]["text"])
        unfiltered = json.loads(self.request("rocknroll_list_meetings", {})["result"]["content"][0]["text"])
        self.assertEqual(ignored["items"], unfiltered["items"])


if __name__ == "__main__":
    unittest.main()
