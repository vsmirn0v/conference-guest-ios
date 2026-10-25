"""Standalone standard-library helper sent over SSH; only apply/stage write files."""
import fcntl
import hashlib
import json
import os
import pathlib
import re
import shutil
import stat
import sys

WEB_ROOT = pathlib.Path('/var/www/rocknroll')
PUBLIC_ROOT = WEB_ROOT / 'releases'
STAGING_ROOT = WEB_ROOT / '.publish-stage'
ARTIFACT = re.compile(r'RockNRoll-[A-Za-z0-9][A-Za-z0-9._-]*-[0-9]+-arm64\.dmg')


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def directory(path, create=False, mode=0o755):
    if path.is_symlink():
        raise ValueError('Refusing a symlinked publication directory')
    if path.exists():
        if not path.is_dir() or path.stat().st_uid != os.geteuid():
            raise ValueError('Publication directories must belong to the publishing account')
    elif create:
        path.mkdir(mode=mode)
    if create:
        path.chmod(mode)


def file_hash(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(info.st_mode):
        raise ValueError('Expected a regular publication file')
    return digest(path)


def alias_target(channel):
    alias = PUBLIC_ROOT / channel / 'latest.dmg'
    if not alias.is_symlink():
        if alias.exists():
            raise ValueError('Refusing to replace a regular channel file')
        return None
    target = os.readlink(alias)
    if not target.startswith('../releases/') or not ARTIFACT.fullmatch(target[len('../releases/'):]):
        raise ValueError('Unexpected existing channel symlink target')
    return target


def state():
    return {'appcastSHA256': file_hash(PUBLIC_ROOT / 'appcast.xml'),
            'inventorySHA256': file_hash(PUBLIC_ROOT / 'latest.json'),
            'stableTarget': alias_target('stable'), 'betaTarget': alias_target('beta')}


def validate_layout(create=False):
    directory(WEB_ROOT, create)
    directory(PUBLIC_ROOT, create)
    for name in ['releases', 'stable', 'beta']:
        directory(PUBLIC_ROOT / name, create)
    directory(STAGING_ROOT, create, 0o700)


def preflight(plan):
    validate_layout()
    current = state()
    artifact = plan['artifact']
    if not ARTIFACT.fullmatch(artifact['file']):
        raise ValueError('Invalid immutable artifact filename')
    collision = file_hash(PUBLIC_ROOT / 'releases' / artifact['file'])
    if collision is not None and collision != artifact['sha256']:
        raise ValueError('Immutable artifact collision: existing bytes differ')
    for entry in plan['inventory'].values():
        if not isinstance(entry, dict):
            continue
        filename = entry['file']
        if not ARTIFACT.fullmatch(filename):
            raise ValueError('Invalid inventory artifact filename')
        expected = entry['sha256']
        actual = artifact['sha256'] if filename == artifact['file'] else file_hash(PUBLIC_ROOT / 'releases' / filename)
        if actual != expected:
            raise ValueError('Inventory references a missing or mismatched artifact')
    for entry in plan['feedArtifacts']:
        filename = entry['file']
        if not ARTIFACT.fullmatch(filename):
            raise ValueError('Invalid feed artifact filename')
        path = PUBLIC_ROOT / 'releases' / filename
        if filename != artifact['file'] and (file_hash(path) is None or path.stat().st_size != entry['length']):
            raise ValueError('Feed references an unavailable immutable artifact')
    old_inventory = PUBLIC_ROOT / 'latest.json'
    if old_inventory.exists():
        if old_inventory.stat().st_size > 65536:
            raise ValueError('Existing inventory exceeds its size limit')
        previous = json.loads(old_inventory.read_text())
        for channel in ['stable', 'beta']:
            if channel in previous and int(previous[channel]['build']) > int(plan['inventory'][channel]['build']):
                raise ValueError('Refusing to move a published channel backwards')
    capacity_path = WEB_ROOT if WEB_ROOT.exists() else WEB_ROOT.parent
    free = shutil.disk_usage(capacity_path).free
    if collision is None and 'stageID' not in plan and free < artifact['length'] + 32 * 1024 * 1024:
        raise ValueError('Insufficient free space to stage the immutable artifact')
    return {'state': current, 'immutableAlreadyPresent': collision is not None, 'freeBytes': free}


def stage(plan):
    validate_layout(create=True)
    stage_id = plan['stageID']
    if not re.fullmatch(r'[a-f0-9]{32}', stage_id):
        raise ValueError('Invalid staging identity')
    path = STAGING_ROOT / stage_id
    path.mkdir(mode=0o700)
    return {'stage': str(path)}


def apply(plan):
    validate_layout(create=True)
    stage_id = plan['stageID']
    if not re.fullmatch(r'[a-f0-9]{32}', stage_id):
        raise ValueError('Invalid staging identity')
    staging = STAGING_ROOT / stage_id
    directory(staging)
    lock_fd = os.open(STAGING_ROOT / 'publish.lock', os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(lock_fd, 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        before = preflight(plan)['state']
        if before != plan['expectedState']:
            raise ValueError('Published metadata changed after preflight; inspect and retry')
        artifact = plan['artifact']
        incoming = {'appcast.xml': plan['feedSHA256'], 'latest.json': plan['inventorySHA256'],
                    artifact['file']: artifact['sha256']}
        for name, expected in incoming.items():
            if file_hash(staging / name) != expected:
                raise ValueError('Uploaded file does not match the local verification')
            (staging / name).chmod(0o644)
        backup = staging / 'backup'
        backup.mkdir(mode=0o700)
        for name in ['appcast.xml', 'latest.json']:
            source = PUBLIC_ROOT / name
            if source.exists():
                shutil.copy2(source, backup / name)
                (backup / name).chmod(0o600)
        (backup / 'previous-state.json').write_text(json.dumps(before, indent=2) + '\n')
        (backup / 'previous-state.json').chmod(0o600)
        target = PUBLIC_ROOT / 'releases' / artifact['file']
        if not target.exists():
            try:
                os.link(staging / artifact['file'], target)
            except FileExistsError:
                pass
        if file_hash(target) != artifact['sha256']:
            raise ValueError('Installed immutable artifact failed its hash check')
        target.chmod(0o644)
        # An interrupted promotion always leaves existing feed enclosures readable.
        # Each channel and metadata replacement is atomic; publish the feed last.
        for channel in ['stable', 'beta']:
            temporary = PUBLIC_ROOT / channel / ('.latest.dmg-' + stage_id)
            temporary.symlink_to('../releases/' + plan['inventory'][channel]['file'])
            os.replace(temporary, PUBLIC_ROOT / channel / 'latest.dmg')
        os.replace(staging / 'latest.json', PUBLIC_ROOT / 'latest.json')
        os.replace(staging / 'appcast.xml', PUBLIC_ROOT / 'appcast.xml')
        result = state()
        if result['appcastSHA256'] != plan['feedSHA256'] or result['inventorySHA256'] != plan['inventorySHA256']:
            raise ValueError('Published metadata failed its hash check')
        return {'state': result, 'backupDirectory': str(backup)}


def main():
    if os.geteuid() != 0:
        raise SystemExit('Publication requires the existing root SSH account')
    request = json.loads(sys.argv[1])
    actions = {'preflight': preflight, 'stage': stage, 'apply': apply}
    try:
        print(json.dumps(actions[request['operation']](request['plan'])))
    except (ValueError, OSError, KeyError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == '__main__':
    main()
