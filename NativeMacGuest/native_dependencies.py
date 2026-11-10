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


AUDIO_ROUTE_RECOVERY_PATCHES = (
    "configuration-recovery-guard",
    "default-route-recovery",
)


def audio_route_recovery_lock_paths(repository=REPOSITORY):
    return [repository / "Experiments/WebRTCM156" / f"{name}.lock.json"
            for name in AUDIO_ROUTE_RECOVERY_PATCHES]


def audio_route_recovery_contract(repository=REPOSITORY):
    """Bind the required native fixes to the checked-in patches, not release prose."""
    repository = pathlib.Path(repository)
    base = None
    capabilities, overrides, patches = {}, {}, {}
    for name, lock_path in zip(AUDIO_ROUTE_RECOVERY_PATCHES,
                               audio_route_recovery_lock_paths(repository)):
        lock = json.loads(lock_path.read_text())
        patch_path = lock_path.with_suffix("").with_suffix(".patch")
        relative_patch = patch_path.relative_to(repository).as_posix()
        if (lock.get("formatVersion") != 1 or
                sha256(patch_path) != lock.get("patchSHA256")):
            raise ValueError(f"Audio route patch differs from its lock: {patch_path}")
        if not lock.get("capabilities") or not all(
                value is True for value in lock["capabilities"].values()):
            raise ValueError(f"Audio route patch has invalid capabilities: {lock_path}")
        identity = {key: lock.get(key) for key in (
            "baseFrameworkBinarySHA256", "baseSourceManifestSHA256", "upstreamRevision")}
        if base is None:
            base = identity
        elif identity != base:
            raise ValueError("Audio route patches do not share the same WebRTC baseline")
        # Later patches may intentionally replace an earlier version of a file.
        # Keep the final override and the complete ordered patch sequence.
        capabilities.update(lock["capabilities"])
        overrides.update(lock["sourceOverrides"])
        patches[relative_patch] = lock["patchSHA256"]
    return {**base, "formatVersion": 1, "capabilities": capabilities,
            "sourceOverrides": overrides, "patches": patches}


def verify_audio_route_recovery_framework(root, repository=REPOSITORY):
    """Reject a legacy binary before it can become another direct-release candidate."""
    root = pathlib.Path(root)
    evidence = json.loads((root / "build-evidence.json").read_text())
    contract = audio_route_recovery_contract(repository)
    actual = evidence.get("audioRouteRecovery")
    if actual != contract:
        if not isinstance(actual, dict):
            raise ValueError(
                "Native framework has no audioRouteRecovery evidence. Build a new framework "
                "with both checked-in audio route patches; do not reuse native-framework-screen-r5.")
        for key, expected in contract.items():
            if actual.get(key) != expected:
                raise ValueError(f"Native framework audioRouteRecovery.{key} does not match "
                                 "the checked-in patches; build and verify a new framework")
    if evidence.get("sourceRevision") != contract["upstreamRevision"]:
        raise ValueError("Native framework WebRTC revision differs from the audio route baseline")
    final_manifest = evidence.get("sourceManifestSHA256")
    if (not isinstance(final_manifest, str) or len(final_manifest) != 64 or
            any(character not in "0123456789abcdef" for character in final_manifest) or
            final_manifest == contract["baseSourceManifestSHA256"]):
        raise ValueError("Native framework needs a distinct final source-manifest SHA-256")
    binary = root / "LiveKitWebRTC.xcframework/macos-arm64/LiveKitWebRTC.framework/LiveKitWebRTC"
    if sha256(binary) == contract["baseFrameworkBinarySHA256"]:
        raise ValueError("Native framework reuses the original binary despite audio recovery evidence")
    return contract


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
