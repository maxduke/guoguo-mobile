# BetterPlayer iOS HLS and AirPlay correction

This is a scoped correction to the locked `better_player_plus` 1.4.1 package.
The original code is licensed under Apache 2.0; see [LICENSE](LICENSE).

Apple supports `AVPlayerItem.videoComposition` for file-based media, but [not for
HLS](https://developer.apple.com/documentation/avfoundation/avplayeritem/videocomposition).
The package installs a composition asynchronously for every source. For an EVENT
playlist its duration is also indefinite or still growing, so a moving playback
clock does not establish that video rendering works.

`ios-hls.patch` forwards the existing `formatHint` to iOS and skips that composition
for HLS, including opaque URLs. `AVPlayerLayer` handles rendering and the track's
orientation. File-based video retains the original path, with a finite-duration
guard and current-item check before a late callback assigns its composition.

The AirPlay bridge prepares the existing player after Flutter installs a reachable
relay URL, clears local composition, and prevents late composition callbacks from
restoring it. It presents Apple's video route picker and reports external playback
changes with the player identifier. The native background pause rule permits
AirPlay as well as PiP; ordinary local playback keeps its original behavior.

`scripts/prepare_ios_player.py` checks the exact original and patched file hashes
in `manifest.json`, prepares a copy under `.dart_tool/ios_player`, and adds
`GuoguoMediaPolicy.swift`. CocoaPods uses this copy; the pub cache stays unchanged.
CI compiles the policy's Swift regressions and the full iOS app. The package pin
and source checks must be deliberately updated before using another package version.
