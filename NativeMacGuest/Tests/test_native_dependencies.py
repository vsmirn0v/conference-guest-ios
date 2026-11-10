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
        (ROOT / ".build").mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=ROOT / ".build")
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


class AudioRouteRecoveryFrameworkTests(unittest.TestCase):
    def setUp(self):
        (ROOT / ".build").mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=ROOT / ".build")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name) / "candidate"
        self.binary = self.root / "LiveKitWebRTC.xcframework/macos-arm64/LiveKitWebRTC.framework/LiveKitWebRTC"
        self.binary.parent.mkdir(parents=True)
        self.binary.write_bytes(b"new audio route candidate")
        self.contract = dependencies.audio_route_recovery_contract()
        self.evidence = {
            "audioRouteRecovery": self.contract,
            "sourceRevision": self.contract["upstreamRevision"],
            "sourceManifestSHA256": "b" * 64,
            "frameworkBinarySHA256": dependencies.sha256(self.binary),
        }
        self.write_evidence()

    def write_evidence(self):
        (self.root / "build-evidence.json").write_text(json.dumps(self.evidence))

    def test_verifies_candidate_against_both_checked_in_patches(self):
        self.assertEqual(dependencies.verify_audio_route_recovery_framework(self.root), self.contract)
        self.assertEqual(self.contract["capabilities"], {
            "configurationRecoveryRaceGuard": True,
            "defaultRouteNativeHandover": True,
        })
        self.assertEqual(len(self.contract["patches"]), 2)

    def test_legacy_framework_without_route_evidence_is_rejected(self):
        del self.evidence["audioRouteRecovery"]
        self.write_evidence()
        with self.assertRaisesRegex(ValueError, "no audioRouteRecovery evidence"):
            dependencies.verify_audio_route_recovery_framework(self.root)

    def test_changed_patch_identity_is_rejected(self):
        name = "Experiments/WebRTCM156/default-route-recovery.patch"
        self.evidence["audioRouteRecovery"]["patches"][name] = "0" * 64
        self.write_evidence()
        with self.assertRaisesRegex(ValueError, r"audioRouteRecovery\.patches"):
            dependencies.verify_audio_route_recovery_framework(self.root)

    def test_original_source_manifest_is_rejected(self):
        self.evidence["sourceManifestSHA256"] = self.contract["baseSourceManifestSHA256"]
        self.write_evidence()
        with self.assertRaisesRegex(ValueError, "distinct final source-manifest"):
            dependencies.verify_audio_route_recovery_framework(self.root)

    def test_original_binary_cannot_claim_route_recovery(self):
        actual_sha256 = dependencies.sha256
        def only_original_binary(path):
            if pathlib.Path(path) == self.binary:
                return self.contract["baseFrameworkBinarySHA256"]
            return actual_sha256(path)
        with mock.patch.object(dependencies, "sha256", side_effect=only_original_binary):
            with self.assertRaisesRegex(ValueError, "reuses the original binary"):
                dependencies.verify_audio_route_recovery_framework(self.root)

    def test_direct_builder_stops_before_preparing_an_unpatched_framework(self):
        legacy = self.root / "legacy-framework"
        legacy.mkdir()
        (legacy / "build-evidence.json").write_text(json.dumps({
            "sourceRevision": self.contract["upstreamRevision"],
            "sourceManifestSHA256": self.contract["baseSourceManifestSHA256"],
            "frameworkBinarySHA256": self.contract["baseFrameworkBinarySHA256"],
        }))
        output = self.root / "app-build"
        result = subprocess.run([
            sys.executable, str(ROOT / "NativeMacGuest/build.py"),
            "--compile-only", "--distribution", "direct",
            "--framework-root", str(legacy), "--output-dir", str(output),
        ], cwd=ROOT, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no audioRouteRecovery evidence", result.stderr)
        self.assertFalse((output / "Dependencies").exists())
        self.assertFalse((output / "Xcode").exists())


if __name__ == "__main__":
    unittest.main()
