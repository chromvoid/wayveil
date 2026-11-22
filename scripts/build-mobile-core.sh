#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 ChromVoid LLC

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HYSTERIA="$ROOT/third_party/hysteria"
HEV="$ROOT/third_party/hev"
HEV_REVISION=55cc2efc280f3a72ffc60ce856772b57f5122e9c
BUILD="$ROOT/.local/native/hev"
export GOBIN="$ROOT/.local/tools/bin"
export PATH="$GOBIN:$PATH"

mkdir -p "$GOBIN" "$BUILD" "$ROOT/ios/Frameworks"
# Dependency sources and expanded HEV submodules are included in this release.
# The HEV lifecycle patch is already applied; fail if those inputs change.
test "$(shasum -a 256 "$HEV/src/hev-socks5-tunnel.c" | cut -d " " -f 1)" = 5823e607770e06ec04685c29d1f0123b12cea65059c225c83eba4dcc76d4afec
test "$(shasum -a 256 "$HEV/src/hev-main.h" | cut -d " " -f 1)" = 17b0319b1951df4196269058fd1fa23f07e12f585a961be31270ed985e34b795
# The core tests its routing decisions against a copy of the shared fixture.
cmp "$HYSTERIA/app/mobile/testdata/routing-decisions.json" "$ROOT/routing/testdata/decisions.json"

build_apple() {
    local sdk="$1" arch="$2" output="$BUILD/apple/$1-$2"
    mkdir -p "$output"
    make -C "$HEV" REV_ID="${HEV_REVISION:0:7}" clean
    make -C "$HEV" \
        PP="xcrun --sdk $sdk clang" CC="xcrun --sdk $sdk clang" \
        CFLAGS="-arch $arch -m$sdk-version-min=16.0" \
        LFLAGS="-arch $arch -m$sdk-version-min=16.0" REV_ID="${HEV_REVISION:0:7}" static
    libtool -static -o "$output/libhev-socks5-tunnel.a" \
        "$HEV/bin/libhev-socks5-tunnel.a" \
        "$HEV/third-part/lwip/bin/liblwip.a" \
        "$HEV/third-part/yaml/bin/libyaml.a" \
        "$HEV/third-part/hev-task-system/bin/libhev-task-system.a"
}

build_apple iphoneos arm64
build_apple iphonesimulator arm64
build_apple iphonesimulator x86_64
mkdir -p "$BUILD/apple/iphonesimulator-universal" "$BUILD/apple/include/HevSocks5Tunnel"
lipo -create "$BUILD/apple/iphonesimulator-arm64/libhev-socks5-tunnel.a" \
    "$BUILD/apple/iphonesimulator-x86_64/libhev-socks5-tunnel.a" \
    -output "$BUILD/apple/iphonesimulator-universal/libhev-socks5-tunnel.a"
cp "$HEV/src/hev-main.h" "$HEV/module.modulemap" "$BUILD/apple/include/HevSocks5Tunnel/"
rm -rf "$ROOT/ios/Frameworks/HevSocks5Tunnel.xcframework"
xcodebuild -create-xcframework \
    -library "$BUILD/apple/iphoneos-arm64/libhev-socks5-tunnel.a" -headers "$BUILD/apple/include" \
    -library "$BUILD/apple/iphonesimulator-universal/libhev-socks5-tunnel.a" -headers "$BUILD/apple/include" \
    -output "$ROOT/ios/Frameworks/HevSocks5Tunnel.xcframework"

cd "$HYSTERIA/app"
export GOWORK=off
export GOFLAGS=-mod=vendor
export GOPROXY=off
export GOTOOLCHAIN=local
# Build the pinned generator and runtime from the included vendor source.
go install github.com/sagernet/gomobile/cmd/gomobile
go install github.com/sagernet/gomobile/cmd/gobind
gomobile bind -target=ios,iossimulator -iosversion=16.0 -trimpath -buildvcs=false \
    -ldflags='-s -w' -o "$ROOT/ios/Frameworks/WayveilCore.xcframework" ./mobile
