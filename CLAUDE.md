# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run
- **Build (Debug)**: `swift build`
- **Build (Release)**: `swift build -c release`
- **Run (Debug)**: `swift run`
- **Update App Bundle**: `cp .build/release/ChargingPowerTool Dist/ChargingPowerTool.app/Contents/MacOS/ChargingPowerTool`
- **Clean**: `swift package clean`

## Architecture
- **Type**: macOS Status Bar Application (LSUIElement = true).
- **Language**: Swift (swift-tools-version: 6.0).
- **Platform**: macOS 13.0+.
- **Frameworks**: SwiftUI (UI), IOKit (Hardware Sensors).
- **Key Components**:
  - `Sources/ChargingPowerTool/`: Core application logic.
  - Uses IOKit to read real-time battery voltage and amperage.
  - Calculates power (Watts) and updates the menu bar interface.
  - Dynamic icon switching based on charging (positive power) vs discharging (negative power) state.

## Release & CI/CD Lessons Learned

### Ad-hoc Signing & No-Certificate Release
When releasing a macOS app without an Apple Developer Program membership ($99/year), specific workarounds are needed for CI/CD:

1.  **Xcode Archive**: `xcodebuild archive` requires a development team. If none is available, force unsigned build args: `CODE_SIGN_IDENTITY= CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`.
2.  **Export**: `xcodebuild -exportArchive` fails without a valid Team ID even with manual/ad-hoc settings.
    - **Fix**: Skip `xcodebuild -exportArchive` entirely. Manually `cp -R` the `.app` bundle from `.xcarchive/Products/Applications/` to the export directory.
3.  **Ad-hoc Signing**: Use `codesign --force --deep -s - VTS.app` to apply a local ad-hoc signature. This allows the app to run (user may need to right-click -> Open).
4.  **DMG Creation**: `sindresorhus/create-dmg` often fails in CI if no signing identity is found.
    - **Fix**: Use native `hdiutil create` command instead. It's robust and doesn't require signing identities.
5.  **Shell Scripting**: Be careful when capturing function output: `var=$(func)`. If `func` prints logs to `stdout`, they pollute the return value. Always redirect logs to `stderr` (`>&2`).
6.  **Keychain**: In CI, skip `security create-keychain` if no certificate secret (`BUILD_CERTIFICATE_BASE64`) is present.
