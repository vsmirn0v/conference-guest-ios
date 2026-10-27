"""Fresh-checkout dependency and preservation checks; no signing or hardware needed."""
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "NativeMacGuest"))
import native_dependencies as dependencies


class NativeDependenciesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repository = pathlib.Path(self.temporary.name) / "fresh-clone"
        self.vendor = self.repository / "Dependencies/native-macos"
        self.vendor.mkdir(parents=True)
        for path in (ROOT / "Dependencies/native-macos").iterdir():
            if path.name == "sdk.lock.json" or path.name.endswith(".tar.gz"):
                shutil.copy2(path, self.vendor / path.name)

    def install(self):
        return dependencies.ensure_framework(repository=self.repository)

    def test_clean_checkout_installs_headers_and_exact_binary_offline(self):
        with mock.patch.object(subprocess, "run", side_effect=AssertionError("offline SDK must not invoke a downloader")):
            root = self.install()
        lock = dependencies.sdk_lock(self.repository)
        dependencies.verify_framework(root, lock)
        framework = root / "LiveKitWebRTC.xcframework/macos-arm64/LiveKitWebRTC.framework"
        self.assertTrue((framework / "Headers/RTCAudioDeviceModule.h").is_file())
        self.assertTrue((framework / "Modules/module.modulemap").is_file())
        self.assertEqual(dependencies.sha256(framework / "LiveKitWebRTC"), lock["frameworkBinarySHA256"])
        self.assertTrue((root / "licenses/THIRD_PARTY_NOTICES.md").is_file())
        inode = root.stat().st_ino
        self.assertEqual(self.install().stat().st_ino, inode)

    def test_corrupt_archive_is_rejected_before_destination_created(self):
        lock = dependencies.sdk_lock(self.repository)
        with (self.vendor / lock["archive"]).open("ab") as archive:
            archive.write(b"corrupt")
        with self.assertRaisesRegex(ValueError, "checksum failed"):
            self.install()
        self.assertFalse(dependencies.default_framework_root(self.repository).exists())

    def test_changed_header_is_preserved_and_rejected(self):
        root = self.install()
        header = root / "LiveKitWebRTC.xcframework/macos-arm64/LiveKitWebRTC.framework/Headers/RTCAudioDeviceModule.h"
        header.write_text("local SDK work\n")
        with self.assertRaisesRegex(ValueError, "differs from its lock"):
            self.install()
        self.assertEqual(header.read_text(), "local SDK work\n")

    def test_extra_framework_file_is_rejected(self):
        root = self.install()
        (root / "LiveKitWebRTC.xcframework/unexpected.h").write_text("unknown header")
        with self.assertRaisesRegex(ValueError, "contents differ"):
            self.install()

    def test_existing_unrelated_destination_is_not_overwritten(self):
        root = dependencies.default_framework_root(self.repository)
        root.mkdir(parents=True)
        (root / "sentinel").write_text("keep")
        with self.assertRaises(ValueError):
            self.install()
        self.assertEqual((root / "sentinel").read_text(), "keep")

    def test_missing_custom_sdk_does_not_fall_back_to_different_binary(self):
        custom = self.repository / "custom-sdk"
        with self.assertRaisesRegex(ValueError, "Custom SDK is missing"):
            dependencies.ensure_framework(custom, self.repository)
        self.assertFalse(custom.exists())

    def test_source_fetch_is_pinned_and_dirty_source_is_preserved(self):
        origin = pathlib.Path(self.temporary.name) / "upstream"
        subprocess.run(["git", "init", "--quiet", str(origin)], check=True)
        (origin / "Package.swift").write_text("// source fixture\n")
        subprocess.run(["git", "-C", str(origin), "add", "Package.swift"], check=True)
        subprocess.run(["git", "-C", str(origin), "-c", "user.name=SDK test", "-c", "user.email=sdk@example.invalid", "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "--no-gpg-sign", "-m", "SDK fixture"], check=True)
        revision = subprocess.check_output(["git", "-C", str(origin), "rev-parse", "HEAD"], text=True).strip()
        with mock.patch.object(dependencies, "SDK_URL", origin.as_uri()), mock.patch.object(dependencies, "SDK_REVISION", revision):
            source = dependencies.ensure_livekit_source(self.repository)
            self.assertEqual((source / "Package.swift").read_text(), "// source fixture\n")
            self.assertEqual(dependencies.ensure_livekit_source(self.repository), source)
            (source / "Package.swift").write_text("// private changes\n")
            with self.assertRaisesRegex(ValueError, "local changes"):
                dependencies.ensure_livekit_source(self.repository)
            self.assertEqual((source / "Package.swift").read_text(), "// private changes\n")

    def test_unsigned_mode_cannot_install_or_archive(self):
        for action in ["--install", "--archive"]:
            result = subprocess.run([sys.executable, str(ROOT / "NativeMacGuest/build.py"), "--compile-only", action], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("cannot install or archive", result.stderr)


if __name__ == "__main__":
    unittest.main()
