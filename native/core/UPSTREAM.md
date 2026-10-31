# Reference source

`internal/` is copied from the user's reference repository:

- Repository: https://github.com/maxduke/guoguo-video
- Commit: `9f1a1b5886ad5d86f85e6bfb7bf8de5536bc8cf9`
- Original module: `juku`

The provider implementations and their regression tests are retained. The desktop Web UI, CLI, task/history management, executable media processing, and FFmpeg installer were removed in the mobile-only cleanup. Shared cover, identity, episode metadata, and media-resolution helpers now live outside desktop-named files. The mobile facade lives in `internal/app/mobile*.go`, `mobile/`, and `cmd/probe/`; the original reference remains available through the revision above and git history.

Provider parsing is invoked through a linked gomobile library. Mobile media processing uses linked native libraries through Flutter. The Go HLS/media HTTP proxy remains part of the mobile runtime; it is not a desktop UI server. Explicit/environment proxy support remains, without desktop registry/scutil subprocess discovery. FFmpeg subprocesses are permitted only in local synthetic-media tests.

No new license grant is asserted for the copied source. This repository is intended for the user's private development and distribution workflow.

## September 2026 selective refresh

Provider/search/recommendation/ranking, cover decoding and public image transport,
Huangguo browser compatibility, and HLS transport fixes were ported from
`675f347b4c47301baf79628f97e61b72464cea0b` (upstream v0.4.0).
Mobile facade, legacy cover mappings, and Huangguo ranking artwork enrichment are
retained. Upstream HTTP/account route tests are adapted to the mobile JSON API;
provider parsing and transport fixtures are retained. At that point, desktop/account/Emby/UI
code remained at the earlier baseline; it has since been removed from the mobile core.
See [the adoption record](../../docs/archive/upstream-refresh-2026-09.md) for scope and validation.

## September 27 guoapp selective port

Hongguo semantic ranking / JSON-LD fallback and bounded incomplete-response retries
are adapted from sibling `guoapp` 0.2.54+60, HEAD `ffddc0b`. Only the ranking parser
and required HTML helpers are copied; the existing mobile transport and provider
facade remain in use. Synthetic tests cover identity, rank, pagination, retries
and cancellation. See [the fusion record](../../docs/archive/app-fusion.md) for adoption decisions and limitations.


The 0.8.0 mobile extension also ports Huangju, Yeguo and DSD catalog/detail/playback
parsers and their client helpers from the same `ffddc0b`. Mobile adapters, scoped
playback credentials, durable download grants and facade tests are local
integration code. Existing source IDs and mobile transport are retained; no
upstream desktop shell, account model or media engine is started.

## September 28 guoapp archive refresh

The 12 duanju provider parsers and selected provider transport fixes are adapted
from guoapp `0.2.55+61`, downloaded from
`https://chenwai.252035.xyz/真果·鉴.zip` (SHA-256
`bdfd0294ae270fa7327143e27331224832f6647df3d4dffab9b084d3855f1e31`).
See [the adoption record](../../docs/archive/upstream-refresh-2026-09-28.md) for the
selection, mobile integration, and validation details.

## October 5 catalog and cover compatibility refresh

Huangguo paged catalog requests, cover Referer selection and legacy image URL
repair, and MacCMS `/xzyxvd/` detail anchors are selectively adapted from guoapp
`5999e469e1281e55dcf603c980f83cd0ba00206d`. The mobile aggregate source keeps its
existing identities, with independent persistent cursors and bounded requests.
HTTPS-only image transport and source isolation are retained; HTTP artwork
metadata is upgraded to HTTPS rather than allowing plaintext image requests.

Yeguo's current `.callawtj.cc` routes and exact-origin configuration discovery
are local fixes verified against the published routes (the reference revision
still has the old behavior). See [the cover repair record](../../docs/archive/source-catalog-covers-2026-10-05.md) for tests, per-source network sampling and remaining limits.

## October 9 provider refresh

Chaoguo, Miguo and Shuangguo parsing, and selected MacCMS identity, title,
playback and HTML request compatibility helpers are adapted from guoapp
`8b98b4731d` (`0.2.120+2127`). The mobile registry, paged search, records,
credentials and media proxy remain local. Catalog ordering is labeled as catalog
position; Chaoguo's official hot chart retains its published ranks and artwork
addresses. Miguo's single-page catalog does not advertise continuation.

Ranking refresh and original fetch timestamps now cross the mobile facade;
Huangguo route recovery and recognition of the current Shuangguo verification
page are local fixes. See [the adoption record](../../docs/archive/upstream-refresh-2026-10-09.md)
for selection decisions and live-network limits.

## October 16 Hongguo playback repair

The App stream request is adapted from
[onedrama `6905554a2c5da06c345776ff594d34735a29fad5`](https://github.com/yhoops/onedrama/commit/6905554a2c5da06c345776ff594d34735a29fad5).
It uses `/novel/player/multi_video_model/preload/v1/`, with
`biz_param.video_platform = 1024` and the short-drama content type `1004` in
`mixed_video_id_map`. The response is selected by the requested episode ID;
JSON-string and object video models use the existing mobile media selection,
quality and CENC key handling. Local regression fixtures cover the request
contract, model formats, episode identity and invalid responses.

Live sampling on 2026-10-16 with
`go run ./cmd/probe -source hongguo -genre short_play -decode` returned 18
recommendations and 71 episodes for series `7691530085832068121`. One episode
passed the HTTP 206 / 1024-byte range check, full CENC decryption and MP4
preparation, and full decoding with Ubuntu FFmpeg 6.1.1. This host sample does
not establish iPhone / iPad playback or ongoing upstream availability.

## October 24 Hongguo protocol repair

Playback request separation is adapted from
[chewu1590/hongguoTV `43b970bf77f5c3ae3e06075a210b49a71c3d9e1a`](https://github.com/chewu1590/hongguoTV/commit/43b970bf77f5c3ae3e06075a210b49a71c3d9e1a).
The current player endpoint is `/novel/player/multi_video_model/v1/`:
the previous `preload` endpoint returned an empty body even without signatures.
Playback sends no signing headers and uses independent client-lifetime numeric
device/install/CDID values, outside the persisted catalog state. Exact episode
identity, model formats, compatible quality selection and CENC handling remain
the mobile implementation.

Signed catalog and detail requests require the full current protocol. Gorgon,
Helios, Medusa, branch-0 ticket selection and the protocol-specific cipher are
adapted from `Signer.kt`, `AesV3.kt` and `VendorConstants.kt` at
[tsukiyo-zero/hongguoTV `e41a74722cc339c3aa40936a325f184d176b1564`](https://github.com/tsukiyo-zero/hongguoTV/tree/e41a74722cc339c3aa40936a325f184d176b1564).
Their algorithm provenance is drpys
`22261adfa31435e3b3ef5a730b8a2a75bcaf1715`, GPL-3.0-only; the license is retained
in [licenses/hongguoTV-GPL-3.0.txt](licenses/hongguoTV-GPL-3.0.txt).
The local signer binds the existing client's device ID and current request
version; upstream's shared metadata identity is not copied.

The first 12 `testdata/hongguo_signing.json` cases are the independent upstream
Node oracle fixtures (`signing.json` blob
`d9fc3da9d35f5a3a4cb0e5098985698c73986aa8`). Two additional cases generated with
the same oracle (`server/vendor/hongguo.cjs` blob
`405b4ac1f75d0c2a9f2856a84288a7df39404dfd`) cover the local version and distinct
device IDs. All 14 compare exact hash, Gorgon, Helios and Medusa outputs.

Public website search is selectively adapted from
[tsukiyo-zero/hongguoTV `2e9b7daf5be227551a95adc4c77398935acf9a77`](https://github.com/tsukiyo-zero/hongguoTV/commit/2e9b7daf5be227551a95adc4c77398935acf9a77),
using `/api/search/result` rather than HTML router data. Existing name matching,
season completion, cancellation, caching and mobile continuation remain local.

Host regression and real search/recommendation/detail/media sampling passed;
one 71-episode series also passed full-episode CENC preparation and decoding.
The [review and validation record](../../docs/hongguo-upstream-review-2026-10-24.md)
records the adoption decisions and CDN/device acceptance limits.

## October 28 Hongguo anonymous playback device repair

Playback device registration and client-lifetime identity reuse are selectively
adapted from [tsukiyo-zero/hongguoTV `388931852ddc614db8b00775a3dc54c5ede6307f`](https://github.com/tsukiyo-zero/hongguoTV/commit/388931852ddc614db8b00775a3dc54c5ede6307f),
reviewed at main `c376666da49615871867e742861f98e108da39ba`.
The references are `kotlin-tv/core/src/main/kotlin/com/hongguotv/core/DeviceRegister.kt`
and `PlaybackDeviceSession.kt`; DeviceRegister itself credits
charlie901208/HGTV `feat/phone-login` (GPL-3.0-only).
The existing [GPL-3.0 license](licenses/hongguoTV-GPL-3.0.txt) is retained.

The local Go implementation registers anonymously through
`https://log5-applog-lf.fqnovel.com/service/2/device_register/`, using the
gzip/ttEncrypt binary envelope and matching registration headers. It retains
the local App version, device profile, player endpoint and unsigned playback
strategy. Registered IDs and an RFC 4122 version-4 CDID replace random numeric
playback IDs. Successful identity is shared by playback and prefetch within the
same mobile client, stays in memory, and is independent of saved catalog state.
Concurrent registration is coalesced with independently cancelable waiters;
unsuccessful/canceled registration publishes no identity. Only the four device
cookie names used by the reference are sent, without an account/site cookie jar
or redirect forwarding. HTTP 200 empty player responses now use the existing
retry budget without registering again or rotating the identity.

On 2026-10-28 a same-episode comparison reproduced empty responses with random
IDs and valid 1080p/CENC models with registered IDs. Three genre probes and one
full-episode preparation/decode succeeded. The [repair and optimization review](../../docs/hongguo-upstream-review-2026-10-28.md)
records the controls, local regression evidence and remaining device limits.

## October 28 Hongguo playback and ranking optimization

Bounded upcoming-episode model reuse is selectively adapted from
`ContentRepository.streamLadder` at [hongguoTV `c376666da49615871867e742861f98e108da39ba`](https://github.com/tsukiyo-zero/hongguoTV/blob/c376666da49615871867e742861f98e108da39ba/kotlin-tv/core/src/main/kotlin/com/hongguotv/core/ContentRepository.kt),
introduced by [e606c8d](https://github.com/tsukiyo-zero/hongguoTV/commit/e606c8d7c236369dcfe222c5eae17b0f0cf5bfa4).
The Go adaptation keeps a 60-second, six-entry, 256-KiB-per-entry memory cache,
consumes models on use, validates the exact requested episode, and derives the
next IDs from a fresh validated detail. The optional mobile `metadataAhead`
count is sent only by Hongguo background preparation after the existing prefetch
policy permits it. This does not prepare additional media or affect downloads.

The Flutter ranking page adopts independent in-flight board results and fresh
session switching inspired by `RankBrowserState` at the same pinned revision.
It retains the existing five-minute policy, four session snapshots, persisted
cache, pagination and forced refresh. CookieJar changes are deferred because
the current live first/second ranking pages succeeded without them. Safe
playback guidance/recovery presentation is local implementation.

The [implementation and broader feature comparison](../../docs/hongguo-optimizations-2026-10-28.md)
records the scope and candidate follow-ups. The existing GPL-3.0 license and
algorithm provenance are retained; account/cloud synchronization is excluded.

## October 28 mobile playback lifetime hardening

Request-scoped resolve cancellation, bounded cancellation tombstones, and the
closed/canceled playback publication guard are local mobile-facade corrections.
They retain protocol 3 and advertise optional resolve cancellation. Provider
parsing, model selection, signing, and retry budgets are unchanged. See the
[playback lifetime record](../../docs/playback-reliability-2026-10-28.md) for the
Flutter initialization guard, Android dispatch budgets, and validation boundaries.

## October 31 Hongguo playback route recovery

Playback route changes and the conservative `device_level: 1` request profile
are selectively adapted from hongguoTV at
[`b6e018ddb941b798e0672d23186c91cc556f1ab7`](https://github.com/tsukiyo-zero/hongguoTV/tree/b6e018ddb941b798e0672d23186c91cc556f1ab7),
specifically [`PlayRetry.kt`](https://github.com/tsukiyo-zero/hongguoTV/blob/b6e018ddb941b798e0672d23186c91cc556f1ab7/kotlin-tv/core/src/main/kotlin/com/hongguotv/core/PlayRetry.kt)
and [`ContentRepository.kt`](https://github.com/tsukiyo-zero/hongguoTV/blob/b6e018ddb941b798e0672d23186c91cc556f1ab7/kotlin-tv/core/src/main/kotlin/com/hongguotv/core/ContentRepository.kt).
The existing GPL-3.0 license and attribution remain applicable.

The Go adaptation rotates only the fixed unsigned playback origins and retains
the registered device identity. Mobile Hongguo playback has a dedicated four-read
budget with 700/1500/3000 ms backoff; general provider retries retain their prior
budget. Optional batch metadata falls back to the selected episode within the
same four attempts and continues the route sequence.
Retries use isolated HTTP transports with rebuilt HTTP/2 handling; shared pools,
TLS verification, DNS and proxy settings are preserved. Codec filtering also
recognizes the upstream `bvc2` alias. Signed requests, registration, model-cache
policy and higher-level recovery budgets keep their existing contracts.

The [repair and feature assessment](../../docs/hongguo-upstream-review-2026-10-31.md)
records live checks and the remaining iPhone acceptance boundary.
