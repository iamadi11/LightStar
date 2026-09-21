# Experimental/DirectCapture — gated off, not linked

**Status: not feasible for video. Do not enable. Do not import into LightStar / LightStarCore.**

This folder is a parking lot for the “GPU / HDMI-reader driver” idea. It is **not** compiled, not in `project.yml`, and not a ScreenCaptureKit replacement. The shipping app stays on the current Screen + Music + Both path.

---

## Idea

A driver that behaves like a DisplayPort/HDMI capture card: read pixels at the GPU and samples at the sound card, skip Screen Recording permission, lower latency, plug-and-play.

## Verdict

| Path | Feasible on Apple Silicon? | Sees Netflix/Prime with HW accel on? | Skips Screen Recording TCC? |
|------|----------------------------|--------------------------------------|-----------------------------|
| Software “HDMI/DP reader” dext/kext | No — no framebuffer API | No | No |
| GPU/Metal/IOSurface of another process | No | No | No |
| Virtual display that looks like a monitor | Partial (private API) | No — `preventsCapture` still black | No |
| Real HDMI/USB capture card on a second port | Hardware, yes | No — HDCP blanks capture sinks | N/A (external box) |
| Background `screencapture` / script | Yes, same pixels as SCK | No | No — still TCC |
| Core Audio HAL virtual device (BlackHole-style) | Yes, as a **separate install** | Audio only, not video | Audio: no Screen Recording; still not plug-and-play |

Protected video is replaced with black **inside WindowServer** (and HDCP on the wire). A driver below that still does not receive those pixels. Apple Silicon’s display coprocessor (DCP) owns the panel; user-space and DriverKit cannot mmap it.

A background script does not dodge permission. `screencapture` and ScreenCaptureKit share the same TCC.

BLE to the strip is coalesced at **20 ms**. Even a magic GPU tap would not beat that for LightStar’s output.

## If this is ever revisited

1. Keep all code in this folder. Do not add it to `project.yml` or LightStarCore until it has a measured, non-DRM proof (YouTube/desktop) and an explicit product flag.
2. Do not implement Widevine/FairPlay key extraction, HDCP bypass, or SkyLight private compositor reads.
3. The only adjacent experiment that is real is an **optional virtual audio device** for Music Pulse without an SCK audio stream — still a signed dext the user installs, not silent plug-and-play.

## Enable flag (unused)

`ENABLED=0` — shipping LightStar ignores this folder.
