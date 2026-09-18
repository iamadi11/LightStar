//! Shared LightStar protocol and domain types — no BLE, no UI.
//!
//! Frame invariant: `BC [cmd] [data_len] [data × data_len] 55` with
//! `bytes[2] == bytes.len() - 4`.

pub mod coalescer;
pub mod color;
pub mod protocol;
pub mod schedule;

pub use coalescer::WriteCoalescer;
pub use color::ColorMath;
pub use protocol::{known_effects, Cmd, Effect, EffectGroup};
pub use schedule::{ScheduledAction, Schedule};

pub fn assert_frame(bytes: &[u8]) -> Result<(), String> {
    if bytes.is_empty() {
        return Err("empty frame".into());
    }
    if bytes[0] != 0xBC {
        return Err(format!("expected leading 0xBC, got {:02X}", bytes[0]));
    }
    if *bytes.last().unwrap() != 0x55 {
        return Err(format!("expected trailing 0x55, got {:02X}", bytes.last().unwrap()));
    }
    if bytes.len() < 4 {
        return Err("frame shorter than 4 bytes".into());
    }
    let data_len = bytes[2] as usize;
    if data_len != bytes.len() - 4 {
        return Err(format!(
            "data_len {} != payload {}",
            data_len,
            bytes.len() - 4
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{TimeZone, Utc};

    fn assert_ok(bytes: &[u8]) {
        assert_frame(bytes).unwrap_or_else(|e| panic!("{e}: {bytes:02X?}"));
    }

    #[test]
    fn all_frames() {
        let frames: Vec<Vec<u8>> = vec![
            Cmd::power_on().to_vec(),
            Cmd::power_off().to_vec(),
            Cmd::channel_order(1),
            Cmd::pixel_count(30),
            Cmd::hue(0.5, 1.0),
            Cmd::brightness(1.0),
            Cmd::effect(0x01),
            Cmd::effect_direction(true),
            Cmd::speed(0.5),
            Cmd::audio_hue(0.2, 0.8),
            Cmd::time_sync(26, 9, 18, 8, 0, 0, 0x01),
            Cmd::weekly_timer(1, false, true, 0x1F, 23, 30),
            Cmd::strip_mic(true),
            Cmd::mic_style(2),
            Cmd::mic_sensitivity(128),
            Cmd::animation(0x10),
        ];
        for f in frames {
            assert_ok(&f);
        }
    }

    #[test]
    fn hue_half_is_lut_corrected() {
        // h=0.5 → 180° → LUT (173,130)–(188,140) → 134.66 → trunc 134 = 0x0086
        let f = Cmd::hue(0.5, 1.0);
        assert_eq!(f, vec![0xBC, 0x04, 0x06, 0x00, 0x86, 0x03, 0xE8, 0x00, 0x00, 0x55]);
    }

    #[test]
    fn brightness_full_is_1000() {
        let f = Cmd::brightness(1.0);
        assert_eq!(f, vec![0xBC, 0x05, 0x06, 0x03, 0xE8, 0x00, 0x00, 0x00, 0x00, 0x55]);
    }

    #[test]
    fn hue_lut_is_monotonic_non_decreasing() {
        let mut last = -1.0;
        for (obs, _) in ColorMath::HUE_LUT {
            assert!(*obs >= last, "obs {obs} < previous {last}");
            last = *obs;
        }
    }

    #[test]
    fn purple_magenta_recalibration_region() {
        let sent = ColorMath::corrected_hue_deg(330.0 / 360.0);
        assert!(sent > 350.0, "sent {sent}");
        assert!(sent <= 360.0);
    }

    #[test]
    fn circadian_night_is_warm() {
        let date = Utc.with_ymd_and_hms(2026, 1, 1, 2, 0, 0).unwrap();
        assert_eq!(ColorMath::circadian_cct_value(date), 0.0);
    }

    #[test]
    fn kelvin_neutral_is_low_saturation() {
        let (_, s) = ColorMath::kelvin_to_hs(4000.0);
        assert!(s < 0.25, "sat {s}");
    }

    fn monday_0805() -> chrono::DateTime<chrono::Utc> {
        Utc.with_ymd_and_hms(2026, 1, 5, 8, 5, 0).unwrap()
    }

    fn eight_am_on(day: chrono::DateTime<chrono::Utc>) -> chrono::DateTime<chrono::Utc> {
        day.date_naive()
            .and_hms_opt(8, 0, 0)
            .unwrap()
            .and_utc()
    }

    #[test]
    fn created_after_due_time_does_not_fire() {
        let now = monday_0805();
        let schedule = Schedule {
            id: uuid::Uuid::nil(),
            label: "Morning".into(),
            hour: 8,
            minute: 0,
            days: [2, 3, 4, 5, 6].into_iter().collect(),
            is_enabled: true,
            action: ScheduledAction::PowerOn,
            last_fired_at: Some(now),
            use_firmware_timer: false,
        };
        assert!(!schedule.is_due(now, 15 * 60));
    }

    #[test]
    fn nil_last_fired_at_is_never_due() {
        let now = monday_0805();
        let schedule = Schedule {
            id: uuid::Uuid::nil(),
            label: "Morning".into(),
            hour: 8,
            minute: 0,
            days: [2].into_iter().collect(),
            is_enabled: true,
            action: ScheduledAction::PowerOn,
            last_fired_at: None,
            use_firmware_timer: false,
        };
        assert!(!schedule.is_due(now, 15 * 60));
    }

    #[test]
    fn catch_up_fires_when_last_fired_before_scheduled_instant() {
        let now = monday_0805();
        let scheduled = eight_am_on(now);
        let schedule = Schedule {
            id: uuid::Uuid::nil(),
            label: "Morning".into(),
            hour: 8,
            minute: 0,
            days: [2].into_iter().collect(),
            is_enabled: true,
            action: ScheduledAction::PowerOn,
            last_fired_at: Some(scheduled - chrono::Duration::seconds(3600)),
            use_firmware_timer: false,
        };
        assert!(schedule.is_due(now, 15 * 60));
    }

    #[test]
    fn next_fire_is_in_the_future() {
        let now = monday_0805();
        let schedule = Schedule {
            id: uuid::Uuid::nil(),
            label: "Morning".into(),
            hour: 8,
            minute: 0,
            days: [2].into_iter().collect(),
            is_enabled: true,
            action: ScheduledAction::PowerOff,
            last_fired_at: Some(now),
            use_firmware_timer: false,
        };
        let next = schedule.next_fire_date(now).expect("next");
        assert!(next > now);
    }

    #[test]
    fn coalescer_replace_in_place_preserves_insertion_order() {
        let mut c = WriteCoalescer::new();
        c.enqueue(&Cmd::power_on());
        c.enqueue(&Cmd::hue(0.0, 1.0));
        c.enqueue(&Cmd::brightness(1.0));
        c.enqueue(&Cmd::power_off()); // cmd 0x01 replaces power_on in place
        let drained = c.drain();
        assert_eq!(drained.len(), 3);
        assert_eq!(drained[0], Cmd::power_off());
        assert_eq!(drained[1][1], 0x04);
        assert_eq!(drained[2][1], 0x05);
    }

    #[test]
    fn firmware_day_mask_monday_is_bit0() {
        // Calendar weekday 2 = Monday → bit 0.
        assert_eq!(Schedule::oem_day_mask(&[2].into_iter().collect()), 0x01);
        // Sunday = Calendar 1 → bit 6.
        assert_eq!(Schedule::oem_day_mask(&[1].into_iter().collect()), 0x40);
        // Weekdays Mon–Fri = bits 0–4.
        assert_eq!(
            Schedule::oem_day_mask(&[2, 3, 4, 5, 6].into_iter().collect()),
            0x1F
        );
    }

    #[test]
    fn known_effects_cover_ha_table() {
        let ids: Vec<u8> = known_effects()
            .into_iter()
            .flat_map(|g| g.effects.into_iter().map(|e| e.id))
            .collect();
        assert!(ids.contains(&0x01));
        assert!(ids.contains(&0x5D));
        assert_eq!(ids.len(), 58);
    }

    #[test]
    fn legacy_preset_json_decodes() {
        let json = r#"[{"id":"00000000-0000-0000-0000-000000000001","name":"Reading","red":1,"green":0.95,"blue":0.8,"brightness":1}]"#;
        let presets: Vec<crate::schedule::Preset> = serde_json::from_str(json).unwrap();
        assert_eq!(presets.len(), 1);
        assert_eq!(presets[0].name, "Reading");
    }
}
