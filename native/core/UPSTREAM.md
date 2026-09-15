# Reference source

`internal/` is copied from the user's reference repository:

- Repository: https://github.com/maxduke/guoguo-video
- Commit: `9f1a1b5886ad5d86f85e6bfb7bf8de5536bc8cf9`
- Original module: `juku`

The original provider implementations, embedded Web UI, and tests are retained to keep the port auditable. The mobile application does not start that Web UI or call its desktop FFmpeg installer. The mobile facade lives in `internal/app/mobile*.go`, `mobile/`, and `cmd/probe/`.

Provider parsing is invoked through a linked gomobile library. Desktop media subprocess logic remains reference code; actual mobile media processing uses linked native libraries through Flutter.

No new license grant is asserted for the copied source. This repository is intended for the user's private development and distribution workflow.
