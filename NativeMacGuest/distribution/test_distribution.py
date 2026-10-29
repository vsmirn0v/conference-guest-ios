import pathlib
import plistlib
import json
import shutil
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

import build_support as support
import release

ROOT = pathlib.Path(__file__).resolve().parents[2]


class DistributionConfigurationTests(unittest.TestCase):
    def test_direct_preserves_originals_sandbox_and_cloud_entitlements(self):
        info_path = ROOT / 'NativeMacGuest/Info.plist'
        entitlement_path = ROOT / 'NativeMacGuest/NativeGuest.entitlements'
        original_info, original_entitlements = info_path.read_bytes(), entitlement_path.read_bytes()
        source = (ROOT / 'NativeMacGuest/project.yml').read_text()
        with tempfile.TemporaryDirectory() as temp:
            spec, _, inputs = support.configure_distribution(ROOT, pathlib.Path(temp), source, 'direct')
            info, entitlements = [plistlib.loads(path.read_bytes()) for path in inputs]
            self.assertEqual({key: info[key] for key in support.DIRECT_INFO}, support.DIRECT_INFO)
            for key, value in plistlib.loads(original_entitlements).items():
                self.assertEqual(entitlements[key], value)
            self.assertEqual(entitlements['com.apple.security.temporary-exception.mach-lookup.global-name'],
                             [support.BUNDLE_ID + '-spks', support.BUNDLE_ID + '-spki'])
            self.assertIn('NATIVE_DIRECT_UPDATES', spec)
            self.assertIn('embed: true\n        codeSign: true', spec)
        self.assertEqual(info_path.read_bytes(), original_info)
        self.assertEqual(entitlement_path.read_bytes(), original_entitlements)

    def test_app_store_has_no_updater_dependency_settings_or_generated_inputs(self):
        with tempfile.TemporaryDirectory() as temp, mock.patch.object(support, 'pinned_sparkle') as pin:
            spec, evidence, inputs = support.configure_distribution(
                ROOT, pathlib.Path(temp), (ROOT / 'NativeMacGuest/project.yml').read_text(), 'app-store')
            pin.assert_not_called()
            self.assertNotIn('Sparkle.framework', spec)
            self.assertNotIn('NATIVE_DIRECT_UPDATES', spec)
            self.assertNotIn('Info-Direct.plist', spec)
            self.assertNotIn('NativeGuest-Direct.entitlements', spec)
            self.assertIsNone(evidence)
            self.assertEqual(inputs, [])
            self.assertEqual(list(pathlib.Path(temp).iterdir()), [])

    def test_direct_license_is_added_after_builder_resolves_source_paths(self):
        source = (ROOT / 'NativeMacGuest/project.yml').read_text()
        resolved = support.resolve_source_paths(ROOT, source)
        anchor = f'      - path: {ROOT / "Experiments/NativeGuest"}\n'
        license_resource = (f'      - path: {ROOT / "NativeMacGuest/distribution/Sparkle-LICENSE.txt"}\n'
                            '        buildPhase: resources\n')
        with tempfile.TemporaryDirectory() as temp:
            spec, _, _ = support.configure_distribution(ROOT, pathlib.Path(temp), resolved, 'direct')
            self.assertEqual(spec.count(license_resource), 1)
            self.assertIn(license_resource + anchor, spec)
            for invalid in [resolved.replace(anchor, ''), resolved + anchor]:
                with self.assertRaisesRegex(ValueError, 'one NativeGuest source resource anchor'):
                    support.configure_distribution(ROOT, pathlib.Path(temp), invalid, 'direct')

    def test_ambiguous_spec_is_rejected_before_project_generation(self):
        with tempfile.TemporaryDirectory() as temp:
            source = (ROOT / 'NativeMacGuest/project.yml').read_text()
            with self.assertRaisesRegex(ValueError, 'one application INFOPLIST_FILE'):
                support.configure_distribution(ROOT, pathlib.Path(temp),
                                               source + '\n        INFOPLIST_FILE: another.plist\n', 'direct')

    @unittest.skipUnless(shutil.which('xcodegen') and shutil.which('plutil'), 'Requires XcodeGen and plutil; no build is run')
    def test_nested_generated_projects_resolve_source_and_file_settings(self):
        for distribution in ('app-store', 'direct'):
            with self.subTest(distribution=distribution), tempfile.TemporaryDirectory(dir=ROOT / '.build') as temp:
                output = pathlib.Path(temp).resolve() / '.build/native-dmg/build'
                spec_dir, project_dir = output / 'Spec', output / 'Project'
                spec_dir.mkdir(parents=True)
                project_dir.mkdir()
                source = (ROOT / 'NativeMacGuest/project.yml').read_text()
                # Model build.py's prepared package paths without fetching or building SDKs.
                packages = {output / 'Dependencies' / name for name in ('client-sdk-swift', 'webrtc-xcframework')}
                for package in packages:
                    package.mkdir(parents=True)
                    source = source.replace('../.build/native-desktop-dependencies/' + package.name, str(package))
                source = support.resolve_source_paths(ROOT, source)
                spec, _, _ = support.configure_distribution(ROOT, spec_dir, source, distribution)
                spec_path = spec_dir / 'project.yml'
                spec_path.write_text(spec)
                subprocess.run(['xcodegen', 'generate', '--spec', str(spec_path), '--project', str(project_dir)],
                               check=True, capture_output=True, text=True)
                project = project_dir / 'RockNativeGuest.xcodeproj/project.pbxproj'
                objects = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project)]))['objects']
                target = next(value for value in objects.values()
                              if value.get('isa') == 'PBXNativeTarget' and value.get('name') == 'RockNRollNativeGuest')
                expected = {'SWIFT_OBJC_BRIDGING_HEADER': ROOT / 'NativeMacGuest/NativeGuest-Bridging-Header.h',
                            'INFOPLIST_FILE': spec_dir / 'Info-Direct.plist' if distribution == 'direct' else ROOT / 'NativeMacGuest/Info.plist',
                            'CODE_SIGN_ENTITLEMENTS': spec_dir / 'NativeGuest-Direct.entitlements' if distribution == 'direct' else ROOT / 'NativeMacGuest/NativeGuest.entitlements'}
                for configuration in objects[target['buildConfigurationList']]['buildConfigurations']:
                    settings = objects[configuration]['buildSettings']
                    for key, path in expected.items():
                        self.assertEqual(settings[key], str(path))
                        self.assertTrue(path.is_file())
                group_paths = {(project_dir / value['path']).resolve() for value in objects.values()
                               if value.get('isa') == 'PBXGroup' and value.get('path')}
                self.assertIn(ROOT / 'NativeMacGuest', group_paths)
                self.assertIn(ROOT / 'Experiments/NativeGuest', group_paths)
                package_paths = {(project_dir / value['relativePath']).resolve() for value in objects.values()
                                 if value.get('isa') == 'XCLocalSwiftPackageReference'}
                self.assertEqual(package_paths, packages | {ROOT / 'ConferenceCore'})
                self.assertNotIn('$(SRCROOT)/../../../', project.read_text())


class NotarizationResumeTests(unittest.TestCase):
    def fixture(self, temp, name=support.APP_BUNDLE_NAME):
        path = pathlib.Path(temp)
        archive, output = path / 'Example.xcarchive', path / 'Export'
        info_path = archive / 'Products/Applications' / name / 'Contents/Info.plist'
        info_path.parent.mkdir(parents=True)
        info_path.write_bytes(plistlib.dumps({'CFBundleIdentifier': support.BUNDLE_ID, 'SUFeedURL': support.FEED_URL}))
        output.mkdir()
        return SimpleNamespace(archive=archive, output=output, wait_seconds=0)

    def test_pending_export_can_resume_without_uploading_again(self):
        with tempfile.TemporaryDirectory() as temp:
            args = self.fixture(temp)
            result = SimpleNamespace(returncode=65, stdout='', stderr='error: Archive "Example.xcarchive" is processing and not ready for distribution.\n')
            with mock.patch.object(release, 'run', return_value=result) as command, mock.patch.object(release.time, 'sleep') as sleep:
                with self.assertRaises(TimeoutError):
                    release.finalize_export(args)
                self.assertEqual(command.call_args.args[0][1], '-exportNotarizedApp')
                self.assertEqual(command.call_count, 1)
                sleep.assert_not_called()

    def test_other_export_failures_are_never_retried(self):
        with tempfile.TemporaryDirectory() as temp:
            args = self.fixture(temp)
            args.wait_seconds = 1800
            result = SimpleNamespace(returncode=65, stdout='', stderr='error: A signing certificate is unavailable.\n')
            with mock.patch.object(release, 'run', return_value=result) as command, mock.patch.object(release.time, 'sleep') as sleep:
                with self.assertRaisesRegex(ValueError, 'Notarized export failed'):
                    release.finalize_export(args)
                self.assertEqual(command.call_count, 1)
                sleep.assert_not_called()

    def test_historical_archive_can_still_resume(self):
        with tempfile.TemporaryDirectory() as temp:
            args = self.fixture(temp, support.LEGACY_APP_BUNDLE_NAME)
            result = SimpleNamespace(returncode=65, stdout='', stderr='error: Archive "Example.xcarchive" is processing and not ready for distribution.\n')
            with mock.patch.object(release, 'run', return_value=result):
                with self.assertRaises(TimeoutError):
                    release.finalize_export(args)


if __name__ == '__main__':
    unittest.main()
