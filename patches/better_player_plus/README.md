# BetterPlayer Dart polling and iOS HLS corrections

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


`dart-polling.patch` fixes overlapping asynchronous play commands installing
multiple 300 ms position timers on the same player. A generation owns the timer
and its in-flight results. Pause, completion, source replacement, seek, errors and
disposal invalidate it before asynchronous work can resume. Only one position /
absolute-position request pair may be in flight, even across source changes.
Late seek completion cannot restore superseded play intent or update a new source.
Disposal cancels polling immediately and does not wait for outstanding play or
position replies; repeated disposal shares the same cleanup future.

`scripts/prepare_player.py` verifies the original pub.dev archive checksum and
both source hashes in `polling-manifest.json`, then generates the full dependency
under `.dart_tool/player`. The checked-in `pubspec.yaml` path override makes normal
pub resolution retain this correction. Run preparation before the first
`flutter pub get`, and again after `flutter clean`. CI and the shared iOS build
perform this step automatically. A failed verification leaves an existing build
copy untouched and fails the setup command. No shared pub cache files or personal
pub overrides are modified. The existing iOS preparation still applies its own
verified patch to the generated dependency's unchanged native sources.

`test/player_polling_test.dart` exercises the actual dependency with gated native
play/position replies, source changes, native play/pause events, disposal and 80
successive episodes. Widget-test timer checks also reject leaked polling timers.
