#!/usr/bin/env python3
"""Mirror verified iOS release assets, then atomically advance the public source."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

import ios_source


ROOT = Path(__file__).resolve().parent.parent


def gh(arguments, token=None, payload=None, missing=False):
    environment = os.environ.copy()
    if token:
        environment["GH_TOKEN"] = token
    result = subprocess.run(["gh", *arguments], input=None if payload is None else json.dumps(payload),
                            env=environment, capture_output=True, text=True)
    if result.returncode:
        if missing and "(HTTP 404)" in result.stderr:
            return None
        raise RuntimeError(result.stderr.strip() or "GitHub request failed")
    return result.stdout


def api(path, token=None, payload=None, missing=False):
    arguments = ["api", path]
    if payload is not None:
        arguments += ["--method", "PUT", "--input", "-"]
    data = gh(arguments, token, payload, missing)
    return None if data is None else json.loads(data)


def put_file(target, path, content, token, message):
    endpoint = f"repos/{target}/contents/{path}"
    current = api(endpoint + "?ref=main", token, missing=True)
    encoded = base64.b64encode(content).decode()
    if current and base64.b64decode(current["content"]) == content:
        return
    payload = {"message": message, "branch": "main", "content": encoded}
    if current:
        payload["sha"] = current["sha"]
    api(endpoint, token, payload)


def tag_commit(source, tag):
    value = api(f"repos/{source}/git/ref/tags/{tag}")["object"]
    for _ in range(4):
        if value["type"] == "commit":
            return value["sha"]
        if value["type"] != "tag":
            break
        value = api(f"repos/{source}/git/tags/{value['sha']}")["object"]
    raise ValueError("Release tag does not resolve to a source commit")


def readme(target):
    url = f"https://raw.githubusercontent.com/{target}/main/apps.json"
    return f"""# 果果 iOS 安装源

在 LiveContainer 3.7+、SideStore、AltStore Classic 或兼容 AltStore 源的工具中添加：

```
{url}
```

只需添加一次。以后刷新源，选择果果的新版本进行更新；更新时保留现有应用及数据，不要先卸载。

此仓库仅用于分发果果的未签名 IPA、校验信息、图标和安装源。LiveContainer 使用其自身的安装与签名流程；SideStore / AltStore Classic 使用你的账户签名安装。源不会代替签名工具，也不负责续签宿主或证书。

手动下载请打开 [最新版本](https://github.com/{target}/releases/latest)，文件完整性可用同页 `SHA256SUMS` 核对。

源索引始终在安装包上传并通过校验后更新。每个版本链接固定到对应的 Release，不会用变化中的“最新版 IPA”冒充旧版本。
""".encode()


def publish(source, target, tag=None, dry_run=False, output=Path("build/ios-source")):
    ios_source.repository(source)
    ios_source.repository(target)
    if source == target:
        raise ValueError("Use a separate public distribution repository")
    token = os.environ.get("IOS_SOURCE_TOKEN")
    destination = api(f"repos/{target}", token, missing=dry_run)
    if destination and (destination.get("private") or destination["default_branch"] != "main"):
        raise ValueError("The distribution repository must be public and use main")
    if tag is not None and not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise ValueError("Expected a stable vX.Y.Z release tag")
    release = api(f"repos/{source}/releases/{'latest' if tag is None else 'tags/' + tag}")
    tag = release["tag_name"]
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag) or release.get("draft") or release.get("prerelease"):
        raise ValueError("Only a published stable release can enter the source")
    commit = tag_commit(source, tag)
    previous_file = api(f"repos/{target}/contents/apps.json?ref=main", token, missing=True) if destination else None
    previous = json.loads(base64.b64decode(previous_file["content"])) if previous_file else None
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="guoguo-ios-source-") as temporary:
        artifacts = Path(temporary)
        gh(["release", "download", tag, "--repo", source, "--pattern", "build-info.json", "--dir", temporary])
        info = json.loads((artifacts / "build-info.json").read_text())
        name, build = info.get("version", ""), info.get("build", "")
        if not re.fullmatch(r"\d+\.\d+\.\d+", name) or not re.fullmatch(r"\d+", build):
            raise ValueError("Invalid release version/build metadata")
        filename = f"Guoguo-{name}+{build}-ios-unsigned.ipa"
        gh(["release", "download", tag, "--repo", source, "--pattern", filename,
            "--pattern", "SHA256SUMS", "--dir", temporary])
        app, filename = ios_source.verify_package(artifacts, release, commit)
        feed = ios_source.generate(target, release, app, filename, (artifacts / filename).stat().st_size, previous)
        content = (json.dumps(feed, ensure_ascii=False, indent=2) + "\n").encode()
        (output / "apps.json").write_bytes(content)
        (output / "README.md").write_bytes(readme(target))
        icon = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png"
        (output / "icon.png").write_bytes(icon.read_bytes())
        if dry_run:
            print(f"Verified {name}+{build}; source preview: {output / 'apps.json'} (nothing published)")
            return
        put_file(target, "README.md", readme(target), token, "docs: explain the iOS installation source")
        put_file(target, "icon.png", icon.read_bytes(), token, "chore: update Guoguo icon")
        mirrored = api(f"repos/{target}/releases/tags/{tag}", token, missing=True)
        expected = {item: ios_source.digest(artifacts / item) for item in (filename, "build-info.json", "SHA256SUMS")}
        if mirrored and not mirrored["draft"]:
            actual = {asset["name"]: asset.get("digest") for asset in mirrored["assets"]}
            if actual != {item: f"sha256:{checksum}" for item, checksum in expected.items()}:
                raise ValueError("Refusing to overwrite a published mirror with different assets")
        else:
            if mirrored is None:
                notes = output / "release-notes.md"
                notes.write_text(ios_source.release_notes(release))
                gh(["release", "create", tag, "--repo", target, "--target", "main", "--draft",
                    "--title", f"果果 {tag}", "--notes-file", str(notes)], token)
            gh(["release", "upload", tag, "--repo", target, "--clobber",
                *[str(artifacts / item) for item in expected]], token)
            uploaded = api(f"repos/{target}/releases/tags/{tag}", token)
            actual = {asset["name"]: asset.get("digest") for asset in uploaded["assets"]}
            if actual != {item: f"sha256:{checksum}" for item, checksum in expected.items()}:
                raise ValueError("Mirror asset verification failed; release remains a draft")
            is_latest = feed["apps"][0]["versions"][0]["version"] == name
            gh(["release", "edit", tag, "--repo", target, "--draft=false", f"--latest={'true' if is_latest else 'false'}"], token)
        # The conditional SHA update prevents a concurrent publisher from losing another version.
        payload = {"message": f"chore: publish iOS source for {name}+{build}", "branch": "main",
                   "content": base64.b64encode(content).decode()}
        if previous_file:
            payload["sha"] = previous_file["sha"]
        if previous_file is None or base64.b64decode(previous_file["content"]) != content:
            api(f"repos/{target}/contents/apps.json", token, payload)
        print(f"Published {name}+{build}: https://raw.githubusercontent.com/{target}/main/apps.json")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default=os.environ.get("GITHUB_REPOSITORY", "maxduke/guoguo-mobile"))
    parser.add_argument("--target", required=True, help="Public binary-only GitHub repository (owner/name)")
    parser.add_argument("--tag", help="Published vX.Y.Z tag; defaults to latest")
    parser.add_argument("--dry-run", action="store_true", help="Verify and generate a preview without writing to GitHub")
    parser.add_argument("--output", type=Path, default=Path("build/ios-source"))
    args = parser.parse_args()
    publish(args.source, args.target, args.tag, args.dry_run, args.output)


if __name__ == "__main__":
    main()
