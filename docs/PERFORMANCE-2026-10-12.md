# High-refresh investigation — 2026-10-12

## Result

120 FPS is a requested target, **not a verified sustained display result**.
The receiver build supports the full panel resolution. The initial test used
2232 × 3184 portrait; the later recovery below uses 3184 × 2232 landscape.
The final motion test measured roughly 59–60 decoded/submitted FPS and the
phone's RenderService reported 60 Hz. Mac capture and encoding are configured
for 120 FPS; the virtual display advertises 120 Hz. Huawei's display setting was
changed from Smart to High (up to 120 Hz).

Earlier lower-resolution experiments received about 80–100 FPS after the
queue fix, but the panel remained at 60 Hz. Those resolution changes were
reverted. Brief higher refresh after touch is not proof of sustained 120 Hz.
The final Mac test had two additional AirPlay displays active; this differs
from the initial capture environment and prevents a clean host A/B comparison.

## Retained change

Use `OH_VideoDecoder_RenderOutputBufferAtTime` with the current monotonic
timestamp. This lets the compositor discard superseded decoded frames at a
vsync instead of requiring every queued frame to be shown. In the same
lower-resolution test, average decoder-input-buffer waiting fell from about
15.7 ms to 0.00–0.04 ms. This is an internal wait measurement, not an end-to-end
latency measurement. Full-resolution final measurements also had near-zero
input-buffer waiting.

Request up to 120 Hz through the XComponent API and provision the decoder for
120 FPS. Requests return success, but the OS still decides the final refresh
rate. Deregister on stop, surface destruction, or a worker failure observed
by the UI's existing status poll. The redundant page-level DisplaySync
experiment was removed. Existing quiet reconnect and placement controls remain.

The on-device counter is labelled **stream FPS** and its explanation states
that decoded frames are counted and screen refresh may be lower. A successful
decoder submission is not proof that every submitted frame was scanned out.

## USB and validation

- Negotiated USB link: 480 Mbps. This does not establish a defective cable.
- A 16 MiB stop-and-wait HDC roundtrip completed with matching content at about
  22 Mbps payload rate. This is not a maximum unidirectional bandwidth test.
- Stream traffic during these tests was about 0.7–3.5 Mbps.
- Native wire, rolling-FPS, and connection-health tests passed.
- Final HarmonyOS signed build, installation, launch, and automatic USB
  connection succeeded on the connected Mate XT 2.
- The original Developer ID signed Mac application was restored after the
  resolution experiment; its persisted refresh target remains 120.
- Device-specific signing artifacts remain private. No public release or
  store submission was made from these experimental changes.

## Remaining work

Determine why the active video surface settles at 60 Hz despite accepted
120-Hz requests. Profile the full-resolution host capture/encoder separately
from concurrent AirPlay displays. Verify actual presentation cadence, not just
decoder output, before advertising 120 FPS support.

References: the installed SDK's `native_avcodec_videodecoder.h` documents
timestamped frame replacement; [Huawei's XComponent frame-rate guide](https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V13/displaysync-xcomponent-V13)
documents refresh requests.

## Later orientation and wrong-display recovery

Observed an independent capture-mapping failure with Sidecar and MacBook Air
AirPlay displays active. CoreGraphics reported no mirroring on any display,
but Huawei showed a landscape desktop letterboxed into the portrait stream.
A clock window placed specifically on HarmonyScreen did not appear there.
The ScreenCaptureKit filter matched the intended virtual display ID.

Quit HarmonyScreen, disconnected the two AirPlay displays, and verified only
the built-in display remained. Relaunched HarmonyScreen with phone orientation
set to Landscape. Huawei then filled its 3184 × 2232 viewport, and the clock
window placed on HarmonyScreen became visible. This is verified recovery of
the current session, not a permanent fix for every virtual-display reconnect.

Reconnected Sidecar and restored its origin to (277, -834); HarmonyScreen
remained an independent display at (1728, 0), logical size 1060 × 742. The
clock remained visible after Sidecar reconnected. MacBook Air stopped
appearing in the display picker and Bonjour discovery, so its reconnection
could not be completed. Its previous origin was (-1920, 0).

Before Sidecar reconnection, two short phone observations showed 85 and
77 decoded stream FPS. After Sidecar reconnected, the overlay showed 60
and RenderService reported 60 Hz. This is not a controlled benchmark.
The USB link continued to report 480 Mbps.

A screenshot of the streaming clock contained timestamp 1791833495376 ms;
the phone screenshot request ran between host times 1791833495169 and
1791833495693 ms. The wide acquisition window does not yield a precise
end-to-end latency; it does not establish physical display scan-out latency.

This matches the known macOS virtual-display capture confusion described in
[BetterDisplay issue 4405](https://github.com/waydabber/BetterDisplay/issues/4405).
A full virtual-display reconnect is disruptive and must not run automatically
against unrelated user displays as a blanket recovery.

## Native-resolution clarity correction, later same day

The original SanDisk SSD cable negotiated 5,000,000,000 bps (USB 3),
verified from the HDC device's UsbLinkSpeed. After unlocking and launching
the receiver, a native extended desktop reconnected. No AirPlay displays
were active in this later test, so differences from earlier FPS measurements
cannot be attributed solely to the cable.

The user clarified that the complaint was low resolution, not darkness.
A grayscale comparison had already shown near-identical code values between
the source and phone screenshots (including 0, 128, and 255), with at most
2 levels of difference in sampled neutral patches. No brightness setting
was changed. This does not constitute full color calibration.

Found a real scaling mismatch: Match Mac text size produced a 1060 × 742
logical desktop / 2120 × 1484 backing image, then capture upscaled it to
3184 × 2232. The encoder quality preference was also absent, selecting the
ultralow default. Persisted Match Mac text size = false and Quality = high,
retaining automatic phone fitting, landscape, and the requested 120 FPS.
Preferences before this change were exported privately to
/tmp/harmonyscreen-before-native-resolution.plist.

Verified the resulting desktop is 1592 × 1116 logical and the source capture
is 3184 × 2232, matching the phone screenshot dimensions exactly. A static
1-physical-pixel black/white stripe test preserved alternation: source mean
adjacent contrast 255.0, phone screenshot 253.7 over the sampled 220 pixels.
This verifies the removal of enlargement blur, not lossless video or physical
panel optical sharpness. Text becomes smaller because the desktop now uses
native 2x Retina density rather than matching the Mac's physical text size.

High-quality capture ran around 104–110 pipeline FPS and the phone overlay
showed 109 FPS; typical mostly static desktop video was around 8–10 Mbps.
The inner panel briefly reported 120 Hz, but three later polls over 10 seconds
returned 60 Hz. Sustained 120 Hz and end-to-end latency remain unverified.
Temporary grayscale, stripe, and text test windows were closed.


## Physical text-size restoration after user feedback

The native-pixel experiment made the desktop too large and text too small.
Restored persisted Match Mac text size = true while retaining Quality = high,
landscape orientation, automatic phone fitting and the 120 FPS request.
The host reconnected over HDC without user approval or a flashing retry loop.

Live verification:
- Mac: 1728 logical units across 344.2447 mm, or 5.019685 units/mm.
- HarmonyScreen: 1060 logical units across 211.1686 mm, also 5.019685 units/mm.
- Phone display: independent extended desktop, logical 1060 × 742, backing
  2120 × 1484, output 3184 × 2232. The live clock placed only on this desktop
  appeared in the phone screenshot. This verifies capture mapping for this run.
- HDC USB link still reports 5,000,000,000 bps. Phone HUD showed 104 stream FPS;
  the inner panel reported 60 Hz in the same check. These are different metrics.
- Before restoration, moving desktop content reached about 56 Mbps, with
  mostly static content around 7–8 Mbps. The physical link was not saturated.

The larger-text setting requires upscale from the macOS 2x backing image.
Do not call this native-detail 3K just because the encoded frame is 3K. The
previous 1-pixel stripe result applies only to the smaller-text native setting.
A general 3x macOS backing scale has not been implemented or verified.

The source review also confirms no bounded network-send backlog in sendFrame;
the existing pending-encode guard is not an end-to-end queue/latency bound.
This is a concrete optimization target, not proof that backlog caused the
present session's latency. Capture-to-presentation latency and sustained panel
cadence still need measurement before claiming Sidecar-equivalent performance.

## Connection controls and cable diagnostics

Added a persistent optional FPS overlay, a tap-accessible settings panel,
negotiated USB Mbps, receiver-side video Mbps, and monotonic echoed-ping RTT.
Manual settings remain open until dismissed; initial connection controls still
hide automatically. Native surface touches are separated from overlay controls.
The FPS overlay itself also opens controls, rather than swallowing the tap.

A manual 16 MiB HDC payload test verifies every byte and reports effective Mbps
and MB/s. Video pauses for the test and resumes with a requested keyframe. It
measures this complete path, not isolated cable efficiency or USB line rate.
Unknown/ambiguous link speed remains unknown. Transport messages are opt-in
for compatibility with older peers. Interrupted or corrupted tests fail.

Mac unit suite: 75 tests passed, including diagnostics negotiation and malformed
link properties. Portable transfer checker passed with address/undefined
behavior sanitizers, including truncated, corrupted and overflowing payloads.

On-device validation: tapping the desktop or FPS badge opens controls; tapping
the backdrop hides them. The settings container uses Default hit testing so
its children remain interactive, while the native surface is excluded. A
real 16 MiB test passed byte validation at 367.0 Mbps (45.9 MB/s), followed by
a fresh video keyframe and resumed playback. The current negotiated link is
5.0 Gbps. The short payload test is not an isolated cable certification.

The final phone build fixes live metric-row updates (values formerly captured
by value in a builder). Two samples with settings continuously open changed
from 7.3 Mbps / 3.0 ms / 109 FPS to 0.6 Mbps / 9.9 ms / 75 FPS. The FPS-on
preference survived an app update/relaunch. Switching it off and hiding the
controls removed all HUD text while preserving the live surface. The previously
restored 1060 × 742 physical text-size matching remained active at that point.

## Follow-up: native pixels with application text zoom

The user reported that the physical-size restoration was blurry and that the
controls still appeared inaccessible. The active configuration now supersedes
the physical-size restoration above: Match Mac text size is false, Quality is
high, the extended display is 1592 × 1116 logical, and the captured backing
and received phone frame are both 3184 × 2232. Grok Bot was reset to its default
application zoom and increased by five 0.1 steps to 150%, using its existing
Electron zoom shortcuts. Its window fills the extended desktop. This renders
Grok content at a larger size without enlarging a lower-resolution bitmap.
It is a per-application workaround, not a general 3x macOS desktop scale;
system menus and other applications retain their own sizes. Zoom persistence
across Grok Bot restarts has not been verified.

A temporary isolated virtual-display probe tried hiDPI settings 1, 2, and 3.
The current macOS interface did not expose a usable 3x backing mode. The probe
display was removed. This does not establish that every possible macOS
implementation is incapable of providing the desired result.

Live pixel verification used a temporary window with alternating one-pixel
black and white lines, at the same coordinates in source and phone snapshots.
Both snapshots were 3184 × 2232. Mean even/odd stripe values were 0/255 in the
Mac capture and 0.2/254.0 in the received JPEG snapshot (253.8 contrast).
The test window was removed. This demonstrates preserved one-pixel luminance
detail for this sample, not lossless color or sustained frame presentation.

Both the previous blurry setting and this native setting encode 3184 × 2232;
the former does not proportionally save transmitted video pixels. Native
source rendering contains approximately 2.26 times as many pixels as the
2120 × 1484 backing. GPU cost may increase; encoded bitrate depends on content.
One current sample showed 111 decoded/submitted FPS, 9.7 Mbps video and 8.3 ms
ping RTT, on a 5.0 Gbps negotiated USB link. These are not controlled A/B
resource measurements or capture-to-presentation latency measurements.

Added a persistent small Settings button even when overlays are hidden, and
debounced control actions to prevent an immediate second toggle. The entry
point was tested using HDC-injected touches. The user then explicitly
confirmed that physical finger tapping on the Huawei works. It does not
represent support for clicking native Huawei controls with a Mac pointer.
FPS and live connection information can be selected independently; the
compact diagnostic overlay itself also opens Settings and no longer needs a
full-screen hit-test layer. Preferences are stored on the phone.

The signed client build `HarmonyScreen-0.1.7-selectable-diagnostics-signed.hap`
was installed on the connected Huawei. Both enabled preferences survived a
force-stop/relaunch. Tapping the diagnostic overlay opened Settings; showing
only connection information hid FPS, and turning both off left just the small
Settings entry and the desktop. The final state leaves both optional overlays
off. The signed HAP SHA-256 is
`25930fc3735f4f6cb508a819bb1ef26ff968dae079f19c10690ac8def24a1f32`.
The phone build and `git diff --check` passed. No public release was made.

## Versioned 0.1.8 follow-up

The preceding paragraphs describe earlier same-day experiments. They were
consolidated into the renamed Harmony Side Screen 0.1.8 build. Both apps now
report 0.1.8 (Huawei versionCode 108). Automatic reconnect and the renamed phone
controls worked after installation. The native pixel check was repeated on
this installed build: 3184 × 2232 source and receiver, mean stripe values 0/255
and 0.25/254 respectively. The temporary window was closed.

The current HDC device now reports UsbLinkSpeed = 480000000, confirmed both in
IOKit and the receiver. The cause of the changed negotiation was not established;
do not assume that the same cable/port state as the earlier 5 Gbps session is
still active. No controlled cable A/B or new throughput benchmark was run for
this final build. The static desktop sampled 0 FPS/video Mbps with live ping RTT;
that does not imply lost connectivity. Pixel-test updates arrived afterward.
The exact version, source tag, configuration and artifact hashes are recorded
in versions/0.1.8.json. Private desktop screenshots and debug HAPs are excluded
from public release assets.
