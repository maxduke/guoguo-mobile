#!/usr/bin/env python3
"""Prepare the pinned Dart player override without changing the shared pub cache."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
from urllib.request import urlopen

from prepare_ios_player import digest

ROOT = Path(__file__).resolve().parent.parent
PATCHES = ROOT / "patches/better_player_plus"


def prepare(archive, output, patches=PATCHES):
    manifest = json.loads((patches / "polling-manifest.json").read_text())
    if digest(archive) != manifest["archiveSha256"]:
        raise ValueError("Unexpected BetterPlayer archive checksum")
    if output.is_symlink():
        raise ValueError("Player build directory must not be a symlink")
    with tempfile.TemporaryDirectory(prefix="guoguo-player-") as directory:
        stage = Path(directory)
        with tarfile.open(archive) as package:
            package.extractall(stage, filter="data")
        match = re.search(r"^version:\s*['\"]?([^\s'\"]+)", (stage / "pubspec.yaml").read_text(), re.M)
        if not match or match[1] != manifest["version"]:
            raise ValueError("BetterPlayer version does not match the polling correction")
        for name, hashes in manifest["files"].items():
            if digest(stage / name) != hashes["original"]:
                raise ValueError(f"Unexpected BetterPlayer source: {name}")
        patch = (patches / "dart-polling.patch").resolve()
        for options in [["--check"], []]:
            result = subprocess.run(["git", "apply", *options, str(patch)], cwd=stage, capture_output=True, text=True)
            if result.returncode:
                raise ValueError(f"Cannot apply BetterPlayer polling correction: {result.stderr.strip()}")
        for name, hashes in manifest["files"].items():
            if digest(stage / name) != hashes["patched"]:
                raise ValueError(f"Unexpected patched BetterPlayer source: {name}")
        output.parent.mkdir(parents=True, exist_ok=True)
        if output.exists():
            shutil.rmtree(output)
        shutil.copytree(stage, output)
    return output.resolve()


def setup(root=ROOT, patches=PATCHES):
    # Other local overrides remain untouched. A conflicting player override must
    # be resolved explicitly instead of silently building the uncorrected SDK.
    overrides = root / "pubspec_overrides.yaml"
    if overrides.exists() and re.search(r"(?:^|[\s{,])['\"]?better_player_plus['\"]?\s*:", overrides.read_text()):
        raise ValueError("pubspec_overrides.yaml overrides better_player_plus; remove that entry to use the verified polling correction (file unchanged)")
    manifest = json.loads((patches / "polling-manifest.json").read_text())
    directory = root / ".dart_tool/player"
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory / f"better_player_plus-{manifest['version']}.tar.gz"
    if not archive.exists():
        url = f"https://pub.dev/api/archives/{archive.name}"
        # Verify before persisting any downloaded input. Existing corrupt input
        # is rejected by prepare(), not silently replaced.
        with urlopen(url, timeout=60) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != manifest["archiveSha256"]:
            raise ValueError("Unexpected downloaded BetterPlayer archive checksum")
        archive.write_bytes(data)
    return prepare(archive, directory / "better_player_plus", patches)


if __name__ == "__main__":
    print(setup())
