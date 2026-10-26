import base64
import hashlib
import json
import pathlib
import tempfile
import unittest
import xml.etree.ElementTree as ET
from types import SimpleNamespace
from unittest import mock

import release
import publish

SIGNATURE = base64.b64encode(b's' * 64).decode()


class FeedIdentityTests(unittest.TestCase):
    def fixture(self, temporary):
        path = pathlib.Path(temporary)
        filename = 'RockNRoll-0.3.0-21-arm64.dmg'
        dmg = path / filename
        dmg.write_bytes(b'notarized DMG fixture')
        entry = {'version': '0.3.0', 'build': '21', 'downloadURL': release.ORIGIN + '/mac/releases/' + filename,
                 'sha256': hashlib.sha256(dmg.read_bytes()).hexdigest()}
        evidence = dict(entry, schemaVersion=1, file=filename, length=dmg.stat().st_size,
                        bundleIdentifier=release.BUNDLE_ID, appStapleValidated=True, gatekeeperExecuteAccepted=True)
        (path / 'release.json').write_text(json.dumps(evidence))
        root = ET.Element('rss', {'version': '2.0'})
        channel = ET.SubElement(root, 'channel')
        item = ET.SubElement(channel, 'item')
        ET.SubElement(item, f'{{{release.NS}}}channel').text = 'beta'
        enclosure = ET.SubElement(item, 'enclosure', {
            'url': entry['downloadURL'], 'length': str(dmg.stat().st_size),
            f'{{{release.NS}}}version': '21', f'{{{release.NS}}}shortVersionString': '0.3.0',
            f'{{{release.NS}}}edSignature': SIGNATURE})
        previous_feed = path / 'previous.xml'
        ET.ElementTree(root).write(previous_feed)
        inventory = {'schemaVersion': 1, 'stable': dict(entry, build='20',
                     downloadURL=release.ORIGIN + '/mac/releases/RockNRoll-0.3.0-20-arm64.dmg'), 'beta': entry}
        inventory_path = path / 'previous.json'
        inventory_path.write_text(json.dumps(inventory))
        args = SimpleNamespace(release=path / 'release.json', channel='stable', output=path / 'Feed',
                               previous_feed=previous_feed, previous_inventory=inventory_path)
        return args, root, enclosure, inventory

    def run_command(self, command, **kwargs):
        text = release.PUBLIC_KEY if pathlib.Path(command[0]).name == 'generate_keys' else SIGNATURE if '-p' in command else ''
        return SimpleNamespace(returncode=0, stdout=text, stderr='')

    def test_conflicting_equal_build_is_rejected_across_channels(self):
        for attribute, value in [('url', release.ORIGIN + '/mac/releases/RockNRoll-0.4.0-21-arm64.dmg'),
                                 ('length', '999'), (f'{{{release.NS}}}edSignature', base64.b64encode(b'x' * 64).decode())]:
            with self.subTest(attribute=attribute), tempfile.TemporaryDirectory() as temporary:
                args, root, enclosure, _ = self.fixture(temporary)
                enclosure.set(attribute, value)
                ET.ElementTree(root).write(args.previous_feed)
                with mock.patch.object(release, 'pinned_sparkle'), mock.patch.object(release, 'run', side_effect=self.run_command):
                    with self.assertRaisesRegex(ValueError, 'different feed artifact across channels'):
                        release.prepare_feed(args)

    def test_identical_beta_to_stable_promotion_preserves_both_channels(self):
        with tempfile.TemporaryDirectory() as temporary:
            args, _, _, _ = self.fixture(temporary)
            with mock.patch.object(release, 'pinned_sparkle'), mock.patch.object(release, 'run', side_effect=self.run_command):
                release.prepare_feed(args)
            channels = {release.item_channel(item) for item in ET.parse(args.output / 'appcast.xml').findall('./channel/item')}
            self.assertEqual(channels, {'stable', 'beta'})
            inventory = json.loads((args.output / 'latest.json').read_text())
            self.assertEqual(inventory['stable'], inventory['beta'])

    def test_equal_inventory_build_with_different_digest_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            args, _, _, inventory = self.fixture(temporary)
            inventory['stable'] = dict(inventory['beta'], sha256='0' * 64)
            args.previous_inventory.write_text(json.dumps(inventory))
            with mock.patch.object(release, 'pinned_sparkle'), mock.patch.object(release, 'run', side_effect=self.run_command):
                with self.assertRaisesRegex(ValueError, 'different inventory artifacts across channels'):
                    release.prepare_feed(args)

    def test_beta_name_change_preserves_stable_inventory_and_artifact_urls(self):
        with tempfile.TemporaryDirectory() as temporary:
            args, root, _, previous = self.fixture(temporary)
            args.channel = 'beta'
            ET.SubElement(root.find('channel'), 'title').text = 'Legacy Mac product'
            ET.ElementTree(root).write(args.previous_feed)
            with mock.patch.object(release, 'pinned_sparkle'), mock.patch.object(release, 'run', side_effect=self.run_command):
                release.prepare_feed(args)
            feed = ET.parse(args.output / 'appcast.xml')
            self.assertEqual(feed.findtext('./channel/title'), "Rock'N'Roll for Mac")
            self.assertEqual(feed.findtext('./channel/item/title'), "Rock'N'Roll for Mac 0.3.0 (21)")
            inventory = json.loads((args.output / 'latest.json').read_text())
            self.assertEqual(inventory['stable'], previous['stable'])
            self.assertEqual(inventory['beta'], previous['beta'])

    def test_publisher_preserves_signed_feed_bytes_including_signature_comment(self):
        with tempfile.TemporaryDirectory() as temporary:
            args, root, _, inventory = self.fixture(temporary)
            inventory['stable'] = inventory['beta']
            args.previous_inventory.write_text(json.dumps(inventory))
            root.find('./channel/item').remove(root.find(f'./channel/item/{{{release.NS}}}channel'))
            signed = ET.tostring(root, encoding='utf-8', xml_declaration=True) + b'\n<!-- EdDSA signature fixture: preserve these final bytes -->\n'
            args.previous_feed.write_bytes(signed)
            plan_args = SimpleNamespace(feed=args.previous_feed, inventory=args.previous_inventory,
                                        package=args.release.parent)
            with mock.patch.object(publish, 'pinned_sparkle'), mock.patch.object(publish, 'run', side_effect=self.run_command) as commands:
                plan, _ = publish.local_plan(plan_args)
            self.assertEqual(args.previous_feed.read_bytes(), signed)
            self.assertEqual(plan['feedSHA256'], hashlib.sha256(signed).hexdigest())
            self.assertTrue(any(str(args.previous_feed) in [str(x) for x in call.args[0]] and '--verify' in call.args[0]
                                for call in commands.call_args_list))


if __name__ == '__main__':
    unittest.main()
