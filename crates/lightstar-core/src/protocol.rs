//! BC/55 command encoder. Confirmed via APK reverse-engineering 2026-08-26.
//! Frame: `BC [cmd] [data_len] [data × data_len] 55`
//! GATT: advertised 0x2022, service FFF0, write FFF3 (with response), notify FFF4.

use crate::color::ColorMath;
use serde::{Deserialize, Serialize};

pub const ADVERTISED_UUID: &str = "00002022-0000-1000-8000-00805f9b34fb";
pub const SERVICE_UUID: &str = "0000fff0-0000-1000-8000-00805f9b34fb";
pub const WRITE_UUID: &str = "0000fff3-0000-1000-8000-00805f9b34fb";
pub const NOTIFY_UUID: &str = "0000fff4-0000-1000-8000-00805f9b34fb";

pub struct Cmd;

impl Cmd {
    pub const POWER_ON: [u8; 5] = [0xBC, 0x01, 0x01, 0x01, 0x55];
    pub const POWER_OFF: [u8; 5] = [0xBC, 0x01, 0x01, 0x00, 0x55];

    pub fn power_on() -> [u8; 5] {
        Self::POWER_ON
    }
    pub fn power_off() -> [u8; 5] {
        Self::POWER_OFF
    }

    /// Static colour. `h` is 0–1 hue; `s` is 0–1 saturation.
    pub fn hue(h: f64, s: f64) -> Vec<u8> {
        encode_hs(0x04, h, s)
    }

    /// Streaming colour (audio-reactive). Same encoding as BC04, cmd 0x09.
    pub fn audio_hue(h: f64, s: f64) -> Vec<u8> {
        encode_hs(0x09, h, s)
    }

    /// Brightness 0–1 mapped to 100–1000.
    pub fn brightness(value: f64) -> Vec<u8> {
        let b = clamp_u16(100.0 + value * 900.0, 100, 1000);
        vec![
            0xBC,
            0x05,
            0x06,
            (b >> 8) as u8,
            (b & 0xFF) as u8,
            0x00,
            0x00,
            0x00,
            0x00,
            0x55,
        ]
    }

    pub fn effect(id: u8) -> Vec<u8> {
        vec![0xBC, 0x06, 0x02, 0x00, id, 0x55]
    }

    pub fn effect_direction(forward: bool) -> Vec<u8> {
        vec![0xBC, 0x07, 0x01, if forward { 0x01 } else { 0x00 }, 0x55]
    }

    /// Effect speed 0–1 mapped to 0–255 (truncates toward zero, matching Swift `Int()`).
    pub fn speed(value: f64) -> Vec<u8> {
        let s = clamp_u16(value * 255.0, 0, 255) as u8;
        vec![0xBC, 0x08, 0x01, s, 0x55]
    }

    pub fn strip_mic(enabled: bool) -> Vec<u8> {
        vec![0xBC, 0x0F, 0x01, if enabled { 0x01 } else { 0x00 }, 0x55]
    }

    /// 1=Classic, 2=Soft, 3=Dynamic, 4=Disco.
    pub fn mic_style(style: u8) -> Vec<u8> {
        vec![0xBC, 0x11, 0x01, style, 0x55]
    }

    pub fn mic_sensitivity(value: i32) -> Vec<u8> {
        let v = value.clamp(0, 255) as u8;
        vec![0xBC, 0x12, 0x01, v, 0x55]
    }

    /// Channel order 1=RGB … 6=BGR.
    pub fn channel_order(order: u8) -> Vec<u8> {
        vec![0xBC, 0x02, 0x01, order, 0x55]
    }

    /// Pixel count 16-bit BE, 8–300.
    pub fn pixel_count(count: i32) -> Vec<u8> {
        let n = (count.clamp(8, 300) as u16).to_be_bytes();
        vec![0xBC, 0x03, 0x02, n[0], n[1], 0x55]
    }

    /// Time sync: yr-2000, mo, day, hr, min, sec, weekday bitmask (bit0=Mon).
    pub fn time_sync(
        year: u8,
        month: u8,
        day: u8,
        hour: u8,
        minute: u8,
        second: u8,
        weekday_mask: u8,
    ) -> Vec<u8> {
        vec![
            0xBC,
            0x0B,
            0x07,
            year,
            month,
            day,
            hour,
            minute,
            second,
            weekday_mask,
            0x55,
        ]
    }

    /// Weekly firmware timer. Slot is the leading 0x01 seen in the APK capture.
    pub fn weekly_timer(
        slot: u8,
        power_on: bool,
        enabled: bool,
        day_mask: u8,
        hour: u8,
        minute: u8,
    ) -> Vec<u8> {
        vec![
            0xBC,
            0x0D,
            0x06,
            slot,
            if power_on { 0x01 } else { 0x00 },
            if enabled { 0x01 } else { 0x00 },
            day_mask,
            hour,
            minute,
            0x55,
        ]
    }

    pub fn animation(id: u8) -> Vec<u8> {
        vec![0xBC, 0x13, 0x01, id, 0x55]
    }
}

fn encode_hs(cmd: u8, h: f64, s: f64) -> Vec<u8> {
    let hue_deg = ColorMath::corrected_hue_deg(h);
    // Swift `Int(x.rounded())` — nearest, ties away from zero via f64::round.
    let h16 = clamp_u16(hue_deg.round(), 0, 360);
    let s16 = clamp_u16((s * 1000.0).round(), 0, 1000);
    vec![
        0xBC,
        cmd,
        0x06,
        (h16 >> 8) as u8,
        (h16 & 0xFF) as u8,
        (s16 >> 8) as u8,
        (s16 & 0xFF) as u8,
        0x00,
        0x00,
        0x55,
    ]
}

fn clamp_u16(v: f64, lo: u16, hi: u16) -> u16 {
    // Match Swift Int(Double) then clamp.
    let truncated = if v.is_nan() { 0 } else { v.trunc() as i64 };
    truncated.clamp(lo as i64, hi as i64) as u16
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Effect {
    pub name: String,
    pub id: u8,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum EffectGroup {
    Loop,
    Flutter,
    Brush,
    OpenClose,
    Transition,
    Water,
    Tailing,
    Running,
}

impl EffectGroup {
    pub fn label(self) -> &'static str {
        match self {
            Self::Loop => "Loop",
            Self::Flutter => "Fluttering",
            Self::Brush => "Brushing",
            Self::OpenClose => "Opening / Closing",
            Self::Transition => "Transition",
            Self::Water => "Flowing Water",
            Self::Tailing => "Tailing",
            Self::Running => "Running",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EffectSection {
    pub group: EffectGroup,
    pub label: String,
    pub effects: Vec<Effect>,
}

pub fn known_effects() -> Vec<EffectSection> {
    fn e(name: &str, id: u8) -> Effect {
        Effect {
            name: name.to_string(),
            id,
        }
    }
    fn sec(group: EffectGroup, effects: Vec<Effect>) -> EffectSection {
        EffectSection {
            label: group.label().to_string(),
            group,
            effects,
        }
    }
    vec![
        sec(
            EffectGroup::Loop,
            vec![
                e("Auto Loop", 0x01),
                e("Symphony", 0x02),
                e("Colorful Energy", 0x03),
                e("Colorful Jumps", 0x04),
                e("7 Colors Strobe", 0x07),
                e("7 Colors Gradient", 0x0A),
            ],
        ),
        sec(
            EffectGroup::Flutter,
            vec![e("Colorful", 0x1A), e("Red-Green-Blue", 0x1B)],
        ),
        sec(
            EffectGroup::Brush,
            vec![
                e("Colorful", 0x1D),
                e("Red-Green-Blue", 0x1E),
                e("Yellow-Cyan-Purple", 0x1F),
                e("Colorful Pull", 0x20),
            ],
        ),
        sec(
            EffectGroup::OpenClose,
            vec![
                e("7 Colors", 0x23),
                e("Red-Green-Blue", 0x24),
                e("Yellow-Cyan-Purple", 0x25),
                e("Red", 0x26),
                e("Green", 0x27),
                e("Blue", 0x28),
                e("Yellow", 0x29),
                e("Cyan", 0x2A),
                e("Purple", 0x2B),
                e("White", 0x2C),
            ],
        ),
        sec(
            EffectGroup::Transition,
            vec![
                e("7 Colors", 0x2D),
                e("Blue-Red-Green", 0x2E),
                e("Violet-Green-Yellow", 0x2F),
                e("Red", 0x30),
                e("Green", 0x31),
                e("Blue", 0x32),
                e("Cyan", 0x33),
                e("Yellow", 0x34),
                e("Purple", 0x35),
                e("White", 0x36),
            ],
        ),
        sec(
            EffectGroup::Water,
            vec![
                e("7 Colors", 0x37),
                e("Blue-Green-Red", 0x38),
                e("Purple-Green-Yellow", 0x39),
                e("Red-Green", 0x3A),
                e("Green-Blue", 0x3B),
                e("Yellow-Blue", 0x3C),
                e("Yellow-Cyan", 0x3D),
                e("Blue-Purple", 0x3E),
            ],
        ),
        sec(
            EffectGroup::Tailing,
            vec![
                e("7 Colors", 0x4C),
                e("Red", 0x4D),
                e("Green", 0x4E),
                e("Blue", 0x4F),
                e("Yellow", 0x50),
                e("Cyan", 0x51),
                e("Purple", 0x52),
                e("White", 0x53),
            ],
        ),
        sec(
            EffectGroup::Running,
            vec![
                e("Red", 0x54),
                e("Green", 0x55),
                e("Blue", 0x56),
                e("Yellow", 0x57),
                e("Cyan", 0x58),
                e("Purple", 0x59),
                e("White", 0x5A),
                e("7 Colors", 0x5B),
                e("Blue-Green-Red", 0x5C),
                e("Purple-Cyan-Yellow", 0x5D),
            ],
        ),
    ]
}

/// Valid BC13 animation IDs: 0x00–0xFF minus 0x3D / 0x5B / 0x96.
pub fn animation_ids() -> Vec<u8> {
    (0u8..=255u8)
        .filter(|v| !matches!(v, 0x3D | 0x5B | 0x96))
        .collect()
}
