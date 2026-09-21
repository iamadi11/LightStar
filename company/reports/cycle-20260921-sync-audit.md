# Autonomous company — sync improvement audit

Date: 2026-09-21T20:55Z  
Focus: Screen / Music (audio) / Both (combined) sync

## Conclusion

Evidence-backed sync pass: **EE-010, EE-011, EE-012 implemented**. Follow-ups EE-013/015/016 parked. No invented features.

## Architecture (unchanged product model)

| Mode | Capture | Strip |
|------|---------|-------|
| Screen | SCStream 48×27 → HSV | Hue ≤20 Hz (+ optional brightness) |
| Music | System tap / mic / strip mic | Brightness + optional audio hue ≤30 Hz |
| Both | Video-only screen + standalone system audio | Screen=hue, audio=brightness |

## Shipped this tick

| ID | Area | Change |
|----|------|--------|
| EE-010 | Screen + Both | Serialize sleep/wake: drain stop before start |
| EE-011 | Screen + Both | Frame interval 60→20 Hz (match write throttle) |
| EE-012 | Music/Both (legacy OS) | FFT prepare before display-stream capture |

## Follow-up (not implemented)

- EE-013 mic vs system RMS scale (needs hardware A/B)
- EE-015 Metal CPU fallback edge weights
- EE-016 Combined saturation punch dead API (product call)

## Rejected / do not reopen

EE-003/005/006/007/009; Metal async without Instruments; faster BLE; sync DI rewrite; PD-001 flips.

## Validation

- Company self-tests: run locally
- Swift: Linux cannot compile — requires macos-15 CI (currently billing-blocked) or Mac sleep/wake manual
