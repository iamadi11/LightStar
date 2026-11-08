# Chrome direct-video pixel test

Run on 7 November 2026 (India time), Apple M3, macOS 26.5.1 (25F80), installed Google Chrome 157.0.8103.38. Public Shaka Player demo v5.3.4-uncompiled. This is an actual browser experiment, not a source-only feasibility assessment.

## Result

Direct JavaScript access successfully reads clear video. The playing Widevine version returns solid black through canvas and rejects `new VideoFrame(video)`. Disabling GPU acceleration does not restore either path.

| Configuration | Clear video, 48×27 canvas | Widevine video, same canvas | `VideoFrame` |
|---|---|---|---|
| Default graphics settings, hardware acceleration verified | Changing RGB, mean channel value 42.27–60.30 | All RGB values exactly zero | Clear succeeds; Widevine `InvalidStateError` |
| `--disable-gpu`, software graphics verified | Changing RGB, mean channel value 24.19–27.54 | All RGB values exactly zero | Clear succeeds; Widevine `InvalidStateError` |

Mean values are on the 0–255 RGB scale. The two runs sampled different times and adaptive resolutions; these figures demonstrate readable versus zero pixels, not colour fidelity or performance equivalence.

## Method and controls

1. Used the installed Chrome executable with a new temporary profile and local DevTools port. The normal user profile was not used or modified.
2. Loaded the public [Shaka demo](https://shaka-project.github.io/shaka-player-release/demo/).
3. Checked normal EME playback support with `requestMediaKeySystemAccess("com.widevine.alpha", ...)`: supported in installed Chrome. An earlier CLI-managed browser did not support Widevine; its capability result was excluded from the pixel experiment.
4. Created two muted, visible HTML video elements with independent Shaka players, starting at t=12 seconds:
   - `https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd`
   - `https://storage.googleapis.com/shaka-demo-assets/angel-one-widevine/dash.mpd`
5. Used normal EME playback and the public test license endpoint `https://cwip-shaka-proxy.appspot.com/no_auth`. No license interception, key extraction, CDM replacement, or protection patch was used.
6. Drew each HTML video to a fresh 48×27 canvas and read `getImageData`. Also attempted `new VideoFrame(video)` and immediately closed successful frames.
7. Recorded player time, readiness, media-key presence, key system and decoded-frame counts alongside numeric pixel statistics. Repeated measurements over changing frames.
8. Repeated in a second temporary installed-Chrome profile with `--disable-gpu`. Verified `chrome://gpu` status for both runs: default canvas/compositing/video decode hardware accelerated; second run software-only with hardware acceleration disabled.

The Widevine player had `readyState = 4`, `paused = false`, attached media keys, key system `com.widevine.alpha`, no recorded player errors, and increasing decoded-frame counts. During the default run those counts increased from 23 to 308; the software run recorded 93 to 134. All retained protected samples contained 1,296 opaque black pixels. This distinguishes the result from trying to read an unloaded video or receiving transparent canvas pixels.

The default clear run's first sample was taken before decoded frames were available; it remains in raw data for completeness and is excluded from the result table. Five subsequent decoded clear samples returned nonzero, changing colours. Five decoded clear samples succeeded in the software run as well.

No screen-capture API was invoked by this probe: no ScreenCaptureKit, desktop screenshot, `getDisplayMedia`, or browser tab-capture stream. Other applications on the Mac were not shut down or instrumented. This experiment therefore does not certify that no unrelated capture session existed elsewhere.

## Artifacts

- Probe source: [browser-pixel-probe.js](../../scripts/mac-validation/browser-pixel-probe.js)
- Default raw numeric results: [JSON](browser-pixel-probe-2026-11-07-default.json)
- Software-rendering raw results: [JSON](browser-pixel-probe-2026-11-07-software.json)
- Default graphics status and version: [text](browser-pixel-probe-2026-11-07-default-gpu.txt)
- Software graphics status and version: [text](browser-pixel-probe-2026-11-07-software-gpu.txt)

To repeat: open the public demo in installed Chrome, evaluate the probe source, then call `lightstarPixelProbe.sample()` after playback starts. Call `lightstarPixelProbe.export()` to collect the record. Reload before a fresh run. The probe creates no light connection and does not change LightStar behaviour.

## Interpretation and limits

- A browser-source implementation for **readable** video is feasible at the acquisition stage. Transport to LightStar and actual lamp output were not implemented or tested here.
- A straightforward canvas/VideoFrame extension is **not a verified replacement for protected-video sync**: it fails on this public Widevine test in both graphics configurations.
- This is consistent with the [EME media-element restrictions](https://www.w3.org/TR/encrypted-media/#media-element-restrictions), which allow CDM-processed data to be withheld from ordinary media-processing APIs.
- Netflix, Prime, and YouTube were not tested directly. Do not label them tested or infer universal failure/success across all services from this asset. A normal extension should not be presented as a Netflix/Prime fix based on these results.
- The two API failures do not prove every imaginable browser modification, internal native hook, or private API impossible. Those would be different research projects.
- Disabling GPU acceleration can affect **desktop capturability**, while direct media-element pixel access remains blocked. The existing screen-capture workaround and this experiment exercise different access paths.
- Timing fields include warmup and scheduling effects; this was not a performance benchmark.

Both temporary installed-Chrome instances and the CLI-managed browser session were closed after the results were saved. No production input source was added.
