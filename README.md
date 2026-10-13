# Harmony Side Screen

**A free, open-source second screen for Mac → HarmonyOS over USB.**
By [YouWo.ai](https://youwo.ai), maintained by Shonn Li. Formerly HarmonyScreen.

[Releases](https://github.com/Shonn-Li/HarmonySideScreen/releases) · [Version history](docs/VERSION-HISTORY.md) · [Changelog](CHANGELOG.md) · [Protocol](docs/HDC-TRANSPORT.md)

Connect an authorized Huawei phone, open the native receiver, and use it as an independent Mac desktop. The host creates a virtual display, captures and encodes it with hardware HEVC, and sends it through Huawei HDC USB forwarding. The native ArkTS/C++ receiver decodes onto the phone surface. No account or subscription is needed.

## Current preview: 0.1.8

- Full-panel 3184 × 2232 playback tested on Mate XT 2; portrait and landscape viewport resizing.
- Quiet reconnect, removal of an unused virtual display, and phone-side placement controls.
- Tap the Huawei screen for controls. A small Settings button remains available when controls are hidden.
- Independently show/hide live stream FPS and connection information; preferences survive receiver restarts.
- View negotiated USB speed, actual video bitrate, round-trip time and frame resolution.
- Run an opt-in 16 MiB transfer-and-byte-validation test to compare the complete cable/port/HDC path.
- Native 2× HiDPI and high encoder quality are the defaults for new settings. Saved preferences remain intact.

**Developer preview, not an AppGallery release.** The public download is a Developer ID-signed Apple Silicon Mac DMG; it is not notarized. The installed Huawei debug HAP is restricted by a private provisioning profile and is **not** a public download. Build and sign the open-source receiver for your own device. General Huawei distribution and other device models remain unverified.

## Sharp text and frame rate

The physical panel, logical desktop and encoded frame size are separate.

| Configuration on the tested unfolded phone | Logical desktop | Source pixels → encoded pixels | Tradeoff |
|---|---:|---:|---|
| Native 2× HiDPI | 1592 × 1116 | 3184 × 2232 → 3184 × 2232 | Preserves panel detail; text can be physically small |
| Match Mac text size, tested Mac scale | 1060 × 742 | 2120 × 1484 → 3184 × 2232 | Larger text, but the source is enlarged and can look soft |
| Native + application zoom | 1592 × 1116 | 3184 × 2232 → 3184 × 2232 | The application redraws larger text; does not resize every macOS menu |

The tested Grok Bot window used 150% application zoom. This is not an automatic, system-wide 3× rendering solution. Merely encoding a frame as “3K” cannot restore detail missing from its source.

Stream FPS counts decoder submissions, not actual panel refresh or end-to-end latency. Some tests exceeded 100 stream FPS while the panel reported 60 Hz. A 120 FPS request is not a verified sustained 120 Hz display claim. USB 5 Gbps is negotiated link capacity, not measured video usage. See the [dated measurements and limitations](docs/PERFORMANCE-2026-10-12.md).

## Build and connect

### Mac

Requires macOS 13+, Xcode command-line build tools, and official Huawei HDC with its runtime dependencies.

```sh
git clone https://github.com/Shonn-Li/HarmonySideScreen.git
cd HarmonySideScreen
scripts/package_harmony_mac.sh
```

The output is `dist/Harmony Side Screen.app` and a versioned arm64 DMG. Set `SIGNING_IDENTITY` to your own certificate name for Developer ID signing; without it, the local build is ad-hoc signed. Existing bundle IDs and preference keys are preserved for upgrades.

Install official Huawei Command Line Tools. Place HDC in a location supported by `MacHost/Sources/HDCBridge.swift`, or set `HARMONYSCREEN_HDC`. Connect one phone with a data cable, unlock it and approve USB debugging. Open the Mac app, grant Screen Recording permission and start USB streaming. HDC readiness alone does not prove video playback.

### HarmonyOS

Open `HarmonyClient` in DevEco Studio and configure your own supported Huawei signing. The checked-in public profile has no signing credentials. The current build uses DevEco Studio 6.0.1.251 / SDK 6.0.1.112 (API 21), minimum API 13; the tested phone reports OpenHarmony 7.0.0.107 / API 26. The minimum API is not a promise of broad device coverage.

```sh
scripts/build_harmony.sh
# DevEco automatic-signing profile must be stored outside this repository:
python3 scripts/build_harmony_signed.py \
  --profile /private/path/deveco-build-profile.private.json5 \
  --output /private/path/HarmonySideScreen-device-debug.hap
```

The first command produces an unsigned release-mode HAP. A retail phone requires a Huawei-issued signing certificate and provisioning profile. The second command stages private signing in a temporary copy and refuses to overwrite an existing output. Never publish a device-specific debug HAP, private keys or provisioning profiles.

Open the receiver after installation. It connects to localhost:54322 through the HDC tunnel and retries while foregrounded unless explicitly disconnected. Native phone touches operate its controls; they do not remotely click Mac applications. Native wireless pairing, audio and remote Mac touch input are not enabled. A sleeping/locked phone may need to be unlocked and reopened.

## Validation and version records

```sh
python3 scripts/check_harmony_version.py
swift test --package-path MacHost
clang++ -std=c++17 -fsanitize=address,undefined tests/wire_test.cpp -o /tmp/harmony-wire-test
/tmp/harmony-wire-test
clang++ -std=c++17 -fsanitize=address,undefined HarmonyClient/tests/transfer_test.cpp -o /tmp/harmony-transfer-test
/tmp/harmony-transfer-test
```

Device tests such as `scripts/test_hdc_recovery.py` intentionally interrupt the tunnel; run them only during a test session.

Every delivered version should have a source commit, immutable preview tag, configuration/evidence record and artifact checksums. Code-only history cannot reproduce external display preferences. See [version policy](docs/VERSIONING.md) and [0.1.8 record](docs/versions/0.1.8.json). Earlier same-day parameter experiments were not all separate releases; missing state is marked unknown.

## License and support

MIT. The Mac host originated in [SideScreen](https://github.com/tranvuongquocdat/SideScreen) by Quoc Dat Tran and contributors. The original license and attribution are preserved in LICENSE and NOTICE; new HDC integration and native HarmonyOS work is copyright 2026 Shonn Li. This project is not affiliated with Huawei or Apple.

The app remains free. An optional Mac support invitation exists, but checkout stays disabled until a verified YouWo-owned payment destination is configured. See [support setup](docs/SUPPORT.md). Source availability does not imply AppGallery approval, notarization, or universal plug-and-play installation.
