#!/usr/bin/env python3
"""Exercise fail-closed patch checks against an immutable guest candidate."""
import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
SOURCE = Path(sys.argv.pop(1)).resolve(strict=True)
spec = importlib.util.spec_from_file_location("maintenance_verify", HERE / "verify-source.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class VerificationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="rock-maintenance-negative-")
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name)
        for series in ["WebRTCMaintenance", "WebRTCHybrid", "GuestSDKRebuild"]:
            destination = self.repo / "Experiments" / series
            shutil.copytree(HERE.parent / series / "patches", destination / "patches")
        self.root = self.repo / "Experiments/WebRTCMaintenance"
        shutil.copy2(HERE / "maintenance-lock.json", self.root)
        self.scope = patch.multiple(module, ROOT=self.root, REPO=self.repo)
        self.scope.start()
        self.addCleanup(self.scope.stop)

    def testExactLockedStatePasses(self):
        self.assertEqual(module.verify(SOURCE, "guest")["flavor"], "guest")

    def testMissingPatchFails(self):
        next((self.repo / "Experiments/GuestSDKRebuild/patches").glob("0*.patch")).unlink()
        with self.assertRaisesRegex(RuntimeError, "Patch series changed"):
            module.verify(SOURCE, "guest")

    def testExtraPatchFails(self):
        (self.repo / "Experiments/WebRTCHybrid/patches/0999-unexpected.patch").write_text("unexpected\n")
        with self.assertRaisesRegex(RuntimeError, "Patch series changed"):
            module.verify(SOURCE, "guest")

    def testTamperedPatchFails(self):
        path = next((self.repo / "Experiments/GuestSDKRebuild/patches").glob("0*.patch"))
        path.write_bytes(path.read_bytes() + b"\n")
        with self.assertRaisesRegex(RuntimeError, "Patch identity changed"):
            module.verify(SOURCE, "guest")


if __name__ == "__main__":
    unittest.main()
