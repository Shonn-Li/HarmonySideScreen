# Release readiness

## Harmony Side Screen 0.1.8 preview

The project and app labels are now Harmony Side Screen, by YouWo.ai. The public
repository is https://github.com/Shonn-Li/HarmonySideScreen; previous releases,
MIT attribution, bundle identities and saved preferences are retained.

Built and installed the Developer ID-signed Mac and private debug-signed Huawei
0.1.8 on 2026-10-12. All 75 Swift tests and four portable C++ sanitizer test
programs passed. Automatic HDC reconnect, the renamed native UI, persistent
Settings access and full-resolution source/received images were checked. A
one-pixel stripe sample retained near-full luminance contrast on the receiver.
The current link independently reports 480 Mbps; earlier same-day 5 Gbps and
367 Mbps payload measurements belong to a different observed link state and
must not be relabelled as final-build measurements.

Public release assets are the signed arm64 Mac DMG and SHA-256 checksum file.
The native HAP remains private and device-specific. New settings prefer native
2x HiDPI and high quality; existing saved settings are preserved. General large
system-wide text with native 3K detail is still incomplete. See the exact
[configuration/build record](versions/0.1.8.json), [history](VERSION-HISTORY.md)
and [performance evidence](PERFORMANCE-2026-10-12.md). This is a developer preview,
not an AppGallery release or a claim of sustained 120 Hz physical presentation.

## Mac and Huawei 0.1.7 preview

Installed on the owner's Mac and authorized Mate XT 2 on 2026-10-09. Reconnect
attempts now keep stable buttons and actionable instructions. The receiver
checks connection health, clears the stale desktop after a failure, and resumes
when brought back to the foreground. The Mac handles confirmed USB disappearance
as a disconnect even if an HDC socket remains open, and serializes USB probes and
tunnel repair. The phone adds Left / Right / Above / Below placement controls.

Verified:

- 72 Swift tests passed, including fragmented placement requests followed by
  heartbeat traffic, invalid placement payloads, and forced USB client teardown
  with the listener remaining available. Portable C++ wire, frame-rate and
  connection-health tests passed with address/undefined-behavior sanitizers.
- The installed phone retried a deliberately silent local Mac connection after
  about eight seconds on two attempts. Waiting-screen button labels and bounds
  were unchanged between repeated retries; next-step instructions were present
  in the device's UI layout after the final UI build.
- The installed receiver displayed actual decoded Mac frames at 2232×3184 after
  the updated host started. Foreground return and display removal after the
  phone session ended were observed. A full-screen device image was inspected.
- Removing the HDC reverse tunnel was repaired automatically in 1.1 seconds.
- A local protocol client exercised all four placement commands against the
  installed host. CoreGraphics confirmed the requested sides with one display
  identity and unchanged other-screen positions; the original setting was
  restored afterward. Phone-side taps and a physical cable unplug/replug still
  await user confirmation; tunnel repair is not proof of those manual actions.

Mac release assets contain the Developer ID-signed arm64 DMG and its checksum.
The native 0.1.7 debug HAP is installed privately on the registered Huawei, not
published as a generally installable package. Notarization and AppGallery
distribution remain separate unfinished gates.

## Mac 0.1.6 preview

The installed Mac host now waits for a viewer before creating a virtual display
or starting capture. A detected disconnect starts a five-second grace period;
afterward, the monitor and capture are removed while the listener and HDC
recovery stay available. Short reconnects retain the monitor identity. Graceful
socket closure is now detected even without another frame being sent, and
cancelled connection setup cannot reactivate an unused display.

Verified on 2026-10-07 with the installed Developer ID-signed arm64 app:

- All 69 Swift tests passed. The graceful-close regression fails with the old
  receive behavior and passes with the fix.
- Cold startup with no phone left only the built-in Mac display active.
- `python3 scripts/test_display_lifecycle.py` passed two connection cycles,
  independently decoding 15 HEVC frames at 2232×3184 per cycle. The virtual
  monitor disappeared in 5.69 and 5.61 seconds after the test viewer closed.
- Closing during display preparation left no monitor behind. The listener
  remained available, and the host released its display-sleep assertion.
- The Huawei was disconnected during this validation. These are real Mac
  capture/display checks with a local test viewer, not fresh phone playback or
  physical cable-unplug verification. The native Huawei receiver remains 0.1.4.

This Mac preview is signed but not notarized. AppGallery distribution remains
subject to the gates below; private Huawei debug signing assets are excluded.

## Previous device validation and distribution gates

0.1.4 was installed on the owner's Mac and Mate XT 2. It added non-blocking host
recovery, streaming on launch by default, and sensor-based follow-phone rotation
even when the phone's general rotation lock is enabled. Landscape/portrait
resizing and recovery from a deliberately occupied host port were verified.
The AppGallery `.app` archive is built locally but unsigned. The signed-in Huawei
portal requires developer real-name verification; store submission has not
occurred. See [submission materials](APPGALLERY-SUBMISSION.md).

Completed: Mac build, Swift tests, HDC USB data round-trip, portable frame validation, Mac Developer ID package signing, native arm64 HAP compilation in release mode, Huawei debug signing and installation on Mate XT 2, native full-screen 3184×2232 playback and automatic recovery after a Mac stream restart. Independent Mac HEVC decoding passed at 1920×1200 and 3184×2232.

Required before an end-user HOS 7 release:

- Native client compiled using DevEco Studio 6.0.1.251 / SDK 6.0.1.112 (API 21), matching the editor; an earlier API 24 command-line build also passed. Preview versioning is maintained separately from supported SDK/API versions. Signing warning is expected until the certificate/profile are configured.
- Debug certificate/profile generation and signed installation have succeeded for com.shonnli.harmonyscreen. Obtain appropriate distribution signing before advertising a generally installable HAP.
- Keep device-specific debug HAPs, private keys, provisioning profiles and device identifiers out of public release assets.
- First displayed frame, full-screen resolution/HiDPI and a Mac stream restart are verified. Still test sustained performance, physical unplug/replug, app backgrounding, malformed frame handling and decoder errors on the device.
- Verify window focus/reopen and permissions on a clean Mac installation.
- Notarize the Developer ID-signed Mac DMG with the owner's Apple developer credentials and staple the ticket.
- Publish native HAP and Mac artifacts only with accurate device/test coverage and SHA-256 checksums.

Current preview is not an AppGallery release. DevEco automatic signing produced a debug HAP that installed and displayed the Mac desktop full-screen on the authorized Mate XT 2. The debug HAP is retained privately because its provisioning profile is device-specific.

0.1.1 adds phone-side stream FPS, YouWo.ai branding, packaged MIT attribution and idle-boundary timeout handling. The owner’s signed phone installation and a full Mac host update/restart are verified. It remains a $0 developer preview with the distribution gates above.
