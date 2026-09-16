#!/usr/bin/env python3
"""Validate release identity and package the exact unsigned iOS build."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def version(root=ROOT):
    match = re.search(r"^version: (\d+\.\d+\.\d+)\+(\d+)\s*$", (root / "pubspec.yaml").read_text(), re.M)
    if not match:
        raise ValueError("pubspec.yaml must contain version: x.y.z+build")
    return match.groups()


def validate(root=ROOT, tag=None):
    name, build = version(root)
    if tag is not None and tag != f"v{name}":
        raise ValueError(f"Tag {tag!r} does not match pubspec version v{name}")
    notes = root / "releases" / f"v{name}.md"
    if not notes.is_file() or not notes.read_text().strip():
        raise ValueError(f"Release notes are missing: {notes}")
    return name, build


def package(root=ROOT, tag=None):
    name, build = validate(root, tag)
    app = root / "build/ios/iphoneos/Runner.app"
    with (app / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) != (name, build):
        raise ValueError("Built app version/build number does not match pubspec.yaml")
    executable = info.get("CFBundleExecutable", "")
    if not executable or not (app / executable).is_file():
        raise ValueError("Built app executable is missing")
    sha = os.environ.get("GITHUB_SHA", "")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("GITHUB_SHA must identify the exact source commit")
    output = root / "build/release"
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"Guoguo-{name}+{build}-ios-unsigned.ipa"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as target:
        for path in sorted(app.rglob("*")):
            if path.is_file():
                target.write(path, Path("Payload/Runner.app") / path.relative_to(app))
    manifest = output / "build-info.json"
    manifest.write_text(json.dumps({
        "version": name,
        "build": build,
        "commit": sha,
        "platform": "ios",
        "signed": False,
        "run_url": f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{os.environ.get('GITHUB_REPOSITORY', '')}/actions/runs/{os.environ.get('GITHUB_RUN_ID', '')}",
    }, indent=2) + "\n")
    checksums = []
    for path in (archive, manifest):
        with path.open("rb") as source:
            hasher = hashlib.sha256()
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                hasher.update(chunk)
            digest = hasher.hexdigest()
        checksums.append(f"{digest}  {path.name}\n")
    (output / "SHA256SUMS").write_text("".join(checksums))
    print(archive)


def verify(root=ROOT, tag=None, artifacts=Path("release-assets")):
    name, build = validate(root, tag)
    sha = os.environ.get("GITHUB_SHA", "")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("GITHUB_SHA must identify the exact source commit")
    expected = {f"Guoguo-{name}+{build}-ios-unsigned.ipa", "build-info.json"}
    entries = (artifacts / "SHA256SUMS").read_text().splitlines()
    seen = set()
    for entry in entries:
        digest, filename = entry.split("  ", 1)
        if filename not in expected or filename in seen:
            raise ValueError("Unexpected or duplicate release checksum entry")
        seen.add(filename)
        hasher = hashlib.sha256()
        with (artifacts / filename).open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                hasher.update(chunk)
        if hasher.hexdigest() != digest:
            raise ValueError(f"Checksum mismatch: {filename}")
    if seen != expected or {p.name for p in artifacts.iterdir()} != expected | {"SHA256SUMS"}:
        raise ValueError("Release artifact set is incomplete or contains unexpected files")
    info = json.loads((artifacts / "build-info.json").read_text())
    if (info.get("version"), info.get("build"), info.get("commit"), info.get("platform"), info.get("signed")) != (name, build, sha, "ios", False):
        raise ValueError("Release artifact identity does not match the tagged source")
    print(f"Verified {name}+{build} at {sha}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["validate", "package", "verify"])
    parser.add_argument("--artifacts", type=Path, default=Path("release-assets"))
    args = parser.parse_args()
    tag = os.environ.get("GITHUB_REF_NAME") if os.environ.get("GITHUB_REF_TYPE") == "tag" else None
    if args.command == "package":
        package(tag=tag)
    elif args.command == "verify":
        verify(tag=tag, artifacts=args.artifacts)
    else:
        name, build = validate(tag=tag)
        print(f"Validated {name}+{build}")


if __name__ == "__main__":
    main()
