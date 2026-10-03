#!/usr/bin/env python3
"""Build an isolated, verified BetterPlayer iOS copy for CocoaPods."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from urllib.parse import unquote, urljoin, urlparse

ROOT = Path(__file__).resolve().parent.parent
PATCHES = ROOT / "patches/better_player_plus"


def find_package(root=ROOT):
    config = root / ".dart_tool/package_config.json"
    for package in json.loads(config.read_text())["packages"]:
        if package["name"] == "better_player_plus":
            uri = urljoin(config.resolve().as_uri(), package["rootUri"])
            if urlparse(uri).scheme != "file":
                raise ValueError("BetterPlayer must resolve to a local package")
            return Path(unquote(urlparse(uri).path))
    raise ValueError("BetterPlayer missing: run flutter pub get first")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(package, output, patches=PATCHES):
    manifest = json.loads((patches / "manifest.json").read_text())
    match = re.search(r"^version:\s*['\"]?([^\s'\"]+)", (package / "pubspec.yaml").read_text(), re.M)
    if not match or match[1] != manifest["version"]:
        raise ValueError("BetterPlayer version does not match the iOS correction")
    # Validate all input before producing a build copy. Never edit the pub cache.
    for name, hashes in manifest["files"].items():
        if digest(package / name) != hashes["original"]:
            raise ValueError(f"Unexpected BetterPlayer source: {name}")
    with tempfile.TemporaryDirectory(prefix="guoguo-ios-player-") as directory:
        stage = Path(directory)
        shutil.copytree(package / "ios", stage / "ios")
        shutil.copy2(package / "LICENSE", stage / "LICENSE")
        patch = (patches / "ios-hls.patch").resolve()
        for options in [["--check"], []]:
            result = subprocess.run(["git", "apply", *options, str(patch)], cwd=stage, capture_output=True, text=True)
            if result.returncode:
                raise ValueError(f"Cannot apply BetterPlayer iOS correction: {result.stderr.strip()}")
        for name, hashes in manifest["files"].items():
            if digest(stage / name) != hashes["patched"]:
                raise ValueError(f"Unexpected patched BetterPlayer source: {name}")
        for name in manifest["extraFiles"]:
            shutil.copy2(patches / name, stage / "ios/better_player_plus/Sources/better_player_plus" / name)
        output.parent.mkdir(parents=True, exist_ok=True)
        if output.is_symlink():
            raise ValueError("Player build directory must not be a symlink")
        if output.exists():
            shutil.rmtree(output)
        shutil.copytree(stage, output)
    return output.resolve()


if __name__ == "__main__":
    print(prepare(find_package(), ROOT / ".dart_tool/ios_player/better_player_plus"))
