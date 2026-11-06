#!/usr/bin/env python3
"""Generate the shared LiveContainer / AltStore / SideStore iOS source."""
import copy
from datetime import datetime
import hashlib
import json
import plistlib
import re
from urllib.parse import quote
import zipfile


BUNDLE_ID = "com.maxduke.guoguoMobile"
TINT = "#235849"


def repository(value):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*", value):
        raise ValueError("Expected a GitHub repository in owner/name form")
    return value


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_package(artifacts, release, commit):
    """Verify the published bytes and the identity inside the unsigned IPA."""
    tag = release["tag_name"]
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag) or release.get("draft") or release.get("prerelease"):
        raise ValueError("Only a published stable release can enter the source")
    published = release.get("published_at")
    if not published:
        raise ValueError("Release publication date is missing")
    datetime.fromisoformat(published.replace("Z", "+00:00"))
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
    assets = {asset["name"]: asset for asset in release["assets"]}
    for item, checksum in checksums.items():
        path = artifacts / item
        if digest(path) != checksum:
            raise ValueError(f"Checksum mismatch: {item}")
        asset = assets[item]
        if asset.get("digest") != f"sha256:{checksum}" or asset["size"] != path.stat().st_size:
            raise ValueError(f"Published asset does not match the verified bytes: {item}")
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


def version_key(item):
    version = item.get("version", "")
    build = item.get("buildVersion", "")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not re.fullmatch(r"\d+", build):
        raise ValueError("Source contains an unsupported version/build")
    return (*map(int, version.split(".")), int(build))


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


def generate(target, release, app, filename, size, previous=None):
    repository(target)
    base = f"https://raw.githubusercontent.com/{target}/main"
    website = f"https://github.com/{target}"
    version = {
        "version": app["CFBundleShortVersionString"],
        "buildVersion": app["CFBundleVersion"],
        # LiveContainer 3.7/3.8 reads buildNumber; AltStore reads buildVersion.
        "buildNumber": app["CFBundleVersion"],
        "date": release["published_at"],
        "localizedDescription": release_notes(release),
        "downloadURL": f"{website}/releases/download/{quote(release['tag_name'], safe='')}/{quote(filename, safe='')}",
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
        "sourceURL": f"{base}/apps.json",
        "iconURL": f"{base}/icon.png",
        "tintColor": TINT,
        "apps": [{
            "name": "果果",
            "bundleIdentifier": BUNDLE_ID,
            "developerName": "maxduke",
            "subtitle": "短剧发现、追剧与离线观看",
            "localizedDescription": "支持 iPhone 和 iPad，提供短剧发现、搜索、收藏、观看进度、离线下载和电视投屏。安装与更新由你选择的侧载工具完成。",
            "iconURL": f"{base}/icon.png",
            "tintColor": TINT,
            "category": "entertainment",
            "versions": [],
            "appPermissions": permissions,
        }],
        "news": [],
    }
    entry = source["apps"][0]
    versions = []
    if previous is not None:
        if previous.get("identifier") != source["identifier"] or previous.get("sourceURL") != source["sourceURL"]:
            raise ValueError("Existing source identity or URL does not match")
        old_apps = previous.get("apps", [])
        if len(old_apps) != 1 or old_apps[0].get("bundleIdentifier") != BUNDLE_ID:
            raise ValueError("Existing source is not the single Guoguo app")
        versions = copy.deepcopy(old_apps[0].get("versions", []))
        if versions and version_key(versions[0]) > version_key(version):
            # Backfilling an older release must not change the newest app permissions.
            entry["appPermissions"] = copy.deepcopy(old_apps[0]["appPermissions"])
    found = [item for item in versions if version_key(item) == version_key(version)]
    if found and found != [version]:
        raise ValueError("Refusing to change a version already present in the source")
    if not found:
        versions.append(version)
    versions.sort(key=version_key, reverse=True)
    entry["versions"] = versions
    latest = versions[0]
    # Legacy fields keep older source readers and Feather compatible.
    for key in ("version", "downloadURL", "size", "minOSVersion"):
        entry[key] = latest[key]
    entry["versionDate"] = latest["date"]
    entry["versionDescription"] = latest["localizedDescription"]
    return source
