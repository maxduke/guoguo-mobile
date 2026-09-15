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
case "$platform" in
  ios)
    mkdir -p "$root/packages/guoguo_core/ios/Frameworks"
    gomobile bind -target=ios,iossimulator -iosversion=15.0 -o "$root/packages/guoguo_core/ios/Frameworks/GuoguoMobile.xcframework" ./mobile
    ;;
  android)
    mkdir -p "$root/packages/guoguo_core/android/libs"
    gomobile bind -target=android/arm64,android/amd64 -androidapi=24 -o "$root/packages/guoguo_core/android/libs/guoguo.aar" ./mobile
    ;;
  *) echo 'Usage: scripts/build_core.sh ios|android' >&2; exit 2 ;;
esac
