#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 ChromVoid LLC

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HYSTERIA="$ROOT/third_party/hysteria"
HYSTERIA_REVISION=381bdbb6ec1d5936bdc6b7471a5da3d777452e0c
HEV="$ROOT/third_party/hev"
HEV_REVISION=55cc2efc280f3a72ffc60ce856772b57f5122e9c
BUILD="$ROOT/.local/native/hev"
export PATH="$ROOT/.local/tools/go/bin:$ROOT/.local/tools/bin:$PATH"
export GOBIN="$ROOT/.local/tools/bin"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/29.0.13846066}"

mkdir -p "$GOBIN" "$BUILD" "$ROOT/ios/Frameworks" "$ROOT/android/app/libs"
# Dependency sources and expanded HEV submodules are included in this release.
# The HEV lifecycle patch is already applied; fail if those inputs change.
test "$(shasum -a 256 "$HEV/src/hev-socks5-tunnel.c" | cut -d " " -f 1)" = 5823e607770e06ec04685c29d1f0123b12cea65059c225c83eba4dcc76d4afec
test "$(shasum -a 256 "$HEV/src/hev-main.h" | cut -d " " -f 1)" = 17b0319b1951df4196269058fd1fa23f07e12f585a961be31270ed985e34b795

build_apple() {
    local sdk="$1" arch="$2" output="$BUILD/apple/$1-$2"
    mkdir -p "$output"
    make -C "$HEV" clean
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

for abi in arm64-v8a x86_64; do
    rm -f "$BUILD/android/obj/local/$abi/libwayveilhev.so"
done
"$ANDROID_NDK_HOME/ndk-build" \
    NDK_PROJECT_PATH=null \
    APP_BUILD_SCRIPT="$ROOT/native/hev/Android.mk" \
    NDK_APPLICATION_MK="$ROOT/native/hev/Application.mk" \
    NDK_OUT="$BUILD/android/obj" \
    NDK_LIBS_OUT="$ROOT/android/app/src/main/jniLibs" \
    HEV_SOURCE_DIR="$HEV" \
    REV_ID="${HEV_REVISION:0:7}" APP_MODULES=wayveilhev

LLVM="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin"
for abi in arm64-v8a x86_64; do
    library="$ROOT/android/app/src/main/jniLibs/$abi/libwayveilhev.so"
    symbols="$("$LLVM/llvm-nm" -D "$library")"
    strings="$("$LLVM/llvm-strings" "$library")"
    if [[ "$symbols" == *JNI_OnLoad* || "$strings" == *hev/htproxy* || "$strings" == *TProxyService* ]]; then
        echo "The native library includes the upstream application JNI adapter." >&2
        exit 1
    fi
done

cd "$HYSTERIA/app"
export GOWORK=off
export GOFLAGS=-mod=vendor
# Build the pinned generator and runtime from the included vendor source.
go install github.com/sagernet/gomobile/cmd/gomobile
go install github.com/sagernet/gomobile/cmd/gobind
gomobile bind -target=android/arm64,android/amd64 -androidapi=29 \
    -javapkg=com.chromvoid.core -libname=wayveilcore -trimpath \
    -ldflags='-s -w' -o "$ROOT/android/app/libs/wayveilcore.aar" ./mobile
gomobile bind -target=ios,iossimulator -iosversion=16.0 -trimpath \
    -ldflags='-s -w' -o "$ROOT/ios/Frameworks/WayveilCore.xcframework" ./mobile
