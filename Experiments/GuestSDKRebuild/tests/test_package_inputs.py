"""Hermetic packaging regressions; only tiny file-copy Ninja fixtures execute."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


EXPERIMENT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("verify_package_inputs", EXPERIMENT / "verify_package_inputs.py")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)
NINJA = os.environ.get("NINJA_BIN") or shutil.which("ninja")


class PackageInputsTests(unittest.TestCase):
    def setUp(self):
        if not NINJA:
            self.fail("Set NINJA_BIN to an existing Ninja executable")
        self.temporary = tempfile.TemporaryDirectory(prefix="guest package inputs ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "src"
        self.source.mkdir()
        self.framework = self.root / "WebRTC.xcframework"
        self.framework.mkdir()
        ninja = self.source / "third_party/ninja/ninja"
        ninja.parent.mkdir(parents=True)
        ninja.symlink_to(Path(NINJA).resolve())
        gn = self.source / "buildtools/mac/gn"
        gn.parent.mkdir(parents=True)
        gn.write_text(f"#!{sys.executable}\nimport pathlib, sys\n"
                      "assert sys.argv[1] == 'args' and sys.argv[3:] == ['--list', '--json']\n"
                      "print((pathlib.Path(sys.argv[2]) / 'evaluated-args.json').read_text())\n")
        gn.chmod(0o755)
        (self.source / "input.cc").write_text("current implementation\n")
        (self.source / "dependency.h").write_text("current dependency\n")
        action = self.source / "fixture.py"
        action.write_text(
            "from pathlib import Path\nimport sys\n"
            "environment, source, dependency, output, depfile = sys.argv[1:]\n"
            "Path(output).write_text(environment + Path(source).read_text() + Path(dependency).read_text())\n"
            "Path(depfile).write_text(output + ': ' + dependency + '\\n')\n"
        )
        self.metadata = {"AvailableLibraries": []}
        for environment in ("device", "simulator"):
            output = self.output(environment)
            (output / "obj/sdk").mkdir(parents=True)
            (output / "WebRTC.framework").mkdir()
            values = {"target_os": "ios", "target_cpu": "arm64", "target_environment": environment,
                      "enable_stripping": False, "ios_enable_code_signing": False}
            (output / "args.gn").write_text("\n".join(f"{key} = {json.dumps(value)}" for key, value in values.items()))
            (output / "evaluated-args.json").write_text(json.dumps([
                {"name": key, "current": {"value": json.dumps(value)}, "default": {"value": "unused"}}
                for key, value in values.items()
            ]))
            (output / "build.ninja").write_text(
                "rule link\n"
                f"  command = {shlex.quote(sys.executable)} ../../fixture.py {environment} "
                "../../input.cc ../../dependency.h obj/sdk/WebRTC obj/sdk/WebRTC.d\n"
                "  depfile = obj/sdk/WebRTC.d\n  deps = gcc\n"
                "build obj/sdk/WebRTC: link ../../input.cc\n"
                "rule bundle\n  command = cp obj/sdk/WebRTC WebRTC.framework/WebRTC\n"
                "build WebRTC.framework/WebRTC: bundle obj/sdk/WebRTC\n"
                "build ios_framework_bundle: phony WebRTC.framework/WebRTC\n"
            )
            self.build(environment)
            identifier = "ios-arm64" + ("-simulator" if environment == "simulator" else "")
            item = {"LibraryIdentifier": identifier, "LibraryPath": "WebRTC.framework",
                    "SupportedPlatform": "ios", "SupportedArchitectures": ["arm64"]}
            if environment == "simulator":
                item["SupportedPlatformVariant"] = environment
            self.metadata["AvailableLibraries"].append(item)
            shutil.copytree(output / "WebRTC.framework", self.framework / identifier / "WebRTC.framework")
        (self.framework / "Info.plist").write_bytes(plistlib.dumps(self.metadata))

    def output(self, environment="device"):
        return self.source / f"out/rock-hybrid-ios-{environment}"

    def build(self, environment="device"):
        subprocess.run([str(NINJA), "-C", str(self.output(environment)), "ios_framework_bundle"],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def verify(self):
        return validator.verify_inputs(self.source, self.framework, self.metadata)

    def make_newer(self, path):
        timestamp = (self.output() / "obj/sdk/WebRTC").stat().st_mtime_ns + 2_000_000_000
        os.utime(path, ns=(timestamp, timestamp))

    def test_current_build_and_assembled_binary_match(self):
        slices = self.verify()
        self.assertEqual(len(slices), 2)
        self.assertNotEqual(slices[0]["binary_sha256"], slices[1]["binary_sha256"])

    def test_source_only_change_requires_rebuild(self):
        source = self.source / "input.cc"
        source.write_text("source fix without a new exported API\n")
        self.make_newer(source)
        with self.assertRaisesRegex(RuntimeError, "Build is not up to date"):
            self.verify()

    def test_discovered_dependency_change_requires_rebuild(self):
        self.make_newer(self.source / "dependency.h")
        with self.assertRaisesRegex(RuntimeError, "Build is not up to date"):
            self.verify()

    def test_link_command_change_requires_rebuild(self):
        graph = self.output() / "build.ninja"
        graph.write_text(graph.read_text().replace("fixture.py device", "fixture.py new-command"))
        with self.assertRaisesRegex(RuntimeError, "Build is not up to date"):
            self.verify()

    def test_missing_bundle_requires_rebuild(self):
        (self.output() / "WebRTC.framework/WebRTC").unlink()
        with self.assertRaisesRegex(RuntimeError, "Build is not up to date"):
            self.verify()

    def test_old_assembled_binary_is_rejected_after_rebuild(self):
        source = self.source / "input.cc"
        source.write_text("source fix without a new exported API\n")
        self.build()
        with self.assertRaisesRegex(RuntimeError, "differs from current GN output"):
            self.verify()

    def test_modified_bundle_cannot_attest_linked_output(self):
        (self.output() / "WebRTC.framework/WebRTC").write_text("different bundle")
        with self.assertRaisesRegex(RuntimeError, "differs from linked binary"):
            self.verify()

    def test_wrong_gn_environment_is_rejected(self):
        path = self.output() / "evaluated-args.json"
        args = json.loads(path.read_text())
        next(item for item in args if item["name"] == "target_environment")["current"]["value"] = '"simulator"'
        path.write_text(json.dumps(args))
        with self.assertRaisesRegex(RuntimeError, "Unexpected GN argument target_environment"):
            self.verify()

    def test_missing_duplicate_and_unsupported_slices_are_rejected(self):
        original = copy.deepcopy(self.metadata)
        for libraries in (original["AvailableLibraries"][:1],
                          [original["AvailableLibraries"][0]] * 2,
                          [dict(original["AvailableLibraries"][0], SupportedPlatformVariant="maccatalyst"),
                           original["AvailableLibraries"][1]]):
            with self.subTest(libraries=libraries):
                self.metadata = {"AvailableLibraries": libraries}
                with self.assertRaisesRegex(RuntimeError, "Expected exactly one"):
                    self.verify()

    def test_slice_paths_cannot_escape_framework(self):
        self.metadata["AvailableLibraries"][0]["LibraryIdentifier"] = "../elsewhere"
        with self.assertRaisesRegex(RuntimeError, "Invalid framework path"):
            self.verify()

    def prepare_packager(self):
        experiment = self.root / "experiment"
        experiment.mkdir()
        for name in ("build-ios.sh", "package-notices.sh", "package-release.sh", "verify_package_inputs.py"):
            shutil.copy2(EXPERIMENT / name, experiment / name)
        verify_source = experiment / "verify-source.sh"
        verify_source.write_text("#!/bin/bash\nexit 0\n")
        verify_source.chmod(0o755)
        for name in ("LICENSE", "PATENTS", "AUTHORS"):
            (self.source / name).write_text(f"Fixture {name}\n")
        generator = self.source / "tools_webrtc/libs/generate_licenses.py"
        generator.parent.mkdir(parents=True)
        generator.write_text("import pathlib, sys\n"
                             "(pathlib.Path(sys.argv[3]) / 'LICENSE.md').write_text('Linked fixture license')\n")
        commands = self.root / "bin"
        commands.mkdir()
        git = commands / "git"
        git.write_text("#!/bin/bash\n[[ \"$*\" == 'rev-parse HEAD' ]] || exit 1\nprintf '%s\\n' fixture-revision\n")
        git.chmod(0o755)
        environment = os.environ.copy()
        environment["PATH"] = str(commands) + os.pathsep + environment["PATH"]
        return experiment, environment

    def test_package_notices_records_validated_slices_and_helper_recipe(self):
        experiment, environment = self.prepare_packager()
        result = subprocess.run(["bash", str(experiment / "package-notices.sh"), str(self.source), str(self.framework)],
                                env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode, 0, result.stdout)
        provenance = json.loads((self.framework / "Supporting/provenance.json").read_text())
        self.assertEqual(provenance["slices"], self.verify())
        self.assertIn("verify_package_inputs.py", [item["name"] for item in provenance["recipes"]])

    def test_both_packagers_fail_before_writing_provenance_for_stale_assembly(self):
        experiment, environment = self.prepare_packager()
        stale_binary = self.framework / "ios-arm64/WebRTC.framework/WebRTC"
        stale_binary.write_text("stale preassembled binary")
        for script in ("package-notices.sh", "package-release.sh"):
            with self.subTest(script=script):
                result = subprocess.run(["bash", str(experiment / script), str(self.source), str(self.framework),
                                         str(self.root / "release")], env=environment,
                                        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("differs from current GN output", result.stdout)
        self.assertFalse((self.framework / "Supporting").exists())
        self.assertFalse((self.root / "release").exists())


if __name__ == "__main__":
    unittest.main()
