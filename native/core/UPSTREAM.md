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
