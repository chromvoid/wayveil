#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/third_party/sing-box"
export PATH="$ROOT/.local/tools/go/bin:$ROOT/.local/tools/bin:$PATH"
export GOBIN="$ROOT/.local/tools/bin"

mkdir -p "$GOBIN" "$ROOT/ios/Frameworks"
go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12

cd "$SOURCE"
export GOFLAGS=-mod=vendor
gomobile bind -target=ios,iossimulator -iosversion=16.0 \
  -tags=with_quic,with_gvisor,tfogo_checklinkname0 -trimpath \
  -ldflags='-s -w -checklinkname=0 -X github.com/sagernet/sing-box/constant.Version=1.14.4' \
  -o "$ROOT/ios/Frameworks/Libbox.xcframework" ./experimental/libbox
