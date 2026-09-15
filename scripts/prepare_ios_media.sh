#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# Path dependencies in CocoaPods do not execute prepare_command. Prepare the
# locked media package explicitly rather than modifying its generated podspec.
media_path="$(python3 - "$root/.dart_tool/package_config.json" <<'PY'
import json,sys,urllib.parse,pathlib
config=pathlib.Path(sys.argv[1]).resolve()
for package in json.loads(config.read_text())['packages']:
    if package['name']=='ffmpeg_kit_flutter_new_full':
        uri=urllib.parse.urljoin(config.as_uri(),package['rootUri'])
        print(urllib.parse.unquote(urllib.parse.urlparse(uri).path))
        break
else:
    raise SystemExit('Media package missing: run flutter pub get')
PY
)"
cd "$media_path/ios"
bash ../scripts/setup_ios.sh
