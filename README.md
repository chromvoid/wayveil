# Wayveil for iOS

Native SwiftUI Hysteria2 VPN client for iPhone and iPad, with a packet-tunnel Network Extension and sing-box/libbox. Import your own compatible connection profile. No VPN subscription or server credentials are included.

This public repository contains the iOS client and its networking dependencies. The separately operated service backend is outside this source release. It contains no private development history, signing keys, provisioning profiles, account credentials, or user profiles.

## Source version

- Client: 0.1.0, build 3; bundle identifier `com.chromvoid.vpn`.
- Source release: `ios-v0.1.0-build.3`.
- Core: unmodified sing-box 1.14.4, commit `c005f35300ce76427dc285481ec5695f5b179cd2`.
- Runtime dependencies: included in `third_party/sing-box/vendor/`, with their upstream licenses and `vendor/modules.txt`. Unused optional Cronet libraries and Windows-only Wintun binaries are excluded; neither is part of this iOS build. Gomobile binding-generator sources are also included to support vendor-mode builds. `go.mod` and `go.sum` retain exact module versions.
- This is a source release, not an announcement of App Store availability. This snapshot represents build 3 only; available prior snapshots remain under their own source tags.

## Build

The tested toolchain is macOS with Xcode 27.0, Swift 6.4 in Swift 5 language mode, XcodeGen 2.46.0, and Go 1.27.3. Deployment target: iOS 16. Put Go and XcodeGen on PATH and select Xcode with `xcode-select`.

```sh
scripts/build-libbox-ios.sh
xcodegen generate --spec ios/project.yml --project ios
xcodebuild -project ios/ChromVoidVPN.xcodeproj -scheme ChromVoidVPN \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .local/DerivedData CODE_SIGNING_ALLOWED=NO build
```

The core build script compiles the included upstream source in vendor mode. It installs the public build tools gomobile and gobind at v0.1.12; initial installation requires internet access. No precompiled Libbox framework is required. The core build tags are `with_quic,with_gvisor,tfogo_checklinkname0` and its linker flags are in the script.

For physical devices, open `ios/ChromVoidVPN.xcodeproj`, select your own paid Apple Developer team for both targets, and enable automatic signing. Use bundle identifiers registered to your team if the existing identifiers are unavailable. Both targets need the packet-tunnel Network Extension capability and the same team-prefixed Keychain access group. No original publisher signing key is needed. Simulator builds intentionally refuse to create a VPN tunnel.

To run the existing tests, replace `SIMULATOR_UDID` with an available simulator:

```sh
xcodebuild -project ios/ChromVoidVPN.xcodeproj -scheme ChromVoidVPN \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -derivedDataPath .local/DerivedData CODE_SIGNING_ALLOWED=NO test
```

## License and attribution

Copyright (C) 2026 ChromVoid LLC for the first-party client. The client is licensed under GPL-3.0-or-later; see `LICENSE`. Recipients may use, study, modify and redistribute it under those terms.

sing-box is Copyright (C) 2022 nekohasekai and its contributors, licensed under GPL-3.0-or-later with an additional restriction on using its name or implying association. Preserve `third_party/sing-box/LICENSE` and all dependency notices. Wayveil is independently developed and is not affiliated with or endorsed by SagerNet or sing-box. The upstream runtime source is unchanged; upstream Git ignore files are omitted so dependency sources remain included in this mirror; the client, integration and packaging scripts are maintained separately by ChromVoid.

Third-party components keep their own licenses. See `ios/App/Resources/ThirdPartyNotices.txt`, `third_party/sing-box/LICENSE`, and the license files in `third_party/sing-box/vendor/`. Apple SDKs, Xcode, system libraries and generally available build tools are not redistributed here.

This source release does not grant an App Store exception for third-party GPL-covered code. App Store distribution terms require a separate compatibility assessment; publication of source alone does not resolve restrictions imposed by a distribution channel.

## Links

- [Versioned source](https://github.com/chromvoid/wayveil/releases/tag/ios-v0.1.0-build.3)
- [Privacy](https://link.chromvoid.com/privacy)
- [Support](https://link.chromvoid.com/support)
