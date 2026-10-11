#!/usr/bin/env python3
"""Export only numeric power-impact data; reject missing phase coverage."""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('directory', type=Path)
a = p.parse_args()
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
def export(filename, schema=None):
    cmd = ['xcrun', 'xctrace', 'export', '--input', str(a.directory / 'power.trace'), '--output', str(a.directory / filename)]
    cmd += ['--xpath', '/trace-toc/run[@number="1"]/data/table[@schema="' + schema + '"]'] if schema else ['--toc']
    subprocess.run(cmd, env=env, check=True, stdout=subprocess.DEVNULL)
    return ET.parse(a.directory / filename).getroot()

toc = export('toc.xml')
start = datetime.fromisoformat(toc.findtext('.//start-date')).timestamp()
end = datetime.fromisoformat(toc.findtext('.//end-date')).timestamp()
phases = [json.loads(line) for line in (a.directory / 'measurements.jsonl').read_text().splitlines()]
phases = [row for row in phases if start <= row['wall_start_s'] < row['wall_end_s'] <= end]
if len(phases) != 2:
    raise ValueError('Expected two full phases inside the actual recording')

def rows(filename, schema):
    root = export(filename, schema)
    refs = {node.attrib['id']: node for node in root.iter() if 'id' in node.attrib}
    def resolve(node):
        while 'ref' in node.attrib:
            node = refs[node.attrib['ref']]
        return node
    names = [col.findtext('mnemonic') for col in root.findall('.//schema/col')]
    for row in root.iter('row'):
        yield {name: resolve(value) for name, value in zip(names, row)}

power = list(rows('process.xml', 'ProcessSubsystemPowerImpact'))
system = list(rows('system.xml', 'SystemPowerLevel'))
for phase in phases:
    expected = phase['requested_fps']
    if abs(phase['capture_fps'] - expected) > expected * 0.02 or phase['actual_sensor_fps'] != expected:
        raise ValueError('Requested cadence was not delivered')
    if phase['invalid_capture_timestamps'] or phase['low_power'] or phase['thermal_end'] != 0:
        raise ValueError('Clock, power or thermal confound')
    if phase['surface'] == 'pip' and abs(phase['pip_enqueue_fps'] - expected) > expected * 0.02:
        raise ValueError('PiP did not deliver the requested cadence')
    begin, finish = phase['wall_start_s'], phase['wall_end_s']
    duration = finish - begin
    samples = []
    for row in power:
        t = start + float(row['start'].text) / 1e9
        length = float(row['duration'].text) / 1e9
        overlap = max(0, min(finish, t + length) - max(begin, t))
        if overlap > 0:
            samples.append((overlap, row))
    phase['power_sample_coverage_s'] = {}
    # CPU/display and GPU use independent, overlapping row streams. Sentinel
    # fields mean unavailable, not zero; weight each metric over its own stream.
    for name in ['cpu-impact', 'gpu-impact', 'display-impact', 'networking-impact']:
        values = [(weight, float(row[name].text)) for weight, row in samples if row[name].text is not None]
        coverage = sum(weight for weight, value in values)
        phase['power_sample_coverage_s'][name] = coverage
        if not values and name == 'networking-impact':
            phase[name.replace('-', '_')] = None
            continue
        if coverage < duration * 0.95 or coverage > duration * 1.05:
            raise ValueError('Incomplete or overlapping metric coverage: ' + name + ' ' + str(coverage))
        phase[name.replace('-', '_')] = sum(weight * value for weight, value in values) / coverage
    phase['cpu_percent_one_core'] = phase['cpu_seconds'] / duration * 100
    device_samples = []
    for row in system:
        t = start + float(row['start'].text) / 1e9
        length = float(row['duration'].text) / 1e9
        overlap = max(0, min(finish, t + length) - max(begin, t))
        if overlap > 0: device_samples.append((overlap, row))
    system_coverage = sum(weight for weight, row in device_samples)
    if system_coverage < duration * 0.95:
        raise ValueError('Incomplete system power coverage')
    consumption = sum(weight * float(row['power-usage'].text) for weight, row in device_samples) / system_coverage
    phase['system_percent_per_hour'] = consumption if consumption > 0 else None
    phase['system_power_unavailable_while_charging'] = consumption == 0
    phase['system_brightness_percent'] = sum(weight * float(row['display-brightness'].text) for weight, row in device_samples) / system_coverage
(a.directory / 'results.json').write_text(json.dumps(phases, indent=2) + '\n')
print(json.dumps(phases, indent=2))
