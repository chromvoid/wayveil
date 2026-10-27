# Wayveil for iOS and Android

Native SwiftUI and Jetpack Compose Hysteria2 VPN clients with the same connection-profile format and routing modes. The networking stack is the ChromVoid Hysteria mobile fork plus HEV SOCKS5 tunnel. Import your own compatible connection profile. No server credentials, VPN subscription, or user profiles are included.

This repository contains both clients, their networking sources, the native integration, and build inputs. The separately operated service backend is outside this source release. Private development history, operator tools, signing keys, provisioning profiles, and account credentials are excluded.

## Source version

- iOS: 0.1.0, build 5; bundle identifier `com.chromvoid.vpn`.
- Android: 0.1.0, version code 3; application ID `com.chromvoid.wayveil`.
- Source tag: `ios-v0.1.0-build.5`; this shared snapshot also contains the Android version identified above.
- Hysteria: [ChromVoid mobile fork](https://github.com/chromvoid/hysteria/tree/ea9a2940a0b43e4b2f9430e9bdb19b65de2cbc62), branch `wayveil-mobile`, commit `ea9a2940a0b43e4b2f9430e9bdb19b65de2cbc62`, based on upstream `ca8fbd874fd6ca82413948de6dc5924405e103e1`. The complete fork is included under `third_party/hysteria`.
- HEV: commit `55cc2efc280f3a72ffc60ce856772b57f5122e9c`, with four pinned submodules expanded under `third_party/hev`. The ChromVoid lifecycle patch `native/hev/hev-reset-stop.patch` is already applied. The Android integration uses only the JNI adapter in `native/hev`, excluding HEV's original application adapter. Exact pins and hashes are recorded in `SOURCE.json`.
- Go dependencies and gomobile v0.1.12 tool/runtime sources are included under `third_party/hysteria/app/vendor`, with original licenses and `vendor/modules.txt`. The app module keeps local replacements for the modified core and extras modules; its vendored copies preserve those changes.
- The unused Windows `third-part/wintun` subtree and its precompiled DLLs are excluded. Upstream Git ignore files are omitted so vendored source remains visible in this source mirror.
- This is a source release, not an announcement of App Store or Google Play availability. Historical snapshots remain under their own source tags. It does not update the App Store draft or submit a build for review.

## Build

The tested toolchain is macOS, Xcode 27.0, XcodeGen 2.46.0, Go 1.27.3, JDK 17, Android SDK 36 and Android NDK 29.0.13846066. Gradle 9.4.1 is pinned by the included wrapper and distribution checksum. Deployment targets are iOS 16 and Android 10 (API 29); Android native ABIs are arm64-v8a and x86_64. Put Go and XcodeGen on PATH and select Xcode with `xcode-select`.

```sh
scripts/build-mobile-core.sh
xcodegen generate --spec ios/project.yml --project ios
xcodebuild -project ios/ChromVoidVPN.xcodeproj -scheme ChromVoidVPN \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .local/DerivedData CODE_SIGNING_ALLOWED=NO build
cd android
./gradlew :app:assembleDebug :app:assembleRelease :app:testDebugUnitTest
```

The shared script builds both Apple and Android networking artifacts from the included sources. It uses `GOWORK=off` and `GOFLAGS=-mod=vendor`, and builds gomobile/gobind from the vendored v0.1.12 tool source. No precompiled framework, AAR, native library, or original publisher signing key is required. The Android SDK/NDK must be installed (`ANDROID_HOME` and `ANDROID_NDK_HOME` can override their default locations). Gradle downloads its pinned distribution and Maven dependencies on the first build. The unsigned Android release output is not ready for store upload until signed with your own key.

For physical iOS devices, select your own paid Apple Developer team for both targets. Use bundle identifiers registered to that team if the existing identifiers are unavailable. Both targets need the packet-tunnel Network Extension capability and the same team-prefixed Keychain access group. Simulator builds intentionally refuse to create a VPN tunnel.

To run the existing iOS tests, replace `SIMULATOR_UDID` with an available simulator:

```sh
xcodebuild -project ios/ChromVoidVPN.xcodeproj -scheme ChromVoidVPN \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -derivedDataPath .local/DerivedData CODE_SIGNING_ALLOWED=NO test
```

The Go mobile tests can run independently with `cd third_party/hysteria/app && GOWORK=off GOFLAGS=-mod=vendor go test ./mobile`. `SOURCE-SHA256SUMS` covers all published files except that manifest itself; build outputs are ignored.

## License and attribution

Copyright (C) 2026 ChromVoid LLC for the first-party clients. The clients remain GPL-3.0-or-later; see `LICENSE`. Recipients may use, study, modify and redistribute them under those terms. This migration does not change their license.

The selected networking runtime uses MIT, BSD, and Apache-2.0 components. The signed iOS build-5 packet-tunnel Go inventory contains 21 modules including the Hysteria app module, and no sing-box or AnyTLS module. This statement concerns the selected networking runtime, not every optional server, test, or build-tool package in the complete source inventory. Hysteria and HEV retain their MIT licenses; HEV's lwIP submodule retains its BSD license. Go and gomobile retain their BSD notices. Native integration code is MIT. AndroidX graphics-path is Apache-2.0.

Preserve the full notices in `ios/App/Resources/ThirdPartyNotices.txt`, `android/app/src/main/assets/LICENSES.txt`, all licenses under `third_party`, and `native/hev/LICENSE`. The native notices include original libyaml attribution in addition to its fork attribution. Apple/Android SDKs, Xcode, system libraries, the Go compiler, and other generally available build tools are not redistributed here; the Gradle wrapper JAR is included as a build tool.

Source publication and permissive networking dependencies do not constitute blanket App Store contractual clearance or an exception for the first-party GPL clients. Distribution terms still require a separate assessment by the publisher.

## Links

- [Versioned source](https://github.com/chromvoid/wayveil/releases/tag/ios-v0.1.0-build.5)
- [Privacy](https://link.chromvoid.com/privacy)
- [Support](https://link.chromvoid.com/support)
