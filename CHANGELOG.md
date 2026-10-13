# Harmony Side Screen changelog

Formerly HarmonyScreen. Earlier SideScreen history is preserved in [UPSTREAM-CHANGELOG.md](docs/UPSTREAM-CHANGELOG.md); its version numbers are not Harmony Side Screen releases.

## 0.1.8 preview — 2026-10-12

- Rename the public project and app labels to Harmony Side Screen, by YouWo.ai. Keep bundle identities and saved preferences compatible.
- Add persistent Settings access, independent FPS/connection overlays, live diagnostics and stored display choices.
- Add an opt-in, byte-verified 16 MiB HDC transfer test, negotiated USB speed, video Mbps and echoed-ping RTT.
- Use timestamped decoder output submission to allow replacement of superseded frames; request higher XComponent refresh without claiming measured panel FPS.
- Prefer native 2× HiDPI and high encoding quality for new settings, and explain the softness tradeoff of matching Mac text size. Existing explicit settings are retained.
- Record the historical sizing paths and actual verification boundaries. Larger system-wide text with full native 3K detail remains incomplete.
- Public Mac preview; native debug-signed Huawei build remains private and device-specific.

## Earlier previews

| Version | Main change |
|---|---|
| 0.1.7 | Quiet reconnect, connection health and phone-side display placement |
| 0.1.6 | Create a display only for a connected viewer; remove it after disconnect |
| 0.1.5 | Keep HDC recovery active in either Mac connection mode |
| 0.1.4 | Non-blocking recovery and automatic phone rotation |
| 0.1.3 | Optional support invitation after each qualifying session |
| 0.1.2 | Initial support invitation and release video |
| 0.1.1 | Live stream FPS and free YouWo.ai branding |
| 0.1.0 | Initial HDC host and native HarmonyOS developer preview |

See [source/tag history and configuration evidence](docs/VERSION-HISTORY.md). A version tag alone does not preserve system preferences or prove physical-device performance.
