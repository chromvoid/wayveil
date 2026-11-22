# Wayveil for iOS

Source for Wayveil TestFlight 0.1.1 (9), tag `ios-v0.1.1-build.9`. The SwiftUI client imports connection profiles and invitations. Its packet tunnel uses the ChromVoid Hysteria mobile core and HEV SOCKS5 tunnel. The app and tunnel require iOS 16 or later. The Control Center extension requires iOS 18 or later.

## Source version

- The app bundle identifier is `com.chromvoid.vpn`. The Xcode project contains the app, PacketTunnel, WayveilControls and the existing iOS unit tests. The routing document and test fixtures live under `routing/`.
- `third_party/hysteria` contains the mobile package, its tests and the build inputs for the local core and extras modules. The runtime sources come from the [public Hysteria fork at 0f312949](https://github.com/chromvoid/hysteria/tree/0f3129498a2022aca3cd82e513c80595b0313d99).
- The mobile module replaces `github.com/xtls/xray-core v1.260327.0` with the [ChromVoid Xray-core fork at c8acf0a4](https://github.com/chromvoid/Xray-core/tree/c8acf0a4a9ab4a26f6108a1ade355d8ffda513de). Go dependencies and gomobile/gobind v0.1.12 are included in `third_party/hysteria/app/vendor`. The module files, checksums, replacement directives and `vendor/modules.txt` record the dependency versions.
- `third_party/hev` contains [HEV at 55cc2efc](https://github.com/heiher/hev-socks5-tunnel/tree/55cc2efc280f3a72ffc60ce856772b57f5122e9c) with its four submodules expanded. The lifecycle patch in `native/hev` is already applied. Submodule revisions and the patch digest are in `SOURCE.json`.

The public project selects the iOS targets and icon assets from the shared Apple project. The mobile core tests use example endpoints and check the vendored dependency graph. Upstream Go ignore files are omitted so all vendor sources are tracked. The bundled notices identify the Xray revision used by this build.

## Build

Use macOS with Xcode 27.2 and its Metal toolchain, XcodeGen 2.46.0 and Go 1.27.3. Select Xcode with `xcode-select` or `DEVELOPER_DIR` and put Go and XcodeGen on `PATH`. From the root of the checkout or unpacked source archive, run

```sh
shasum --quiet -a 256 -c SOURCE-SHA256SUMS
scripts/build-mobile-core.sh
xcodegen generate --spec ios/project.yml --project ios
xcodebuild -project ios/Wayveil.xcodeproj -scheme Wayveil \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath .local/DerivedData CODE_SIGNING_ALLOWED=NO build
```

The script builds HEV and WayveilCore XCFrameworks for arm64 devices and arm64/x86_64 simulators from the included sources. It builds the binding tools from the vendor directory. The release command produces an unsigned app with both extensions in `.local/DerivedData/Build/Products/Release-iphoneos/`.

To run the existing tests, use `xcrun simctl list devices available` and set `SIMULATOR_UDID` to an available iOS simulator. Xcode's local ad hoc signature enables the shared Keychain group used by the storage tests. The routing tests read fixture files from the checkout.

```sh
xcodebuild -project ios/Wayveil.xcodeproj -scheme Wayveil \
  -destination "platform=iOS Simulator,id=${SIMULATOR_UDID}" \
  -parallel-testing-enabled NO -derivedDataPath .local/DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= test
(cd third_party/hysteria/app && GOWORK=off GOFLAGS=-mod=vendor GOPROXY=off go test ./mobile)
```

`SOURCE-SHA256SUMS` covers every published file except itself. It verifies the source archive. TestFlight package verification is a separate publisher step.

## License and attribution

Copyright (c) 2026 ChromVoid LLC. First-party Wayveil source and its native integration are licensed under MIT. Preserve the copyright and permission notice in `LICENSE` when redistributing substantial portions.

Preserve the component licenses under `third_party`, `native/hev/LICENSE` and the bundled `ios/App/Resources/ThirdPartyNotices.txt`. The notices include the MPL-2.0 terms for Xray-core and REALITY, the LGPL-3.0 terms and linking exception for juju/ratelimit, and the original libyaml attribution. The Go compiler and Apple development tools are supplied separately.

## Links

- [Versioned source](https://github.com/chromvoid/wayveil/releases/tag/ios-v0.1.1-build.9)
- [Privacy](https://link.chromvoid.com/privacy)
- [Support](https://link.chromvoid.com/support)
