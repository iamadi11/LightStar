# BC/55 Protocol — Reverse Engineering Notes

**Source:** Two PacketLogger captures of Miracles Star (com.weifeng.lightbar) on iPhone 17,1 (iOS 26.6),
  paired with GATT--DEMO LED bar. All analysis is done from ATT Write Command traffic only
  (peripheral's NOTIFY traffic not captured but is present on FFF4).

---

## 1. Frame Structure

Every write follows one of two patterns:

```
Pattern A (most commands):
  BC [cmd] [len] [data × len bytes] 55
  ^                                  ^
  start marker                       end marker

Pattern B (BC0F — anomalous, see §3.7):
  BC [cmd] [A] [B] 55
  No length byte — or len=0 with 2 extra bytes
```

**Proof:**

| Cmd | Raw bytes | len field | data bytes | matches? |
|-----|-----------|-----------|-----------|---------|
| BC01 | `BC 01 01 00 55` | 01 | [00] | ✓ |
| BC04 | `BC 04 06 00 00 03 E8 00 00 55` | 06 | 6 bytes | ✓ |
| BC05 | `BC 05 06 03 E8 00 00 00 00 55` | 06 | 6 bytes | ✓ |
| BC06 | `BC 06 02 00 01 55` | 02 | [00, 01] | ✓ |
| BC08 | `BC 08 01 64 55` | 01 | [64] | ✓ |
| BC09 | `BC 09 06 00 A2 03 E8 00 00 55` | 06 | 6 bytes | ✓ |
| BC0B | `BC 0B 07 07 EA 08 17 10 21 2D 55` | 07 | 7 bytes | ✓ |
| BC0C | `BC 0C 01 01 55` | 01 | [01] | ✓ |
| BC0F | `BC 0F 01 01 55` | ? | ? | anomalous |

Write type: **Write Command (withoutResponse)** on GATT handle 0x0003 = FFF3 characteristic.
Confirmed by PacketLogger showing `ATT Send → Write Command` with no corresponding ATT Response.

---

## 2. Device Identity

| Field | Value |
|-------|-------|
| BLE name | `GATT--DEMO` |
| Advertised service | `0x2022` |
| Primary service | `0000FFF0-0000-1000-8000-00805f9b34fb` |
| Write characteristic | `0000FFF3-0000-1000-8000-00805f9b34fb` |
| Notify characteristic | `0000FFF4-0000-1000-8000-00805f9b34fb` |
| GATT write handle | `0x0003` |

---

## 3. Command Catalog

### 3.1 BC04 — Set Hue + Saturation ✅ CONFIRMED

```
BC 04 06 [H_hi] [H_lo] [S_hi] [S_lo] 00 00 55
```

**Field math (big-endian 16-bit):**

```
H = hue in degrees  0–360   e.g. Red=0, Green=120, Blue=240
S = saturation      0–1000  (1000 = 100% saturated)
```

**Raw evidence:**

| Bytes (data field) | H (decoded) | S (decoded) | Color |
|--------------------|------------|------------|-------|
| `00 00 03 E8 00 00` | 0° | 1000 | Red |
| `00 F0 03 E8 00 00` | 240° | 1000 | Blue |
| `00 78 03 E8 00 00` | 120° | 1000 | Green |
| `00 00 00 00 00 00` | 0° | 0 | White (no saturation) |
| `01 05 00 6E 00 00` | 261° | 110 | Blue-ish, low sat |
| `00 F5 00 C4 00 00` | 245° | 196 | Blue, moderate sat |

Trailing `00 00` always zero — purpose unknown (padding, or reserved for future channels).

**Confirmed:** ≥200 unique H+S combinations captured across two sessions of full color-wheel dragging.

---

### 3.2 BC05 — Set Brightness ✅ CONFIRMED

```
BC 05 06 [B_hi] [B_lo] 00 00 00 00 55
```

**Field math (big-endian 16-bit):**

```
B = brightness  100–1000  (minimum 100 = ~10%, maximum 1000 = 100%)
```

**Raw evidence (subset):**

```
BC 05 06 03 E8 00 00 00 00 55  →  B=1000 (max, 0x03E8)
BC 05 06 03 C3 00 00 00 00 55  →  B=963
BC 05 06 00 64 00 00 00 00 55  →  B=100  (min observed, 0x0064)
```

User dragged slider full range: 1000 → 100 (held) → 1000. Min 100 is confirmed floor.
Minimum in capture is 0x0064=100. Whether B=0 (power off via brightness) is untested.
Trailing `00 00 00 00` always zero.

---

### 3.3 BC06 — Select Effect ✅ CONFIRMED

```
BC 06 02 00 [effect_id] 55
```

**Raw evidence:**

| Bytes | effect_id | Miracles Star UI tap |
|-------|-----------|---------------------|
| `BC 06 02 00 01 55` | 0x01 = 1 | First effect button |
| `BC 06 02 00 03 55` | 0x03 = 3 | Second effect button |
| `BC 06 02 00 35 55` | 0x35 = 53 | Third effect button |

Byte at position 3 is always `00` (reserved). Effect IDs are not contiguous — gaps likely exist
for other effect IDs not captured. The full ID table cannot be derived without a controlled
capture where each effect button is tapped while watching the log.

---

### 3.4 BC08 — Effect Speed ✅ CONFIRMED

```
BC 08 01 [speed] 55
```

**Field math (single byte):**

```
speed = 0–100 decimal  (0x00 = slowest, 0x64 = fastest)
```

**Raw evidence:**

| Bytes | speed |
|-------|-------|
| `BC 08 01 64 55` | 100 (max) |
| `BC 08 01 00 55` | 0 (min) |
| `BC 08 01 1D 55` | 29 |
| `BC 08 01 41 55` | 65 |
| `BC 08 01 59 55` | 89 |
| `BC 08 01 4D 55` | 77 |

User moved slider from max → min → random positions. Range 0–100 confirmed.

---

### 3.5 BC0B — Set Real-Time Clock ✅ CRACKED

```
BC 0B 07 [Y_hi] [Y_lo] [month] [day] [hour] [minute] [second] 55
```

**Proof — exact timestamp match:**

Raw capture: `BC 0B 07 07 EA 08 17 10 21 2D 55`

```
07 EA → year   = 0x07EA = 2026
08    → month  = 8 (August)
17    → day    = 0x17 = 23
10    → hour   = 0x10 = 16 (4 PM)
21    → minute = 0x21 = 33
2D    → second = 0x2D = 45
```

Decoded: **2026-08-23 16:33:45**
PacketLogger capture timestamp for this packet: **16:33:45** ← exact match.

Sent exactly twice (back-to-back) at 16:33:45, immediately following BC0C 0101 55.
This is the device's internal clock sync, likely triggered when the user opens a
"Schedule" or "Timer" feature in the Miracles Star app.

---

### 3.6 BC0C — Schedule Confirm 🔵 INFERRED

```
BC 0C 01 01 55
```

Always sent immediately before BC0B (RTC sync). Sent twice per session. Data byte is always `01`.
**Hypothesis:** "Write schedule / confirm settings." Could also be "Enable schedule mode."
Needs a controlled capture: tap the Schedule toggle ON vs OFF and observe BC0C.

---

### 3.7 BC0F — Unknown Toggle 🟡 PARTIAL

```
BC 0F [A] 01 55
```

Two forms seen:

| Bytes | A |
|-------|---|
| `BC 0F 01 01 55` | 01 (enable?) |
| `BC 0F 00 01 55` | 00 (disable?) |

Sent as a pair (01 then 00) with ~1 second between them, mid-session during BC09 color wheel
dragging. The trailing `01` before `55` is constant.

**Framing anomaly:** BC 0F 00 01 55 — if len=00 then data length is 0 bytes, making `01` a
spurious byte before the terminator. Either: (a) BC0F uses a non-standard 2-byte payload with
no length field, or (b) the trailing 01 is a "version" or "confirm" byte appended after the
standard frame.

**Hypothesis candidates:**
- Music-sync toggle (enable mic → disable after ~1s debounce)
- "Live color preview" mode on/off
- Some internal feature lock/unlock

---

### 3.8 BC09 — Secondary Color Control 🟡 PARTIAL

```
BC 09 06 [V_hi] [V_lo] 03 E8 00 00 55
```

**Field analysis:**

| Field | Bytes | Observed values |
|-------|-------|----------------|
| V | bytes 3–4 (big-endian) | 19–246 (0x0013–0x00F6) |
| constant | bytes 5–6 | always 0x03E8 = 1000 |
| constant | bytes 7–8 | always 0x0000 |

Appears in bursts of 50–150 consecutive commands while the user drags (distinct from BC04 dragging).
BC04 is sent when dragging the main 2D color wheel (both H and S vary).
BC09 appears in a DIFFERENT drag context where only the first field varies and saturation is locked at 1000.

**Hypothesis:** Hue-only strip or "spectrum" selector (separate from the 2D color wheel).
V range 19–246 ≈ scaled hue 0–255 (8-bit hue system), with S hard-coded at maximum.
If confirmed: hue_degrees = V / 255 × 360.

**Alternative hypothesis:** Color temperature control (warm-to-cool white), where V encodes temperature and the constant 1000 is brightness.

**Probe to confirm:** Isolate this drag control in the app, note which UI element triggers BC09
vs BC04. Log with ONLY one very specific tap or drag action.

---

### 3.9 BC01 — Power ON/OFF ✅ CONFIRMED

```
BC 01 01 [state] 55
```

**Confirmed by physical test:**
- `BC 01 01 01 55` (state=0x01) = **Power ON**
- `BC 01 01 00 55` (state=0x00) = **Power OFF**

Miracles Star sends `00` then `01` on every connect = power-cycle reset (OFF → ON).
This initializes the device into a known state before sending color commands.

---

## 4. Session Sequence Patterns

### Solid Color Workflow

```
BC01 0100 55       ← session init (or mode switch)
BC01 0101 55       ← always follows init
BC04 [H+S]         ← set hue + saturation
BC05 [B]           ← set brightness
(BC04/BC05 repeat while slider dragging)
```

### Effect Workflow

```
BC01 0100 55       ← transition signal
BC01 0101 55       ← transition signal
BC06 00 [id] 55    ← select effect
BC08 [speed] 55    ← set speed
```

### Schedule / Clock Sync Workflow

```
BC0C 01 55         ← enter schedule mode
BC0B [Y_hi Y_lo M D h m s] 55  ← sync RTC
BC0C 01 55         ← confirm
```

---

## 5. What Is Still Unknown

| Question | What to do |
|----------|-----------|
| Full effect ID table (only 0x01, 0x03, 0x35 seen) | Capture each effect button tap individually |
| BC01 true semantics (mode vs power) | Controlled power toggle test (see §3.9) |
| BC09 control identity (which UI element) | Isolate in app, use only that control |
| BC0F purpose | Toggle whatever feature BC0F controls ON then OFF with single tap |
| Whether B=0 in BC05 powers off | Send `BC05 06 00 00 00 00 00 00 55` and observe |
| Notify data on FFF4 | Capture peripheral → central direction; understand device state replies |

---

## 6. Not Observed / Not Needed

- No checksum — frame is `BC [cmd] [len] [data] 55`, no trailing CRC or XOR.
- No RGB encoding — pure HSV. The device does HSV→RGB conversion internally.
- No RGBW white channel separate command observed (BC09 second field constant, not a W channel).
- No Brightness-in-BC04 — brightness is always a separate BC05 command.
