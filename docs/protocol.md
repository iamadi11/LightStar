# Protocol notes

The BC/55 frame and hue LUT are documented in `agents.md` and implemented in
`crates/lightstar-core`. Reverse-engineering notes from the Swift era:

- `legacy/LightStar/Docs/protocol-confirmed.md`
- `legacy/LightStar/Docs/protocol-research.md`
- `legacy/LightStar/Docs/reverse-engineering.md`

Do not regenerate `ColorMath::HUE_LUT` without a full sweep on the physical strip.
