#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
platform="${1:-ios}"
export PATH="$(go env GOPATH)/bin:$PATH"
cd "$root/native/core"
if ! command -v gomobile >/dev/null 2>&1; then
  echo 'Install the pinned gomobile tool using scripts/setup_core.sh first.' >&2
  exit 1
fi
source_digest="$(python3 "$root/scripts/core_identity.py" digest)"
version="$(cd "$root" && python3 -c 'from scripts.release import version; name, build = version(); print(name + "+" + build)')"
ldflags="-X juku/internal/app.mobileSourceDigest=$source_digest -X juku/internal/app.mobileBuildVersion=$version"
case "$platform" in
  ios)
    mkdir -p "$root/packages/guoguo_core/ios/Frameworks"
    artifact="$root/packages/guoguo_core/ios/Frameworks/GuoguoMobile.xcframework"
    gomobile bind -ldflags "$ldflags" -target=ios,iossimulator -iosversion=15.0 -o "$root/packages/guoguo_core/ios/Frameworks/GuoguoMobile.xcframework" ./mobile
    ;;
  android)
    mkdir -p "$root/packages/guoguo_core/android/libs"
    artifact="$root/packages/guoguo_core/android/libs/guoguo.aar"
    gomobile bind -ldflags "$ldflags" -target=android/arm64,android/amd64 -androidapi=24 -o "$root/packages/guoguo_core/android/libs/guoguo.aar" ./mobile
    ;;
  *) echo 'Usage: scripts/build_core.sh ios|android' >&2; exit 2 ;;
esac

python3 "$root/scripts/core_identity.py" write --artifact "$artifact" --manifest "$artifact.manifest.json" --platform "$platform"
python3 "$root/scripts/core_identity.py" verify --artifact "$artifact" --manifest "$artifact.manifest.json" --platform "$platform"
