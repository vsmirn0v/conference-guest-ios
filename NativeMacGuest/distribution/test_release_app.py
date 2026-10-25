import pathlib
import plistlib
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

import release


class ExportedIdentityTests(unittest.TestCase):
    def fixture(self, temporary):
        app = pathlib.Path(temporary) / 'RockNRoll Native Guest.app'
        (app / 'Contents/Frameworks/Sparkle.framework').mkdir(parents=True)
        info = dict(release.DIRECT_INFO, CFBundleIdentifier=release.BUNDLE_ID,
                    CFBundleShortVersionString='0.3.0', CFBundleVersion='21')
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        entitlements = {'com.apple.security.app-sandbox': True,
                        'com.apple.developer.icloud-container-environment': 'Production',
                        'com.apple.developer.aps-environment': 'production',
                        'com.apple.developer.team-identifier': release.TEAM_ID,
                        'com.apple.security.application-groups': ['group.dev.vsmirn0v.conferenceguest'],
                        'com.apple.developer.icloud-container-identifiers': ['iCloud.dev.vsmirn0v.conferenceguest'],
                        'com.apple.developer.icloud-services': ['CloudKit'],
                        'com.apple.security.temporary-exception.mach-lookup.global-name':
                            [release.BUNDLE_ID + '-spks', release.BUNDLE_ID + '-spki']}
        profile = {'TeamIdentifier': [release.TEAM_ID], 'Entitlements': dict(entitlements,
                   **{'com.apple.application-identifier': release.TEAM_ID + '.' + release.BUNDLE_ID})}
        details = ('Identifier=' + release.BUNDLE_ID + '\nCodeDirectory v=20500 size=1024 flags=0x10000(runtime)\n'
                   'Authority=Developer ID Application: Fixture\nTeamIdentifier=' + release.TEAM_ID + '\n')
        def command(args, **kwargs):
            if args[0] == 'security':
                return SimpleNamespace(stdout=plistlib.dumps(profile).decode(), stderr='', returncode=0)
            if '-dv' in args:
                return SimpleNamespace(stdout='', stderr=details, returncode=0)
            return SimpleNamespace(stdout=plistlib.dumps(entitlements).decode(), stderr='', returncode=0)
        return app, info, entitlements, profile, command

    def test_expected_cloud_identity_and_profile_are_accepted(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, info, _, _, command = self.fixture(temporary)
            with mock.patch.object(release, 'run', side_effect=command):
                self.assertEqual(release.inspect_app(app), info)

    def test_wrong_signed_cloud_identity_push_or_debug_entitlements_are_rejected(self):
        for key, value in [('com.apple.security.application-groups', ['group.unrelated']),
                           ('com.apple.developer.icloud-container-identifiers', ['iCloud.unrelated']),
                           ('com.apple.developer.aps-environment', 'development'),
                           ('com.apple.developer.team-identifier', 'OTHERTEAM'),
                           ('com.apple.security.get-task-allow', True)]:
            with self.subTest(key=key), tempfile.TemporaryDirectory() as temporary:
                app, _, entitlements, _, command = self.fixture(temporary)
                entitlements[key] = value
                with mock.patch.object(release, 'run', side_effect=command):
                    with self.assertRaises(ValueError):
                        release.inspect_app(app)

    def test_profile_must_authorize_the_signed_container(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, _, _, profile, command = self.fixture(temporary)
            profile['Entitlements']['com.apple.developer.icloud-container-identifiers'] = ['iCloud.unrelated']
            with mock.patch.object(release, 'run', side_effect=command):
                with self.assertRaisesRegex(ValueError, 'profile does not authorize'):
                    release.inspect_app(app)


if __name__ == '__main__':
    unittest.main()
