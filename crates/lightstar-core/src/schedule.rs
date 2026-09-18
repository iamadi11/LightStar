use chrono::{DateTime, Datelike, Duration, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use uuid::Uuid;

/// Scene saved by the user. New fields must be `Option` so legacy JSON still decodes.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Preset {
    #[serde(default)]
    pub id: Uuid,
    pub name: String,
    pub red: f64,
    pub green: f64,
    pub blue: f64,
    pub brightness: f64,
}

impl Preset {
    pub fn defaults() -> Vec<Self> {
        vec![
            Preset {
                id: Uuid::new_v4(),
                name: "Reading".into(),
                red: 1.0,
                green: 0.95,
                blue: 0.8,
                brightness: 1.0,
            },
            Preset {
                id: Uuid::new_v4(),
                name: "Movie".into(),
                red: 0.1,
                green: 0.0,
                blue: 0.3,
                brightness: 0.3,
            },
            Preset {
                id: Uuid::new_v4(),
                name: "Party".into(),
                red: 1.0,
                green: 0.0,
                blue: 0.5,
                brightness: 1.0,
            },
            Preset {
                id: Uuid::new_v4(),
                name: "Relax".into(),
                red: 0.8,
                green: 0.4,
                blue: 0.1,
                brightness: 0.5,
            },
        ]
    }

    pub fn hsv(&self) -> (f64, f64, f64) {
        crate::color::ColorMath::rgb_to_hsv(self.red, self.green, self.blue)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", tag = "type")]
pub enum ScheduledAction {
    PowerOn,
    PowerOff,
    Preset {
        color_hue: f64,
        color_sat: f64,
        brightness: f64,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Schedule {
    #[serde(default)]
    pub id: Uuid,
    pub label: String,
    /// Hour 0–23 in the user's local timezone. Stored separately so JSON is stable.
    pub hour: u32,
    pub minute: u32,
    /// 1=Sun … 7=Sat (Foundation Calendar weekday).
    pub days: BTreeSet<u32>,
    #[serde(default = "default_true")]
    pub is_enabled: bool,
    pub action: ScheduledAction,
    /// Optional so existing JSON still decodes. New schedules set this to now
    /// so a catch-up window cannot fire for a time that passed before creation.
    #[serde(default)]
    pub last_fired_at: Option<DateTime<Utc>>,
    /// When true, also push this schedule as a BC0D firmware timer.
    #[serde(default)]
    pub use_firmware_timer: bool,
}

fn default_true() -> bool {
    true
}

impl Schedule {
    pub fn firmware_timer_enabled(&self) -> bool {
        self.use_firmware_timer
    }

    /// OEM bitmask: bit0=Mon … bit6=Sun. Calendar weekday 1=Sun … 7=Sat.
    pub fn oem_day_mask(days: &BTreeSet<u32>) -> u8 {
        let mut mask = 0u8;
        for weekday in days {
            mask |= 1u8 << ((*weekday + 5) % 7);
        }
        mask
    }

    pub fn previous_fire_date<Tz: TimeZone>(&self, now: DateTime<Tz>) -> Option<DateTime<Tz>>
    where
        Tz::Offset: Copy,
    {
        if self.days.is_empty() {
            return None;
        }
        for offset in 0..8 {
            let day = now.clone() - Duration::days(offset);
            let weekday = day.weekday().number_from_sunday();
            if !self.days.contains(&weekday) {
                continue;
            }
            let candidate = day
                .date_naive()
                .and_hms_opt(self.hour, self.minute, 0)?
                .and_local_timezone(now.timezone())
                .single()?;
            if candidate <= now {
                return Some(candidate);
            }
        }
        None
    }

    pub fn next_fire_date<Tz: TimeZone>(&self, now: DateTime<Tz>) -> Option<DateTime<Tz>>
    where
        Tz::Offset: Copy,
    {
        if !self.is_enabled || self.days.is_empty() {
            return None;
        }
        for offset in 0..8 {
            let day = now.clone() + Duration::days(offset);
            let weekday = day.weekday().number_from_sunday();
            if !self.days.contains(&weekday) {
                continue;
            }
            let candidate = day
                .date_naive()
                .and_hms_opt(self.hour, self.minute, 0)?
                .and_local_timezone(now.timezone())
                .single()?;
            if candidate > now {
                return Some(candidate);
            }
        }
        None
    }

    /// Due if the last scheduled instant is within `catch_up` seconds of `now`
    /// and we have not already fired for that instant. `last_fired_at == None`
    /// is treated as not due.
    pub fn is_due<Tz: TimeZone>(&self, now: DateTime<Tz>, catch_up_secs: i64) -> bool
    where
        Tz::Offset: Copy,
    {
        if !self.is_enabled {
            return false;
        }
        let Some(last_fired) = self.last_fired_at else {
            return false;
        };
        let Some(scheduled) = self.previous_fire_date(now.clone()) else {
            return false;
        };
        let scheduled_utc = scheduled.with_timezone(&Utc);
        if now.with_timezone(&Utc) - scheduled_utc > Duration::seconds(catch_up_secs) {
            return false;
        }
        last_fired < scheduled_utc
    }
}

pub const PENDING_CAP: usize = 8;
