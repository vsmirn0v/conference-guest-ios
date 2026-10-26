import pathlib
import plistlib
import tempfile
import unittest

import build_support as support


class ProductIdentityTests(unittest.TestCase):
    def app(self, directory, name, identifier=support.BUNDLE_ID):
        app = pathlib.Path(directory) / name
        (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': identifier, 'CFBundleExecutable': support.EXECUTABLE_NAME}))
        return app

    def test_fresh_install_and_existing_names_have_one_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(support.installation_destination(directory, '').name, "Rock'N'Roll for Mac.app")
            with self.assertRaisesRegex(ValueError, 'not installed'):
                support.installed_application(directory)
        for name in ["Rock'N'Roll for Mac.app", 'RockNRoll Native Guest.app']:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                app = self.app(directory, name)
                self.assertEqual(support.installation_destination(directory, ''), app)
                self.assertEqual(support.installed_application(directory), app)
                self.assertEqual(support.application_executable(app), app / 'Contents/MacOS/RockNRoll Native Guest')

    def test_running_old_or_new_installation_is_never_replaced(self):
        for name in ["Rock'N'Roll for Mac.app", 'RockNRoll Native Guest.app']:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                app = self.app(directory, name)
                command = str(app / 'Contents/MacOS/RockNRoll Native Guest') + '\n'
                with self.assertRaisesRegex(ValueError, 'Close the installed'):
                    support.installation_destination(directory, command)

    def test_duplicates_and_unrelated_bundles_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            self.app(directory, support.APP_BUNDLE_NAME)
            self.app(directory, support.LEGACY_APP_BUNDLE_NAME)
            with self.assertRaisesRegex(ValueError, 'Both native app names'):
                support.installation_destination(directory, '')
        for name in [support.APP_BUNDLE_NAME, support.LEGACY_APP_BUNDLE_NAME]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                self.app(directory, name, identifier='unrelated.app')
                with self.assertRaisesRegex(ValueError, 'unrelated'):
                    support.installation_destination(directory, '')

    def test_installation_symlink_is_rejected_even_when_broken(self):
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory) / support.APP_BUNDLE_NAME
            app.symlink_to(pathlib.Path(directory) / 'missing.app')
            with self.assertRaisesRegex(ValueError, 'symbolic-link'):
                support.installation_destination(directory, '')

    def test_archive_resolution_handles_renamed_and_historical_products(self):
        for name in [support.APP_BUNDLE_NAME, support.LEGACY_APP_BUNDLE_NAME]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                app = self.app(directory, name)
                self.app(directory, 'Unrelated.app', identifier='unrelated.app')
                self.assertEqual(support.find_application(directory), app)
                self.app(directory, 'Duplicate.app')
                with self.assertRaisesRegex(ValueError, 'exactly one'):
                    support.find_application(directory)

    def test_metadata_names_change_without_changing_executable_or_identity(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        info = plistlib.loads((root / 'NativeMacGuest/Info.plist').read_bytes())
        for key in ['CFBundleName', 'CFBundleDisplayName']:
            self.assertEqual(info[key], "Rock'N'Roll for Mac")
        self.assertEqual(info['CFBundleExecutable'], '$(EXECUTABLE_NAME)')
        self.assertEqual(info['CFBundleIdentifier'], '$(PRODUCT_BUNDLE_IDENTIFIER)')
        self.assertEqual(info['NSUserActivityTypes'], ['dev.vsmirn0v.conferenceguest.continue-jam'])
        spec = (root / 'NativeMacGuest/project.yml').read_text()
        self.assertIn("PRODUCT_NAME: Rock'N'Roll for Mac\n", spec)
        self.assertIn('EXECUTABLE_NAME: RockNRoll Native Guest\n', spec)
        self.assertIn('PRODUCT_MODULE_NAME: RockNativeDesktop\n', spec)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER: dev.vsmirn0v.conferenceguest.nativeguest\n', spec)
        self.assertIn("TEST_HOST: $(BUILT_PRODUCTS_DIR)/Rock'N'Roll for Mac.app/Contents/MacOS/RockNRoll Native Guest\n", spec)


if __name__ == '__main__':
    unittest.main()
