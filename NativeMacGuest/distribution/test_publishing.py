import hashlib
import json
import os
import pathlib
import tempfile
import unittest
import uuid
from types import SimpleNamespace
from unittest import mock

import publish
import publish_remote as remote_helper


class PublicationTests(unittest.TestCase):
    def fixture(self, temporary):
        web = pathlib.Path(temporary) / 'web'
        for key, value in [('WEB_ROOT', web), ('PUBLIC_ROOT', web / 'releases'), ('STAGING_ROOT', web / '.publish-stage')]:
            patch = mock.patch.object(remote_helper, key, value)
            patch.start()
            self.addCleanup(patch.stop)
        artifact = b'verified disk image fixture'
        feed, inventory = b'<rss version="2.0"><channel/></rss>', b'{"schemaVersion":1}'
        filename = 'RockNRoll-0.3.0-21-arm64.dmg'
        artifact_hash = hashlib.sha256(artifact).hexdigest()
        channel = {'file': filename, 'sha256': artifact_hash, 'build': '21'}
        plan = {'artifact': {'file': filename, 'sha256': artifact_hash, 'length': len(artifact)},
                'inventory': {'schemaVersion': 1, 'stable': channel, 'beta': channel},
                'feedArtifacts': [{'file': filename, 'length': len(artifact)}],
                'feedSHA256': hashlib.sha256(feed).hexdigest(),
                'inventorySHA256': hashlib.sha256(inventory).hexdigest()}
        files = {filename: artifact, 'appcast.xml': feed, 'latest.json': inventory}
        return web, plan, files

    def stage(self, plan, files):
        plan['expectedState'] = remote_helper.preflight(plan)['state']
        plan['stageID'] = uuid.uuid4().hex
        staging = pathlib.Path(remote_helper.stage(plan)['stage'])
        for name, data in files.items():
            (staging / name).write_bytes(data)
        return staging

    def test_preflight_creates_no_remote_directories(self):
        with tempfile.TemporaryDirectory() as temporary:
            web, plan, _ = self.fixture(temporary)
            self.assertFalse(remote_helper.preflight(plan)['immutableAlreadyPresent'])
            self.assertFalse(web.exists())

    def test_apply_installs_immutable_bytes_and_promotes_feed_last(self):
        with tempfile.TemporaryDirectory() as temporary:
            web, plan, files = self.fixture(temporary)
            self.stage(plan, files)
            with mock.patch.object(remote_helper.os, 'replace', wraps=os.replace) as replace:
                result = remote_helper.apply(plan)
            root = web / 'releases'
            self.assertEqual((root / 'releases' / plan['artifact']['file']).read_bytes(), files[plan['artifact']['file']])
            self.assertEqual(os.readlink(root / 'stable/latest.dmg'), '../releases/' + plan['artifact']['file'])
            self.assertEqual(os.readlink(root / 'beta/latest.dmg'), '../releases/' + plan['artifact']['file'])
            self.assertEqual([call.args[1].name for call in replace.call_args_list][-2:], ['latest.json', 'appcast.xml'])
            self.assertEqual((web / '.publish-stage').stat().st_mode & 0o777, 0o700)
            self.assertEqual(root.stat().st_mode & 0o777, 0o755)
            self.assertEqual((root / 'appcast.xml').stat().st_mode & 0o777, 0o644)
            self.assertTrue(pathlib.Path(result['backupDirectory'], 'previous-state.json').is_file())

    def test_immutable_collision_preserves_existing_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            web, plan, files = self.fixture(temporary)
            self.stage(plan, files)
            remote_helper.apply(plan)
            original = (web / 'releases/releases' / plan['artifact']['file']).read_bytes()
            plan['artifact']['sha256'] = '0' * 64
            with self.assertRaisesRegex(ValueError, 'Immutable artifact collision'):
                remote_helper.preflight(plan)
            self.assertEqual((web / 'releases/releases' / plan['artifact']['file']).read_bytes(), original)

    def test_metadata_race_stops_before_install_or_promotion(self):
        with tempfile.TemporaryDirectory() as temporary:
            web, plan, files = self.fixture(temporary)
            self.stage(plan, files)
            (web / 'releases/latest.json').write_text(json.dumps({'schemaVersion': 1}))
            with self.assertRaisesRegex(ValueError, 'changed after preflight'):
                remote_helper.apply(plan)
            self.assertFalse((web / 'releases/releases' / plan['artifact']['file']).exists())
            self.assertFalse((web / 'releases/appcast.xml').exists())

    def test_default_command_performs_only_preflight(self):
        args = SimpleNamespace(apply=False)
        plan = {'artifact': {'file': 'RockNRoll-0.3.0-21-arm64.dmg'}}
        with mock.patch.object(publish, 'local_plan', return_value=(plan, pathlib.Path('/unused'))) as local:
            with mock.patch.object(publish, 'remote', return_value={'state': {}}) as remote:
                with mock.patch.object(publish.subprocess, 'run') as command:
                    publish.publish(args)
                    local.assert_called_once_with(args)
                    remote.assert_called_once_with('preflight', plan)
                    command.assert_not_called()


if __name__ == '__main__':
    unittest.main()
