# Display output without Screen Recording: evidence and solution

Research date: 7 November 2026. Scope: LightStar on modern Apple Silicon macOS, its BC/55 strip, Mi lamp, and WiZ gradient floor light. This is a documentation/source/installed-SDK investigation, not a new Netflix, Prime, camera, or HDMI hardware test.

**Measured follow-up:** The user subsequently narrowed the scope to mainly Chrome and authorized direct-pixel testing. [The Chrome experiment](validation/browser-pixel-probe-2026-11-07.md) found readable clear video, but opaque black canvas output and rejected VideoFrame construction for a playing public Widevine clip, both with hardware acceleration and with `--disable-gpu`. Netflix/Prime remain untested directly. A straightforward browser sampler is therefore not established as a protected-video solution.

**Subsequent user requirement:** software only, covering everything on the Mac, including Safari and native apps. Under this constraint, the camera and HDMI recommendations below are excluded, and browser-only input is insufficient. No verified implementation meeting the full constraint has been established. ScreenCaptureKit remains the supported desktop source, with protected-content limitations; private graphics-stack modification remains unproven research. A proposed isolated browser pixel test was cancelled before session initialization when the user clarified whole-Mac coverage; it produced no playback or pixel-access evidence.

## Decision

There are viable ways to remove ScreenCaptureKit from the input path, but no verified universal software replacement that reads the final physical display signal, preserves protected playback, and needs no extra hardware.

Two practical choices meet different requirements:

1. **Keep LightStar responsible for all current lights:** add a camera input aimed at the screen. AVFoundation supplies frames; perspective correction and calibration produce a small BGRA image; existing LightStar colour analysis drives the lights. Camera permission replaces Screen Recording permission. This is the recommended implementation for a fully integrated LightStar solution.
2. **Drive compatible WiZ lights directly from HDMI:** use a WiZ HDMI sync box. This is an existing vendor-supported product path, including gradient floor lights. LightStar would hand control of those lights to the box. Receiving its colours in LightStar to drive the BC/55 strip or Mi lamp remains an unverified, separate integration project.

If the requirements also prohibit a camera and extra HDMI hardware, this investigation does not establish a complete solution. Browser sampling is a useful limited option, not a substitute for arbitrary protected desktop video.

## Requirements that must be kept separate

- No Screen Recording permission or screen-sharing indicator.
- Correct, changing screen colours, including protected video.
- Browser playback remains accelerated, with its existing quality.
- Existing monitor resolution, refresh rate, HDR, and VRR are preserved.
- All current lights remain controlled by LightStar.
- No additional hardware.

An approach can satisfy some of these while failing others. A software-rendering workaround may restore capturable pixels but still uses screen capture. A sync box may eliminate screen capture while keeping the light engine outside LightStar.

## Evidence matrix

| Approach | Avoids macOS Screen Recording? | Protected-video coverage | Fit for LightStar |
|---|---|---|---|
| ScreenCaptureKit, legacy capture, background screenshot helper | No | Protected regions may be withheld | Current desktop solution |
| Chrome with graphics acceleration disabled | No, if still using desktop capture | Vendor-documented workaround; service-specific outcomes need testing | Compatibility option only |
| Browser extension sampling readable video | Potentially, without desktop-capture APIs | EME permits pixel access to be withheld | Limited browser source |
| Browser tab-capture extension | Browser capture authorization still applies | Not a guaranteed DRM workaround | Still a capture mechanism |
| Own video player / renderer | Yes for frames it owns | Owning a player does not guarantee protected-frame access | Good for local/accessible media |
| WidevineProxy2 plus a separate playback pipeline | Potentially | Depends on keys, streams, service and CDM compatibility | Major new system; not a frame provider |
| DriverKit / VideoDriverKit | No display tap established | No demonstrated access to protected scanout | Research hypothesis only |
| Legacy kext or private GPU/compositor hooking | Unknown | Not demonstrated here | OS-specific research, not a product solution |
| Virtual display / DisplayLink | Not inherently; DisplayLink requires it | DisplayLink documents protected-playback failures | Does not solve the requirement |
| Ordinary HDMI capture card | Yes for external input | HDCP prevents capture | Useful for unprotected HDMI only |
| WiZ / Hue HDMI lighting sync box | Yes | Vendor-supported streaming-device path; validate actual chain | WiZ box fits compatible WiZ lights |
| Camera observing the panel | Yes; camera permission instead | Samples the picture the viewer can actually see | Best integration path for all lights |

### ScreenCaptureKit and permissions

Apple's sample explicitly requires Screen Recording authorization. Lowering resolution or extracting only a colour does not change the underlying acquisition permission. A command-line helper does not establish an independent display-signal source. [Apple capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)

Metal processes accessible textures. IOSurface shares buffers across processes; this does not establish permission to enumerate and read arbitrary other-process surfaces or the final output signal. [Apple IOSurface documentation](https://developer.apple.com/documentation/iosurface)

### Drivers: what is established, and what is not

Apple documents DriverKit as user-space device-driver infrastructure. Its overview is not proof that every framework absent from that page is absent from an installed SDK. [Apple DriverKit](https://developer.apple.com/documentation/driverkit)

Read-only inspection on this machine established:

- `sw_vers`: macOS 26.5.1, build 25F80; `uname -m`: arm64.
- Installed DriverKit SDK includes `VideoDriverKit.framework`, alongside audio, USB, HID, networking and other families.
- `IOUserVideoDriver.iig` describes a driver, host-controlled device I/O, and configuration changes.
- `IOUserVideoStream.iig` describes driver-owned streams and video buffers passed to a host.
- A case-insensitive search through its Headers for `framebuffer`, `scanout`, `windowserver`, and display-capture combinations returned no matches.

SDK root: `/Applications/Xcode.app/Contents/Developer/Platforms/DriverKit.platform/Developer/SDKs/DriverKit.sdk/System/DriverKit/System/Library/Frameworks/`.

**Conclusion:** the inspected framework does not demonstrate a facility for subscribing to Apple's existing GPU scanout. This is a bounded finding, not a proof that undocumented interfaces or research modifications can never work. Creating a video stream is different from obtaining the pixels to put into it.

The legacy `IOFramebuffer` interface is real and includes framebuffer-device functionality. Its existence is insufficient evidence that a third-party driver can attach to the shipping Apple Silicon graphics stack and read all its protected planes. Loading a custom kext on Apple Silicon requires a Recovery-mode security-policy change and explicit approval, before functionality is even considered. [Apple IOFramebuffer](https://developer.apple.com/documentation/kernel/ioframebuffer), [Apple custom-kext installation](https://developer.apple.com/documentation/apple-silicon/installing-a-custom-kernel-extension)

Asahi's display-driver work demonstrates that Apple display hardware can be reverse engineered. It also describes display scanout and composition as distinct operations: under Linux, a fullscreen application's framebuffer may be submitted directly to DCP. It is evidence of hardware programmability, not a ready macOS capture driver or proof of access to macOS protected content. [Asahi display work](https://asahilinux.org/2026/08/progress-report-7-2/)

Do not assume a single ordinary CPU-readable framebuffer contains everything visible on the panel. Nor assume every driver below WindowServer necessarily receives a black image: that earlier explanation overgeneralizes a more complicated protected-layer/output pipeline.

### DisplayLink and virtual displays

DisplayLink is a useful real-world counterexample to the idea that installing a graphics driver automatically avoids capture restrictions. Its Mac software explicitly requires Screen Recording authorization. Its support documentation also reports that protected content may become unavailable across screens while a DisplayLink screen is attached. [DisplayLink authorization](https://support.displaylink.com/knowledgebase/articles/2024872-displaylink-manager-first-time-configuration), [DisplayLink protected-video limitations](https://support.displaylink.com/knowledgebase/articles/830301-content-protected-video-does-not-play-on-mac-while)

A virtual display creates a display target; it does not by itself grant a readback channel to the physical monitor. Mirroring or capturing it still needs a demonstrated acquisition path. No new virtual-display runtime experiment was performed here.

### Browser extensions, custom browsers, and WidevineProxy2

The EME specification explicitly allows CDM-processed media data to be unavailable to APIs such as canvas `drawImage`. Thus an extension can sample readable videos, but cannot promise access to every protected video. Cross-origin canvas restrictions are a separate obstacle. [EME media-element restrictions](https://www.w3.org/TR/encrypted-media/#media-element-restrictions)

Browser tab/desktop capture APIs are capture APIs, not raw physical-output access. Chrome documents user invocation for tab capture and a selection flow for desktop capture. [Chrome capture guidance](https://developer.chrome.com/docs/extensions/how-to/web-platform/screen-capture), [Chrome desktopCapture](https://developer.chrome.com/docs/extensions/reference/api/desktopCapture)

Browser implementation matters: Mozilla documents a pipeline that carries a DRM flag from decoded images to macOS video layers and capture protection, as well as a regression fixed in that pipeline. This rules out treating one browser/version's behaviour as a universal property of all Widevine playback. [Mozilla implementation discussion](https://bugzilla.mozilla.org/show_bug.cgi?id=2073215)

[WidevineProxy2](https://github.com/DevLARLEY/WidevineProxy2) intercepts EME license exchanges and retrieves keys. Its README requires local device material or a remote CDM. It does not document an output of synchronized decoded frames or light zones.

Using it as the input to lighting would additionally require media acquisition, decryption, decoding, playback-position synchronization, seeking and adaptation handling, plus browser/service compatibility. It is technically a different architecture from reading the display. This research did not demonstrate such an integration and does not classify it as physically impossible. A custom browser/player may expose pixels it controls, but there is no evidence here that it will preserve Netflix/Prime playback quality and compatibility. Google also specifies a license agreement for use of Widevine products/services. [Google Widevine overview](https://developers.google.com/widevine/drm/overview)

Disabling browser acceleration is documented by DisplayLink as a workaround. It does not remove Screen Recording when LightStar still captures the desktop. Avoid the unsupported shorthand that this necessarily changes Widevine from L1 to L3: CDM security and the compositor's capture-exclusion behaviour are distinct questions.

### HDMI: capture cards versus lighting processors

An ordinary capture card cannot be assumed to read protected HDMI. Elgato explicitly says its devices cannot capture HDCP-enabled input. Passing video through a device is not evidence of exporting its pixels over USB. [Elgato HDCP limitations](https://help.elgato.com/hc/en-us/articles/360040482032-HDCP-and-Elgato-Capture-devices)

Purpose-built lighting processors are a separate product category. Hue publishes light-sync compatibility with HDCP 1.4/2.2/2.3 depending on box generation, demonstrating that HDMI lighting analysis is commercially feasible without exporting a general-purpose video capture stream. [Hue compatibility](https://www.philips-hue.com/en-us/support/hue-sync-compatibility)

For this project, WiZ is the closer fit:

- WiZ describes its box as analyzing HDMI input to control lighting. [WiZ operating principle](https://wizconnected.helpshift.com/hc/en/7-wiz-v2/faq/1065-how-does-the-wiz-hdmi-sync-box-with-tv-backlight-work/)
- Its compatibility guide distinguishes HDMI 2.0 at 4K60 from HDMI 2.1 at 4K120/8K60 and identifies external HDMI sources as the requirement. [WiZ compatibility guide](https://faq.wizconnected.com/hc/en/7-wiz-v2/faq/1073-will-the-philips-smart-lighting-hdmi-sync-box-connected-by-wiz-work-with-my-tv-setup/)
- Its additional-light guide supports compatible Wi-Fi/Bluetooth lights on the same network and multi-colour segment mapping for gradient floor lamps. [WiZ additional lights](https://faq.wizconnected.com/hc/en/7-wiz-v2/faq/1074-how-to-add-and-configure-additional-lights-in-the-sync-zone/)
- Signify's 2026 datasheet corroborates the newer box's 4K120/8K60 headline specifications. [Signify datasheet](https://www.assets.signify.com/is/content/Signify/GB.en_GB.8721103157492)

The exact LightTheatre lamp SKU, monitor timing, adapters, HDCP negotiation, HDR and VRR still require an actual-chain test. Headline resolution support does not prove every BenQ mode will survive. Mac HDMI output is a plausible source but was not tested. Built-in Mac-panel content has no equivalent inline cable insertion point.

No documented colour-grid export API for these boxes was established in this investigation. Their network lighting traffic might offer an integration lead, but availability, encryption, packet delivery to the Mac, semantics, fidelity and stability must be measured. Merely sharing Wi-Fi does not guarantee that the Mac sees unicast packets destined for a lamp. Lamp polling is not a validated substitute: LightStar's existing device notes say WiZ readback does not echo gradient `elm` data.

## Proposed LightStar implementation

For all existing lights under LightStar, implement an optional **Camera** source:

`AVCaptureSession → screen-corner crop / perspective correction → colour calibration → 48×27 BGRA → shared analysis → LampZonePipe + strip colour`

Apple documents camera capture authorization separately from screen capture. An external camera must physically see the panel; a MacBook's built-in camera normally points in the wrong direction. An iPhone rear camera could be an initial source, subject to positioning and capture testing. [Apple media authorization](https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos)

Implementation work:

1. Select a camera and map the screen's four corners; persist mapping per camera/display setup.
2. Correct perspective and compensate exposure/white balance where the device supports controls. Add black/white/colour calibration. Avoid light reflections and the LEDs' own spill creating feedback.
3. Analyze only the rectified small frame off MainActor. Start at 30 fps as a target, not a measured capability or latency promise.
4. Feed WiZ zones through `LampZonePipe`, and dominant colour through the existing connected/on-gated strip path. Preserve brightness control and power-off ordering.
5. Stop the display SCStream when Camera is selected. Keep system audio on the existing process-tap path for Combined, with explicit source lifecycle handling.
6. Distinguish optical black frames from the current protected-content heuristic. Camera frames should not automatically be treated as DRM when a film genuinely goes black.
7. Cancel capture and release the device on source changes, sleep and teardown; handle camera disconnects and stale frames explicitly.

Source inspection found that `ScreenFrameProvider` exists, but `ScreenColorSampler` currently stores the concrete `ScreenCaptureKitProvider` and calls its extra audio/zones/diagnostic methods. Therefore this is not a one-line provider swap. Extract a source-neutral frame-analysis entry point and preserve source-specific controls.

`CanvasEngine.onLightFrame`, `LightBLEManager.takeCanvasFrame`, `LampGradient.screenZones` and `LampZonePipe` already demonstrate internally generated pixels driving lights without screen capture. Reuse their analysis/transport structure, but do not make Camera pretend to be Canvas: that method's lifecycle and colour application are canvas-specific.

For a WiZ-box mode instead, implement explicit ownership handoff: stop LightStar WiZ streaming, mirror writes and heartbeat resends that would override the box; restore the chosen look on exit. BC/55 and Mi output cannot be promised to follow until a real colour-input interface is established.

## Evidence quality and corrections to older notes

The older `display-capture-research.md` records a side-by-side Shaka clear/Widevine test. This pass did not rerun it or locate a retained raw measurement bundle. Treat the figures as a historical repository record. Its own caveat says it does not establish Netflix/Prime behaviour, despite stronger language elsewhere.

Other corrections:

- `preventsCapture` and protected-plane mechanisms do not justify a universal assertion that every lower-level driver sees only black.
- SDK framework presence contradicts “no video equivalent at any privilege level.” VideoDriverKit exists here; no usable display tap was demonstrated.
- I/O Registry class names alone do not prove exactly where all HDCP keys, operations or pixels reside.
- AudioDriverKit is not the reason a Core Audio process tap works; those are distinct interfaces.
- BLE queue cadence does not prove input latency is irrelevant. Input and output latency accumulate.
- Negative searches and API documentation do not prove that all private, patched or future approaches are impossible.

No drivers were installed, security settings changed, browser profiles altered, protected-media keys acquired, or light ownership changed during this investigation.

## Validation needed before calling a solution delivered

| Candidate | Required experiment | Pass condition |
|---|---|---|
| Camera source | Calibrated RGB patches, changing test pattern, dark scenes, real protected playback | Colours track the visible panel; no screen SCStream; acceptable measured error and latency |
| Camera quality | Bright room, reflections, HDR display, high refresh, long run | Stable exposure, no banding/feedback; measured resource cost acceptable |
| All-light integration | BC/55 + Mi + WiZ; power-off, reconnect, source switching | No stale writes, accidental wake, or competing source |
| WiZ HDMI box | Exact source → adapter → box → BenQ chain | Desired video mode and protected playback survive; gradient zones respond |
| WiZ-to-LightStar bridge | Documented interface or traffic from an owned box/light setup | Stable timestamped colours actually reach LightStar; no polling assumption |
| Browser-only input | Clear local video, cross-origin video, public DRM demo, each target service | Explicit coverage table; no inferred service-wide support |
| Custom driver | Working, reviewable proof on exact OS and hardware | Real pixels without delegating to screen capture; protected test separately demonstrated |

Recommendation: build the Camera proof first if keeping all lights inside LightStar is essential. Choose the WiZ HDMI path if direct external-display sync for compatible WiZ lights is sufficient. Retain ScreenCaptureKit for users who prefer desktop software capture. There is no evidence-based reason to begin with a custom driver.
