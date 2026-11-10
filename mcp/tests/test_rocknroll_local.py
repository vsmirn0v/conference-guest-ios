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


if __name__ == "__main__":
    unittest.main()
