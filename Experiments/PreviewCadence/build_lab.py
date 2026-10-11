#!/usr/bin/env python3
"""Generate an optimized DEBUG-only laboratory app without replacing the beta."""
import json
from pathlib import Path
import plistlib
import subprocess

root = Path(__file__).resolve().parents[2]
build = root / '.build/preview-cadence'
build.mkdir(parents=True, exist_ok=True)
spec = json.loads(subprocess.check_output(['ruby', '-ryaml', '-rjson', '-e',
    'puts JSON.generate(YAML.load_file(ARGV[0]))', str(root / 'project.yml')]))
app = spec['targets']['RockNRoll']
app.pop('scheme', None)
app['sources'][0]['excludes'] = ['Info.plist']
for entry in app['sources']:
    entry['path'] = str(root / entry['path'])
app['dependencies'] = [entry for entry in app['dependencies'] if 'target' not in entry]
for entry in app['dependencies']:
    if 'framework' in entry:
        entry['framework'] = str(root / entry['framework'])
for entry in spec['packages'].values():
    if 'path' in entry:
        entry['path'] = str(root / entry['path'])
settings = app['settings']['base']
settings.update(PRODUCT_BUNDLE_IDENTIFIER='dev.vsmirn0v.conferenceguest.previewexperiment',
                INFOPLIST_FILE=str(build / 'Info.plist'), CODE_SIGN_ENTITLEMENTS=str(build / 'Empty.entitlements'),
                SWIFT_OBJC_BRIDGING_HEADER=str(root / 'RockNRoll/BridgingHeader.h'))
app['settings']['configs']['Debug']['SWIFT_OPTIMIZATION_LEVEL'] = '-O'
for entry in app['postBuildScripts']:
    entry['script'] = 'bash "' + str(root / 'scripts/copy-sdk-resources.sh') + '"'
spec['name'] = 'PreviewExperiment'
spec['targets'] = {'RockNRoll': app, 'RockNRollUITests': {
    'type': 'bundle.ui-testing', 'platform': 'iOS',
    'sources': [str(root / 'RockNRollUITests/PreviewCadenceUITests.swift')],
    'dependencies': [{'target': 'RockNRoll'}], 'settings': {'base': {
        'PRODUCT_BUNDLE_IDENTIFIER': 'dev.vsmirn0v.conferenceguest.previewexperiment.uitests',
        'DEVELOPMENT_TEAM': '5V64BP2H3P', 'CODE_SIGN_STYLE': 'Automatic',
        'GENERATE_INFOPLIST_FILE': 'YES', 'SWIFT_VERSION': '5.0'}}}}
spec['schemes'] = {'PreviewExperiment': {'build': {'targets': {'RockNRoll': 'all'}},
                                       'test': {'targets': ['RockNRollUITests']}}}
info = plistlib.loads((root / 'RockNRoll/Info.plist').read_bytes())
info['CFBundleDisplayName'] = 'Preview Lab'
info.pop('CFBundleURLTypes', None); info.pop('NSUserActivityTypes', None)
(build / 'Info.plist').write_bytes(plistlib.dumps(info))
(build / 'Empty.entitlements').write_bytes(plistlib.dumps({}))
(build / 'project.json').write_text(json.dumps(spec))
subprocess.run(['xcodegen', 'generate', '--spec', str(build / 'project.json'), '--project', str(build)], check=True)
packages = root / '.build/app-device-15003/SourcePackages'
derived = build / 'DerivedData'; derived.mkdir(exist_ok=True)
if not (derived / 'SourcePackages').exists():
    (derived / 'SourcePackages').symlink_to(packages)
print('Build-for-testing with Debug, the PreviewExperiment scheme and physical iPhone destination.')
