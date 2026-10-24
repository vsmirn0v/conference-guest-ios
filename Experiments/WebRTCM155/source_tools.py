"""Pinned M155 source identity; dependency checkouts are a separate contract."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import tarfile

SOURCE_SHA = "623fcfe044d5037b3ecd92001c2ef80ca1d932d5"
ARCHIVE_SHA256 = "2b7d74ad4d5a3050ff71a8b2b5af86fadaab7576c24c02ab3a2de2a63692f437"
ARCHIVE_ROOT = "jitsi-webrtc-623fcfe"
HERE = Path(__file__).resolve().parent


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def relative_path(value):
    if not isinstance(value, str) or not value or "\\" in value or "\0" in value:
        raise ValueError(f"Invalid relative path: {value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in (".", "..") for part in value.split("/")):
        raise ValueError(f"Invalid relative path: {value!r}")
    if path.as_posix() != value or path.parts[0] == ".git":
        raise ValueError(f"Invalid source path: {value!r}")
    return path


def checked_input(root, item, label):
    path = root / relative_path(item["path"])
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root):
        raise ValueError(f"Missing or unsafe {label}: {path}")
    if digest(path) != item["sha256"]:
        raise ValueError(f"Identity mismatch: {label}")
    return path


def load_lock(lock_path=None):
    path = Path(lock_path or HERE / "m155-lock.json").resolve(strict=True)
    lock = json.loads(path.read_text())
    if (lock.get("schema_version") != 1 or lock.get("source_sha") != SOURCE_SHA or
            lock.get("source_archive_sha256") != ARCHIVE_SHA256):
        raise ValueError("Lock does not identify the pinned pristine M155 source")
    if lock["patch"]["path"] != "m155-port.patch":
        raise ValueError("Expected the single cumulative m155-port.patch")
    root = path.parent
    patch = checked_input(root, lock["patch"], "cumulative patch")
    manifest_path = checked_input(root, lock["source_manifest"], "source manifest")
    manifest = json.loads(manifest_path.read_text())
    if (manifest.get("schema_version") != 1 or manifest.get("source_sha") != SOURCE_SHA or
            manifest.get("source_archive_sha256") != ARCHIVE_SHA256 or
            manifest.get("patch_sha256") != lock["patch"]["sha256"]):
        raise ValueError("Source manifest provenance does not match the lock")
    entries = manifest["entries"]
    if not entries:
        raise ValueError("Empty source manifest")
    for name, entry in entries.items():
        relative_path(name)
        if entry.get("type") not in ("file", "symlink", "directory"):
            raise ValueError(f"Invalid manifest entry: {name}")
    dependencies = lock["dependencies"]
    deps = checked_input(root, dependencies["deps"], "dependency DEPS")
    gclient = checked_input(root, dependencies["gclient"], "gclient configuration")
    roots = dependencies["roots"]
    if len(set(roots)) != len(roots):
        raise ValueError("Duplicate dependency roots")
    for name in roots:
        prefix = str(relative_path(name)) + "/"
        if any(item == name or item.startswith(prefix) for item in entries):
            raise ValueError(f"Dependency root overlaps locked source: {name}")
    return lock, entries, roots, patch, deps, gclient


def tree_entries(source, dependency_roots=(), known_entries=()):
    source = Path(source)
    if source.is_symlink() or not source.is_dir():
        raise ValueError("Source must be a real directory")
    roots = set(dependency_roots)
    containers = {parent.as_posix() for name in roots
                  for parent in PurePosixPath(name).parents if parent.as_posix() != "."}
    result = {}

    def visit(directory):
        for path in sorted(directory.iterdir()):
            name = path.relative_to(source).as_posix()
            if name == ".git" or name in roots:
                continue
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                result[name] = {"type": "symlink", "target": os.readlink(path)}
            elif stat.S_ISDIR(mode):
                if name not in containers or name in known_entries:
                    result[name] = {"type": "directory"}
                visit(path)
            elif stat.S_ISREG(mode):
                result[name] = {"type": "file", "sha256": digest(path),
                                "executable": bool(mode & 0o111)}
            else:
                raise ValueError(f"Unsupported source entry: {name}")
    visit(source)
    return result


def verify(source, lock_path=None):
    lock, expected, roots, _, _, _ = load_lock(lock_path)
    actual = tree_entries(source, roots, expected)
    missing, extra = sorted(expected.keys() - actual.keys()), sorted(actual.keys() - expected.keys())
    changed = sorted(name for name in expected.keys() & actual.keys()
                     if expected[name] != actual[name])
    if missing or extra or changed:
        raise ValueError(f"Source mismatch: missing={missing[:10]}, extra={extra[:10]}, changed={changed[:10]}")
    return {"source_sha": SOURCE_SHA, "source_archive_sha256": ARCHIVE_SHA256,
            "patch_sha256": lock["patch"]["sha256"],
            "source_manifest_sha256": lock["source_manifest"]["sha256"],
            "source_entries": len(expected), "dependency_roots_not_verified": roots}


def archive_members(archive):
    seen = set()
    for member in archive:
        name = PurePosixPath(member.name)
        if name.as_posix() == ARCHIVE_ROOT:
            if not member.isdir():
                raise ValueError("Invalid archive root")
            continue
        if not name.parts or name.parts[0] != ARCHIVE_ROOT:
            raise ValueError("Unexpected source archive root")
        relative = "/".join(name.parts[1:])
        relative_path(relative)
        if relative in seen or not (member.isfile() or member.isdir() or member.issym()):
            raise ValueError(f"Duplicate or unsupported archive member: {relative}")
        seen.add(relative)
        yield relative, member


def check_archive(path):
    if digest(path) != ARCHIVE_SHA256:
        raise ValueError("Pristine M155 archive identity mismatch")


def prepare(archive_path, output, lock_path=None):
    lock, _, _, patch, deps, gclient = load_lock(lock_path)
    check_archive(archive_path)
    output = Path(output).absolute()
    if output.exists() or output.is_symlink():
        raise ValueError(f"Output already exists: {output}")
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    source = output / "src"
    source.mkdir()
    links = []
    with tarfile.open(archive_path) as archive:
        for name, member in archive_members(archive):
            destination = source / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            if member.isdir():
                destination.mkdir(exist_ok=True)
            elif member.issym():
                links.append((name, member.linkname))
            else:
                with destination.open("xb") as stream:
                    shutil.copyfileobj(archive.extractfile(member), stream)
                destination.chmod(0o755 if member.mode & 0o111 else 0o644)
    # Create symlinks last so archive writes cannot traverse a symlink ancestor.
    for name, target in links:
        path = source / name
        if PurePosixPath(target).is_absolute() or not (path.parent / target).resolve().is_relative_to(source):
            raise ValueError(f"Source symlink escapes output: {name}")
        path.symlink_to(target)
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env["GIT_CEILING_DIRECTORIES"] = str(output)
    subprocess.run(["git", "apply", "--check", str(patch)], cwd=source, env=env, check=True)
    subprocess.run(["git", "apply", str(patch)], cwd=source, env=env, check=True)
    evidence = verify(source, lock_path)
    shutil.copy2(deps, output / "DEPS")
    shutil.copy2(gclient, output / ".gclient")
    evidence["dependency_deps_sha256"] = lock["dependencies"]["deps"]["sha256"]
    evidence["gclient_configuration_sha256"] = lock["dependencies"]["gclient"]["sha256"]
    (output / "source-provenance.json").write_text(json.dumps(evidence, indent=2) + "\n")
    return source
