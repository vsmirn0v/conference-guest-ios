#!/usr/bin/env python3
"""Small synthetic negative tests; never copy, fetch, or build a WebRTC tree."""
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import source_tools as tools

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("m155_manifest", HERE / "make-source-manifest.py")
manifest_tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest_tool)


class VerificationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="m155-verifier-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / "source"
        (self.source / "api").mkdir(parents=True)
        (self.source / "api/frame.cc").write_text("after\n")
        (self.source / "run.sh").write_text("#!/bin/sh\n")
        (self.source / "run.sh").chmod(0o755)
        (self.source / "alias").symlink_to("api/frame.cc")
        self.patch = self.root / "m155-port.patch"
        self.patch.write_text("locked fixture patch\n")
        (self.root / "DEPS").write_text("deps = {}\n")
        (self.root / "gclient.template").write_text("solutions = []\n")
        self.manifest = self.root / "source-manifest.json"
        self.write_manifest(tools.tree_entries(self.source))
        self.lock_path = self.root / "m155-lock.json"
        self.lock = {
            "schema_version": 1, "source_sha": tools.SOURCE_SHA,
            "source_archive_sha256": tools.ARCHIVE_SHA256,
            "patch": {"path": self.patch.name, "sha256": tools.digest(self.patch)},
            "source_manifest": {"path": self.manifest.name, "sha256": tools.digest(self.manifest)},
            "dependencies": {
                "deps": {"path": "DEPS", "sha256": tools.digest(self.root / "DEPS")},
                "gclient": {"path": "gclient.template", "sha256": tools.digest(self.root / "gclient.template")},
                "roots": ["third_party/fixture"],
            },
        }
        self.write_lock()

    def write_manifest(self, entries):
        self.manifest.write_text(json.dumps({
            "schema_version": 1, "source_sha": tools.SOURCE_SHA,
            "source_archive_sha256": tools.ARCHIVE_SHA256,
            "patch_sha256": tools.digest(self.patch), "entries": entries,
        }))

    def write_lock(self):
        self.lock_path.write_text(json.dumps(self.lock))

    def verify(self):
        return tools.verify(self.source, self.lock_path)

    def test_exact_content_and_git_metadata_pass(self):
        (self.source / ".git").mkdir()
        (self.source / ".git/index").write_text("not part of source identity\n")
        self.assertEqual(self.verify()["source_sha"], tools.SOURCE_SHA)

    def test_missing_source_fails(self):
        (self.source / "api/frame.cc").unlink()
        with self.assertRaisesRegex(ValueError, "missing=.*api/frame.cc"):
            self.verify()

    def test_changed_source_fails(self):
        (self.source / "api/frame.cc").write_text("tampered\n")
        with self.assertRaisesRegex(ValueError, "changed=.*api/frame.cc"):
            self.verify()

    def test_extra_source_fails_even_when_gitignored(self):
        (self.source / ".gitignore").write_text("*.cc\n")
        (self.source / "api/extra.cc").write_text("extra\n")
        with self.assertRaisesRegex(ValueError, "extra=.*api/extra.cc"):
            self.verify()

    def test_extra_empty_directory_fails(self):
        (self.source / "unexpected").mkdir()
        with self.assertRaisesRegex(ValueError, "extra=.*unexpected"):
            self.verify()

    def test_changed_executable_mode_fails(self):
        (self.source / "run.sh").chmod(0o644)
        with self.assertRaisesRegex(ValueError, "changed=.*run.sh"):
            self.verify()

    def test_changed_symlink_fails(self):
        (self.source / "alias").unlink()
        (self.source / "alias").symlink_to("run.sh")
        with self.assertRaisesRegex(ValueError, "changed=.*alias"):
            self.verify()

    def test_tampered_patch_fails(self):
        self.patch.write_bytes(self.patch.read_bytes() + b"\n")
        with self.assertRaisesRegex(ValueError, "Identity mismatch: cumulative patch"):
            self.verify()

    def test_missing_patch_fails(self):
        self.patch.unlink()
        with self.assertRaisesRegex(ValueError, "Missing or unsafe cumulative patch"):
            self.verify()

    def test_tampered_manifest_fails(self):
        self.manifest.write_bytes(self.manifest.read_bytes() + b"\n")
        with self.assertRaisesRegex(ValueError, "Identity mismatch: source manifest"):
            self.verify()

    def test_wrong_source_revision_fails(self):
        self.lock["source_sha"] = "0" * 40
        self.write_lock()
        with self.assertRaisesRegex(ValueError, "pinned pristine M155"):
            self.verify()

    def test_wrong_archive_identity_fails(self):
        self.lock["source_archive_sha256"] = "0" * 64
        self.write_lock()
        with self.assertRaisesRegex(ValueError, "pinned pristine M155"):
            self.verify()

    def test_exact_dependency_root_is_separate_but_siblings_fail(self):
        dependency = self.source / "third_party/fixture"
        dependency.mkdir(parents=True)
        (dependency / "dependency.cc").write_text("separate identity\n")
        self.verify()
        (dependency.parent / "unexpected.cc").write_text("not a locked dependency\n")
        with self.assertRaisesRegex(ValueError, "extra=.*third_party/unexpected.cc"):
            self.verify()

    def test_dependency_cannot_hide_locked_source(self):
        self.lock["dependencies"]["roots"] = ["api"]
        self.write_lock()
        with self.assertRaisesRegex(ValueError, "overlaps locked source"):
            self.verify()

    def test_dependency_container_keeps_locked_source_directory(self):
        self.lock["dependencies"]["roots"] = ["api/dependency"]
        self.write_lock()
        dependency = self.source / "api/dependency"
        dependency.mkdir()
        (dependency / "separate.cc").write_text("dependency\n")
        self.verify()

    def test_archive_and_patch_manifest_and_fresh_preparation(self):
        archive_path = self.root / "fixture.tar.gz"
        with tarfile.open(archive_path, "w:gz") as archive:
            for name, data, mode in [("api/frame.cc", b"before\n", 0o644),
                                     ("run.sh", b"#!/bin/sh\n", 0o755),
                                     ("unused.txt", b"remove\n", 0o644)]:
                member = tarfile.TarInfo(tools.ARCHIVE_ROOT + "/" + name)
                member.size, member.mode = len(data), mode
                archive.addfile(member, io.BytesIO(data))
            link = tarfile.TarInfo(tools.ARCHIVE_ROOT + "/alias")
            link.type, link.linkname = tarfile.SYMTYPE, "api/frame.cc"
            archive.addfile(link)
        self.patch.write_text("diff --git a/api/frame.cc b/api/frame.cc\n"
                              "--- a/api/frame.cc\n+++ b/api/frame.cc\n"
                              "@@ -1 +1 @@\n-before\n+after\n"
                              "diff --git a/api/added.cc b/api/added.cc\n"
                              "new file mode 100644\n--- /dev/null\n+++ b/api/added.cc\n"
                              "@@ -0,0 +1 @@\n+added\n"
                              "diff --git a/unused.txt b/unused.txt\n"
                              "deleted file mode 100644\n--- a/unused.txt\n+++ /dev/null\n"
                              "@@ -1 +0,0 @@\n-remove\n")
        (self.source / "api/added.cc").write_text("added\n")
        generated = self.root / "generated.json"
        # Synthetic input is accepted only by this in-process test mock.
        # Production CLIs always require the real pinned archive digest.
        with patch.object(manifest_tool, "check_archive"):
            manifest_tool.make_manifest(archive_path, self.patch, generated)
        self.manifest.write_bytes(generated.read_bytes())
        self.lock["patch"]["sha256"] = tools.digest(self.patch)
        self.lock["source_manifest"]["sha256"] = tools.digest(self.manifest)
        self.write_lock()
        self.verify()
        output = (self.root / "prepared").resolve()
        with patch.object(tools, "check_archive"):
            result = tools.prepare(archive_path, output, self.lock_path)
            self.assertEqual(result, output / "src")
            self.assertEqual((output / "DEPS").read_bytes(), (self.root / "DEPS").read_bytes())
            self.assertTrue((output / "source-provenance.json").is_file())
            with self.assertRaisesRegex(ValueError, "Output already exists"):
                tools.prepare(archive_path, output, self.lock_path)
        with self.assertRaisesRegex(ValueError, "archive identity mismatch"):
            tools.check_archive(archive_path)


if __name__ == "__main__":
    unittest.main()
