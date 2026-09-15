#!/usr/bin/env bash
set -euo pipefail
version=v0.0.0-20260908204917-8b95e45f8d3e
go install "golang.org/x/mobile/cmd/gomobile@$version"
go install "golang.org/x/mobile/cmd/gobind@$version"
"$(go env GOPATH)/bin/gomobile" init
