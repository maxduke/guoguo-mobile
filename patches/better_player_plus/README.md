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

The AirPlay bridge keeps connection intent on the player across episode changes.
A new player starts with external video disabled. After Flutter installs a
receiver-readable HTTP(S) relay, `prepareAirPlay` clears local composition and
enables external playback. Replacing that item preserves this intent and does not
toggle `allowsExternalPlayback`; late composition callbacks cannot undo it.
The new item directly replaces the old one without an intermediate empty player.
The old item is detached before `setDataSource` returns, allowing Flutter to close
its relay after installation completes.

The `guoguo/airplay` method contract is:

- `getAirPlayState` without `textureId` works before the first asset exists and
  returns the actual system audio route with `active: false`.
- With `textureId`, `getAirPlayState` and `prepareAirPlay` return `active`
  (`AVPlayer.isExternalPlaybackActive`), `routed` (an AirPlay output in
  `AVAudioSession.currentRoute`), `prepared`, nullable `sourceUrl`, and integer
  `sourceRevision`. `externalPlaybackChanged` sends the same fields plus
  `textureId`; obsolete queued video callbacks are dropped after source changes.
- `releaseAirPlay` pauses, removes item observers, cancels pending seeks, detaches
  the item, and disables external video before returning the current state.
  Flutter may then close the relay. Disposal performs the same media detachment.
- `showAirPlayRoutes` presents Apple's route picker, including while detached.
  Explicit return to the phone waits for a real local audio route before Flutter
  reinstalls local media.

Apple distinguishes [external video playback](https://developer.apple.com/documentation/avfoundation/avplayer/allowsexternalplayback)
from the [system audio route](https://developer.apple.com/documentation/avfaudio/avaudiosession/currentroute).
Disabling external video does **not** disconnect that audio route, and `routed`
never depends on this player's preparation state. Source installation rejects a
local/loopback asset while AirPlay is prepared or selected. Playback also waits
when a newly inherited audio route has no prepared, receiver-readable item, so
unprepared phone video cannot continue with TV audio while Flutter adopts it.

Initialization checks the current [item's ready-to-play state](https://developer.apple.com/documentation/avfoundation/avplayeritem)
and derives dimensions from its video track before checking presentation size.
For routed/prepared video it accepts a ready item without local dimensions,
avoiding a dependency on local rendering before Flutter can prepare AirPlay.
Local video retains its size requirement. Duration and HLS safeguards remain.

The background pause rule permits prepared AirPlay as well as PiP; ordinary local
playback keeps its original behavior. Confirmed native position at full duration
provides completion when a receiver omits its end notification. Current-item
checks and a completion marker suppress stale/duplicate events; seeking back
clears that marker. Source revisions also invalidate delayed seek/rate work, and
source clearing cancels delayed stall recovery before detaching the old item.

`scripts/prepare_ios_player.py` checks the exact original and patched file hashes
in `manifest.json`, prepares a copy under `.dart_tool/ios_player`, and adds
`GuoguoMediaPolicy.swift`. CocoaPods uses this copy; the pub cache stays unchanged.
CI compiles the policy's Swift regressions and the full iOS app. The package pin
and source checks must be deliberately updated before using another package version.
