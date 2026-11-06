#!/usr/bin/env python3
"""Generate the shared LiveContainer / AltStore / SideStore iOS source."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
from urllib.parse import quote
import zipfile


BUNDLE_ID = "com.maxduke.guoguoMobile"
TINT = "#235849"
ROOT = Path(__file__).resolve().parent.parent


def repository(value):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*", value):
        raise ValueError("Expected a GitHub repository in owner/name form")
    return value


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_package(artifacts, tag, commit):
    """Verify checksums and the identity inside the exact tagged unsigned IPA."""
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise ValueError("Expected a stable vX.Y.Z release tag")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Expected the exact source commit")
    info = json.loads((artifacts / "build-info.json").read_text())
    name, build = info.get("version"), info.get("build")
    if (name, info.get("commit"), info.get("platform"), info.get("signed")) != (tag[1:], commit, "ios", False):
        raise ValueError("Release metadata does not match the tagged unsigned iOS build")
    if not isinstance(build, str) or not re.fullmatch(r"\d+", build):
        raise ValueError("Release build number is missing")
    filename = f"Guoguo-{name}+{build}-ios-unsigned.ipa"
    expected = {filename, "build-info.json"}
    checksums = {}
    for line in (artifacts / "SHA256SUMS").read_text().splitlines():
        checksum, item = line.split("  ", 1)
        if item not in expected or item in checksums or not re.fullmatch(r"[0-9a-f]{64}", checksum):
            raise ValueError("Unexpected or duplicate iOS checksum entry")
        checksums[item] = checksum
    if set(checksums) != expected:
        raise ValueError("Incomplete iOS checksums")
    for item, checksum in checksums.items():
        path = artifacts / item
        if digest(path) != checksum:
            raise ValueError(f"Checksum mismatch: {item}")
    archive = artifacts / filename
    with zipfile.ZipFile(archive) as ipa:
        plists = [item for item in ipa.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info.plist", item)]
        if len(plists) != 1:
            raise ValueError("Expected exactly one iOS app")
        app_path = plists[0].removesuffix("Info.plist")
        if any(item.startswith(app_path + "PlugIns/") and ".appex/" in item for item in ipa.namelist()):
            raise ValueError("Review app-extension permissions before adding this IPA to the source")
        if app_path + "embedded.mobileprovision" in ipa.namelist() or app_path + "_CodeSignature/CodeResources" in ipa.namelist():
            raise ValueError("Expected an unsigned iOS app")
        app = plistlib.loads(ipa.read(plists[0]))
    if (app.get("CFBundleIdentifier"), app.get("CFBundleShortVersionString"), app.get("CFBundleVersion")) != (BUNDLE_ID, name, build):
        raise ValueError("IPA identity does not match the release metadata")
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", app.get("MinimumOSVersion", "")):
        raise ValueError("IPA minimum iOS version is missing")
    return app, filename


def release_notes(release):
    """Use the user-facing change list rather than internal validation footnotes."""
    body = (release.get("body") or "").strip()
    changes = []
    for paragraph in re.split(r"\n\s*\n", body):
        if paragraph.startswith(("- ", "* ")):
            changes.append(paragraph)
        elif changes:
            break
    return "\n\n".join(changes) or body or f"果果 {release['tag_name']}"


def generate(repo, release, app, filename, size):
    repository(repo)
    date = release["published_at"]
    if not date or datetime.fromisoformat(date.replace("Z", "+00:00")).tzinfo is None:
        raise ValueError("Expected a release date with a timezone")
    website = f"https://github.com/{repo}"
    downloads = f"{website}/releases/download/{quote(release['tag_name'], safe='')}"
    icon = f"{downloads}/icon.png"
    version = {
        "version": app["CFBundleShortVersionString"],
        "buildVersion": app["CFBundleVersion"],
        # LiveContainer 3.7/3.8 reads buildNumber; AltStore reads buildVersion.
        "buildNumber": app["CFBundleVersion"],
        "date": date,
        "localizedDescription": release_notes(release),
        "downloadURL": f"{downloads}/{quote(filename, safe='')}",
        "size": size,
        "minOSVersion": app["MinimumOSVersion"],
    }
    permissions = {
        "entitlements": [],
        "privacy": {key: value for key, value in app.items() if key.endswith("UsageDescription")},
    }
    source = {
        "name": "果果",
        "identifier": "com.maxduke.guoguo.source",
        "subtitle": "果果 iPhone / iPad 安装与更新",
        "description": "添加一次，之后在工具中刷新此源即可获取果果新版。",
        "website": website,
        "sourceURL": f"{website}/releases/latest/download/apps.json",
        "iconURL": icon,
        "tintColor": TINT,
        "apps": [{
            "name": "果果",
            "bundleIdentifier": BUNDLE_ID,
            "developerName": "maxduke",
            "subtitle": "短剧发现、追剧与离线观看",
            "localizedDescription": "支持 iPhone 和 iPad，提供短剧发现、搜索、收藏、观看进度、离线下载和电视投屏。安装与更新由你选择的侧载工具完成。",
            "iconURL": icon,
            "tintColor": TINT,
            "category": "entertainment",
            "versions": [version],
            "appPermissions": permissions,
        }],
        "news": [],
    }
    entry = source["apps"][0]
    # Legacy fields keep older source readers and Feather compatible.
    for key in ("version", "downloadURL", "size", "minOSVersion"):
        entry[key] = version[key]
    entry["versionDate"] = version["date"]
    entry["versionDescription"] = version["localizedDescription"]
    return source


def write_source(artifacts, repo, tag, commit, date=None, root=ROOT):
    app, filename = verify_package(artifacts, tag, commit)
    release = {
        "tag_name": tag,
        "published_at": date or datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "body": (root / "releases" / f"{tag}.md").read_text(),
    }
    feed = generate(repo, release, app, filename, (artifacts / filename).stat().st_size)
    icon = root / "ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png"
    (artifacts / "icon.png").write_bytes(icon.read_bytes())
    (artifacts / "apps.json").write_text(json.dumps(feed, ensure_ascii=False, indent=2) + "\n")
    print(f"Generated {app['CFBundleShortVersionString']}+{app['CFBundleVersion']}: {feed['sourceURL']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", type=Path, default=Path("build/release"))
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"), required="GITHUB_REPOSITORY" not in os.environ)
    parser.add_argument("--tag", default=os.environ.get("GITHUB_REF_NAME"), required="GITHUB_REF_NAME" not in os.environ)
    parser.add_argument("--commit", default=os.environ.get("GITHUB_SHA"), required="GITHUB_SHA" not in os.environ)
    parser.add_argument("--date", help="Existing release publication timestamp when adding a source to an older release")
    args = parser.parse_args()
    write_source(args.artifacts, args.repository, args.tag, args.commit, args.date)


if __name__ == "__main__":
    main()
