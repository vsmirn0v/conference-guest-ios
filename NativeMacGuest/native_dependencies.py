"""Pinned native SDK provisioning, independent of an author's build directory."""
import hashlib
import json
import os
import pathlib
import plistlib
import subprocess
import tarfile
import tempfile


REPOSITORY = pathlib.Path(__file__).resolve().parents[1]
SDK_REVISION = "57a84d71c33e97349963c1cbd442fb4b01428b7c"
SDK_URL = "https://github.com/livekit/client-sdk-swift.git"


def sha256(path):
    result = hashlib.sha256()
    with pathlib.Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def sdk_lock(repository=REPOSITORY):
    return json.loads((repository / "Dependencies/native-macos/sdk.lock.json").read_text())


def default_framework_root(repository=REPOSITORY):
    return repository / sdk_lock(repository)["destination"]


def verify_framework(root, lock):
    """Verify public headers, module maps, binary and matching build evidence."""
    framework = root / "LiveKitWebRTC.xcframework"
    actual = set()
    for directory, folders, files in os.walk(framework, followlinks=False):
        for name in folders + files:
            path = pathlib.Path(directory) / name
            if path.is_symlink() or path.is_file():
                actual.add(path.relative_to(root).as_posix())
    expected_files = {name for name in lock["files"] if name.startswith("LiveKitWebRTC.xcframework/")}
    if actual != expected_files:
        raise ValueError("Native SDK framework contents differ from the committed file inventory")
    for name, expected in lock["files"].items():
        path = root / name
        if expected["type"] == "symlink":
            valid = path.is_symlink() and os.readlink(path) == expected["target"]
        else:
            valid = not path.is_symlink() and path.is_file() and sha256(path) == expected["sha256"]
        if not valid:
            raise ValueError(f"Native SDK differs from its lock: {path}; preserve it and use a new destination")
    info = plistlib.loads((root / "LiveKitWebRTC.xcframework/Info.plist").read_bytes())
    libraries = info.get("AvailableLibraries", [])
    if len(libraries) != 1 or libraries[0].get("SupportedPlatform") != "macos" or libraries[0].get("SupportedArchitectures") != ["arm64"]:
        raise ValueError("The pinned native SDK must contain exactly the macOS arm64 slice")
    evidence = json.loads((root / "build-evidence.json").read_text())
    if evidence["frameworkBinarySHA256"] != lock["frameworkBinarySHA256"]:
        raise ValueError("Native SDK build evidence does not match its locked binary")


def ensure_framework(destination=None, repository=REPOSITORY):
    lock = sdk_lock(repository)
    canonical = (repository / lock["destination"]).resolve()
    destination = canonical if destination is None else pathlib.Path(destination).resolve()
    if destination.exists():
        if destination == canonical:
            verify_framework(destination, lock)
        return destination
    if destination != canonical:
        raise ValueError(f"Custom SDK is missing: {destination}. Run NativeMacGuest/bootstrap.py for the committed SDK, or supply your custom framework and build-evidence.json")
    archive = repository / "Dependencies/native-macos" / lock["archive"]
    if sha256(archive) != lock["archiveSHA256"]:
        raise ValueError(f"Native SDK archive checksum failed: {archive}")
    if not hasattr(tarfile, "data_filter"):
        raise ValueError("SDK extraction requires Python 3.12+ (brew install python)")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".native-sdk-", dir=destination.parent) as temporary:
        staging = pathlib.Path(temporary) / "sdk"
        staging.mkdir()
        with tarfile.open(archive, "r:gz") as source:
            source.extractall(staging, filter="data")
        verify_framework(staging, lock)
        # Never merge into, or replace, an existing build dependency.
        if destination.exists():
            verify_framework(destination, lock)
        else:
            staging.rename(destination)
    return destination


def _source_git(path, *arguments):
    return subprocess.check_output(["git", "-C", str(path), *arguments], text=True,
                                   env={**os.environ, "GIT_TERMINAL_PROMPT": "0"}).strip()


def ensure_livekit_source(repository=REPOSITORY):
    destination = repository / f".build/native-sdk/client-sdk-swift-{SDK_REVISION}"
    if not destination.exists():
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".livekit-", dir=destination.parent) as temporary:
            staging = pathlib.Path(temporary) / "source"
            subprocess.run(["git", "init", "--quiet", str(staging)], check=True)
            subprocess.run(["git", "-C", str(staging), "config", "core.autocrlf", "false"], check=True)
            subprocess.run(["git", "-C", str(staging), "fetch", "--quiet", "--depth=1", SDK_URL, SDK_REVISION],
                           check=True, timeout=180, env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})
            # Populate this new dependency checkout without switching any project branch.
            subprocess.run(["git", "-C", str(staging), "read-tree", "--reset", "-u", "FETCH_HEAD"], check=True)
            subprocess.run(["git", "-C", str(staging), "update-ref", "HEAD", SDK_REVISION], check=True)
            if not destination.exists():
                staging.rename(destination)
    if _source_git(destination, "rev-parse", "HEAD") != SDK_REVISION:
        raise ValueError(f"Wrong LiveKit source revision at {destination}; refusing to overwrite it")
    if _source_git(destination, "status", "--porcelain", "--untracked-files=all"):
        raise ValueError(f"LiveKit source has local changes at {destination}; refusing to overwrite them")
    return destination
