# Source and display-configuration history

The project was renamed from HarmonyScreen to **Harmony Side Screen** on 2026-10-12. The repository and its eight existing preview releases are retained rather than replaced. Upstream SideScreen tags are unrelated product versions.

## Existing releases

| Release | Source commit | Main change |
|---|---|---|
| [0.1.0](https://github.com/Shonn-Li/HarmonySideScreen/releases/tag/v0.1.0-preview.1) | eac71f9 | HDC host/native client preview; initial tag predates verified signed phone playback |
| [0.1.1](https://github.com/Shonn-Li/HarmonySideScreen/releases/tag/v0.1.1-preview.1) | bd2c48c | Rolling stream FPS, YouWo.ai branding |
| [0.1.2](https://github.com/Shonn-Li/HarmonySideScreen/releases/tag/v0.1.2-preview.1) | fb54e88 | Initial support invitation and release video |
| [0.1.3](https://github.com/Shonn-Li/HarmonySideScreen/releases/tag/v0.1.3-preview.1) | a7058be | Recurring optional support |
| [0.1.4](https://github.com/Shonn-Li/HarmonySideScreen/releases/tag/v0.1.4-preview.1) | d29c7bc | Stream recovery and phone rotation |
| [0.1.5](https://github.com/Shonn-Li/HarmonySideScreen/releases/tag/v0.1.5-preview.1) | 242b7fa | HDC recovery in either connection mode |
| [0.1.6](https://github.com/Shonn-Li/HarmonySideScreen/releases/tag/v0.1.6-preview.1) | 7894a86 | Remove disconnected virtual display |
| [0.1.7](https://github.com/Shonn-Li/HarmonySideScreen/releases/tag/v0.1.7-preview.1) | 8bfc5e9 | Quiet reconnect and phone placement |
| [0.1.8](https://github.com/Shonn-Li/HarmonySideScreen/releases/tag/v0.1.8-preview.1) | resolved by tag | New name, native-detail defaults, control/USB diagnostics; [configuration record](versions/0.1.8.json) |

The older release/tag mapping above was read from GitHub on 2026-10-12. Local tags had not all been fetched; GitHub already contained the eight previews.

## What the early display actually used

All verified native versions below use a Mac virtual display, hardware HEVC encoding, HDC USB forwarding, and a native HarmonyOS decoder. No change from this architecture to a new cable-specific display protocol occurred.

| Recorded state | Evidence | Logical desktop | Source → stream | Target / observed cadence |
|---|---|---|---|---|
| Initial transport experiment | BUILD-EVIDENCE.md | Not fully recorded | Encoded 1920 × 1200 | Transport decode verified; not phone presentation |
| Oct 4 full-screen native receiver | Commit 0baab03; BUILD-EVIDENCE.md | 1592 × 1116, 2× HiDPI | 3184 × 2232 → 3184 × 2232 | Target 30 FPS; later 0.1.1 receiver samples 28–30 |
| Oct 4 physical-size matching | Commit 7311ba2; BUILD-EVIDENCE.md | 1060 × 742 with the tested Mac scale | 2120 × 1484 → 3184 × 2232 | Bigger text by enlarging source; not native detail |
| Oct 12 text-size/native-detail experiments | PERFORMANCE-2026-10-12.md | Switched between the two layouts above | Same 3K encoded output, different source detail | Target 120; some stream samples above 100; panel also observed at 60 Hz |
| Current tested native + app zoom | 0.1.8 record | 1592 × 1116; Grok Bot content zoom 150% | 3184 × 2232 → 3184 × 2232 | Stream FPS is not physical panel refresh |

Some Oct 12 edits/parameter trials reused the 0.1.7 bundle version before the 0.1.8 snapshot. They were **not** all independently tagged releases. Existing private HAPs and Mac backup bundles are preserved, but exact source/configuration mapping for every trial cannot be reconstructed from the version string alone.

## Why “large, sharp, but delayed” is not contradictory

Glyph rendering, encoded video quality, frame rate and queue latency are independent. HiDPI can render sharp text at a low frame rate. A queue can deliver many frames per second while still showing old frames. The earlier decoder output change reduced measured input-buffer waiting in one test, but end-to-end latency was not established. We cannot identify the user's exact remembered session or prove its delay was caused by the cable.

The desired large-and-sharp system-wide result needs a sufficiently detailed source at the desired logical size. Encoding a smaller bitmap into a 3K frame does not provide that. The present app-zoom workaround redraws supported app content but does not change all macOS menus or other apps.
