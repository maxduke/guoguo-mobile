# Reference source

`internal/` is copied from the user's reference repository:

- Repository: https://github.com/maxduke/guoguo-video
- Commit: `9f1a1b5886ad5d86f85e6bfb7bf8de5536bc8cf9`
- Original module: `juku`

The provider implementations and their regression tests are retained. The desktop Web UI, CLI, task/history management, executable media processing, and FFmpeg installer were removed in the mobile-only cleanup. Shared cover, identity, episode metadata, and media-resolution helpers now live outside desktop-named files. The mobile facade lives in `internal/app/mobile*.go`, `mobile/`, and `cmd/probe/`; the original reference remains available through the revision above and git history.

Provider parsing is invoked through a linked gomobile library. Mobile media processing uses linked native libraries through Flutter. The Go HLS/media HTTP proxy remains part of the mobile runtime; it is not a desktop UI server. Explicit/environment proxy support remains, without desktop registry/scutil subprocess discovery. FFmpeg subprocesses are permitted only in local synthetic-media tests.

No new license grant is asserted for the copied source. This repository is intended for the user's private development and distribution workflow.

## November 5 Huangguo API and line selection

The anonymous edge-request protocol and response fields were compared with
[Minireel/HGhub `8665ffcaa553bc6eb1b52629fd91b35cc6e02678`](https://github.com/Minireel/HGhub/tree/8665ffcaa553bc6eb1b52629fd91b35cc6e02678)
and checked against the provider's current public responses. HGhub's referenced
revision uses [PolyForm Noncommercial 1.0.0](https://github.com/Minireel/HGhub/blob/8665ffcaa553bc6eb1b52629fd91b35cc6e02678/LICENSE).
No Rust, React, player, media-proxy or cryptography source is copied from HGhub.
The Go adapter is implemented against the observed protocol using this core's
existing request limiter, public-DNS validation, cancellation and media handling.

The adapter preserves `huangguoai:<id>` and the existing chapter keys (`1`,
`ep-2`, ...), keeps legacy HTML/direct-JSON fallbacks for unsupported endpoints,
and uses no account cookies or tokens. The Flutter line picker uses the existing
official discovery path; its catalog check does not claim media or device
playback acceptance. Details and validation are recorded in
[the adoption record](../../docs/hghub-adoption-2026-11-05.md).

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

## November 2 Hongguo selective identity recovery

Bounded anonymous identity recovery is selectively adapted from
[hongguoTV PR #42](https://github.com/tsukiyo-zero/hongguoTV/pull/42), pinned at
[`3e2db1b75126c804d6b1e1dc6acb5e8c6f365766`](https://github.com/tsukiyo-zero/hongguoTV/tree/3e2db1b75126c804d6b1e1dc6acb5e8c6f365766),
particularly `ContentRepository.kt` and `PlaybackDeviceSession.kt`. The existing
GPL-3.0 license and attribution apply.

Two complete all-empty four-read rounds can trigger one replacement registration
through the existing anonymous protocol. The Go adaptation performs at most two
old-identity rounds and one replacement-identity round within the original mobile
request deadline; background metadata keeps its single-round budget. Failed
replacement registration retains the old identity. Successful current-episode
models reset the failure period; canceled registration publishes no replacement.

Registration is claimed under the client mutex and coalesced with cancelable
waiters. Request identity/revision snapshots prevent stale replies from changing
current recovery state or warming a cache invalidated by replacement. Account
cookies, catalog identity, persistence and active media are unchanged. These
concurrency and cache guards are local adaptations rather than a direct port.

The [investigation and validation record](../../docs/hongguo-identity-recovery-2026-11-02.md)
also preserves the live failure where a replacement identity still received empty
models. Identity-specific and broader service/network failures remain distinct;
this change does not promise availability during every server incident.

## November 8 Hongguo signed, per-resolve playback

The current playback request policy is selectively adapted from
[jackotom/hongguo-drama `b2b81cec61159ae788c723b21ad1015ac40296f6`](https://github.com/jackotom/hongguo-drama/tree/b2b81cec61159ae788c723b21ad1015ac40296f6),
`src/native/app-source.js` (`playbackRequest`, `fetchAppPlayUrl`) and
`src/native/playback-device.js` (`registerPlaybackDevice`), GPL-3.0-only.
The existing [GPL license](licenses/hongguoTV-GPL-3.0.txt) is retained.
That project's signing/Spade provenance is woshishiq1/drpys
`22261adfa31435e3b3ef5a730b8a2a75bcaf1715` via N3urda/hongguoTV
`eea73e6a45569a2cbbb9440f7cd5290c459b0b70`; its registration provenance is
hongguoTV `388931852ddc614db8b00775a3dc54c5ede6307f` via
charlie901208/HGTV. Our already validated Go cryptography remains in use.

This supersedes the October unsigned-player policy and November 2 shared
identity/health-revision recovery. Playback signs the final query and POST bytes
with the registered anonymous identity on every attempt; catalog-only body-stub
and SDK headers are omitted from the anonymous player profile. Registration
remains separate and unsigned except for its binary body checksum. Existing
account-cookie and redirect isolation remain in place.

A fresh identity belongs to each uncached logical resolve, retaining it within
that resolve's route and batch-to-single retries. Registration uses an eight-second
sub-deadline and ten-second failure cooldown (caller cancellation excluded).
Foreground all-empty failure permits at most one replacement and one additional
four-attempt round; background lookahead keeps one round. The old cross-resolve
identity state and stale-lease machinery are removed. Successful upcoming models
remain independently reusable with the existing one-minute cap, additionally
bounded by server `expire_time` minus five seconds.

Same-episode unsigned/signed controls and single-use identity behavior were
observed on this host; three sequential mobile resolves passed. See
[the adoption and validation record](../../docs/hongguo-drama-review-2026-11-08.md)
for evidence, selective follow-up ideas, and the outstanding iOS acceptance.

## November 8 Hongguo model fields and equal-quality alternatives

Model field normalization and candidate retention are selectively adapted from
[jackotom/hongguo-drama `b2b81cec61159ae788c723b21ad1015ac40296f6`](https://github.com/jackotom/hongguo-drama/tree/b2b81cec61159ae788c723b21ad1015ac40296f6),
`src/native/app-source.js:parseAppPlayModel` and its
`src/native/app-source-inline-fallback.test.cjs` cases, GPL-3.0-only.
Existing cryptographic attribution and the retained GPL license apply.

The local parser accepts top-level and nested codec/encryption/dimension fields,
requires a valid key or an explicit plaintext marker, prioritizes actual short-edge
dimensions, and retains validated main/backup addresses with their own metadata.
AVC and HEVC alternatives at the same quality survive deduplication and flow into
the existing mobile fallback contract. At most four addresses per quality/codec
family are retained; all available quality tiers remain represented. ByteVC2 and
unknown codecs are excluded. This does not add model/network retries or change
anonymous identity/cache lifetimes. See
[the implementation and validation record](../../docs/hongguo-model-compatibility-2026-11-08.md).
