# BetterPlayer iOS HLS correction

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

AirPlay now belongs exclusively to the separate AVQueuePlayer/AVKit bridge in
`guoguo_core`. This local player permanently disables external video. Its play
entry point and delayed native resume path reject a selected AirPlay audio route
with `airplay_route`, closing the route-query/play race. A process-local exclusion
flag also silently holds local playback while the independent queue owns media,
even before a TV is selected. Public begin/end notifications update this flag;
end is posted only after native pause and media/observer detachment. Stale SDK
play calls are acknowledged while held, so unawaited internal commands do not
become unhandled errors. Plugin detachment removes the notification observers. Handoff also removes only
BetterPlayer's remote-command tokens and every local Now Playing timer. Pending
artwork/timer callbacks carry a generation and source check, so they cannot
republish old local metadata after AVKit takes ownership. Local disposal during
the native session leaves AVKit's metadata and shared audio session intact;
ordinary local play reinstalls the original SDK notification controls afterward. The Flutter page must
wait for a real local route before resuming. The former BetterPlayer AirPlay
channel, item handoff, completion inference, and routing state have been removed;
local HLS and PiP continue to use the established baseline.

`scripts/prepare_ios_player.py` checks the exact original and patched file hashes
in `manifest.json`, prepares a copy under `.dart_tool/ios_player`, and adds
`GuoguoMediaPolicy.swift`. CocoaPods uses this copy; the pub cache stays unchanged.
CI compiles the policy's Swift regressions and the full iOS app. The package pin
and source checks must be deliberately updated before using another package version.
