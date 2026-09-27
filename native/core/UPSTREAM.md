# Reference source

`internal/` is copied from the user's reference repository:

- Repository: https://github.com/maxduke/guoguo-video
- Commit: `9f1a1b5886ad5d86f85e6bfb7bf8de5536bc8cf9`
- Original module: `juku`

The original provider implementations, embedded Web UI, and tests are retained to keep the port auditable. The mobile application does not start that Web UI or call its desktop FFmpeg installer. The mobile facade lives in `internal/app/mobile*.go`, `mobile/`, and `cmd/probe/`.

Provider parsing is invoked through a linked gomobile library. Desktop media subprocess logic remains reference code; actual mobile media processing uses linked native libraries through Flutter.

No new license grant is asserted for the copied source. This repository is intended for the user's private development and distribution workflow.

## September 2026 selective refresh

Provider/search/recommendation/ranking, cover decoding and public image transport,
Huangguo browser compatibility, and HLS transport fixes were ported from
`675f347b4c47301baf79628f97e61b72464cea0b` (upstream v0.4.0).
Mobile facade, legacy cover mappings, and Huangguo ranking artwork enrichment are
retained. Upstream HTTP/account route tests are adapted to the mobile JSON API;
provider parsing and transport fixtures are retained. Desktop/account/Emby/UI
code remains at the earlier baseline unless needed by shared parser types.
See `docs/upstream-refresh-2026-09.md` at the repository root for scope and validation.

## September 27 guoapp selective port

Hongguo semantic ranking / JSON-LD fallback and bounded incomplete-response retries
are adapted from sibling `guoapp` 0.2.54+60, HEAD `ffddc0b`. Only the ranking parser
and required HTML helpers are copied; the existing mobile transport and provider
facade remain in use. Synthetic tests cover identity, rank, pagination, retries
and cancellation. See `docs/app-fusion.md` for adoption decisions and limitations.


The 0.8.0 mobile extension also ports Huangju, Yeguo and DSD catalog/detail/playback
parsers and their client helpers from the same `ffddc0b`. Mobile adapters, scoped
playback credentials, durable download grants and facade tests are local
integration code. Existing source IDs and mobile transport are retained; no
upstream desktop shell, account model or media engine is started.
