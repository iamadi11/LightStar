use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

use lightstar_core::protocol::known_effects;
use lightstar_core::schedule::{Preset, Schedule};
use lightstar_core::protocol::EffectSection;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum ConnectionState {
    #[default]
    Disconnected,
    Scanning,
    Connecting,
    Connected,
}

impl ConnectionState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Disconnected => "disconnected",
            Self::Scanning => "scanning",
            Self::Connecting => "connecting",
            Self::Connected => "connected",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "kebab-case")]
pub enum SyncMode {
    #[default]
    Off,
    Video,
    Audio,
    Combined,
}

impl SyncMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Video => "video",
            Self::Audio => "audio",
            Self::Combined => "combined",
        }
    }

    pub fn is_video(self) -> bool {
        matches!(self, Self::Video | Self::Combined)
    }

    pub fn is_audio(self) -> bool {
        matches!(self, Self::Audio | Self::Combined)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum AudioSyncMode {
    #[default]
    Rainbow,
    Pulse,
    Frequency,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AudioInputSource {
    Microphone,
    StripMic,
}

impl Default for AudioInputSource {
    fn default() -> Self {
        Self::Microphone
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DisplayInfo {
    pub id: u32,
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Persisted {
    #[serde(default)]
    pub is_on: bool,
    #[serde(default)]
    pub hue: f64,
    #[serde(default = "one")]
    pub sat: f64,
    #[serde(default = "one")]
    pub brightness: f64,
    #[serde(default = "default_true")]
    pub auto_connect: bool,
    #[serde(default)]
    pub circadian_enabled: bool,
    #[serde(default)]
    pub audio_input_source: AudioInputSource,
    #[serde(default = "half")]
    pub mic_sensitivity: f64,
    #[serde(default = "one_u8")]
    pub led_channel_order: u8,
    #[serde(default = "thirty")]
    pub led_pixel_count: u16,
    #[serde(default = "resp")]
    pub sync_responsiveness: f64,
    #[serde(default = "half")]
    pub beat_sensitivity: f64,
    #[serde(default)]
    pub video_sync_brightness: bool,
    #[serde(default)]
    pub multi_light_enabled: bool,
    #[serde(default)]
    pub last_sync_mode: SyncMode,
    #[serde(default)]
    pub audio_sync_mode: AudioSyncMode,
    #[serde(default = "one_u8")]
    pub mic_style: u8,
    #[serde(default)]
    pub presets: Vec<Preset>,
    #[serde(default)]
    pub schedules: Vec<Schedule>,
    #[serde(default)]
    pub color_history: Vec<(f64, f64)>,
    #[serde(default)]
    pub default_preset_id: Option<Uuid>,
    #[serde(default = "half")]
    pub effect_speed: f64,
}

fn one() -> f64 {
    1.0
}
fn half() -> f64 {
    0.5
}
fn default_true() -> bool {
    true
}
fn one_u8() -> u8 {
    1
}
fn thirty() -> u16 {
    30
}
fn resp() -> f64 {
    0.7
}

impl Default for Persisted {
    fn default() -> Self {
        Self {
            is_on: false,
            hue: 0.0,
            sat: 0.0,
            brightness: 1.0,
            auto_connect: true,
            circadian_enabled: false,
            audio_input_source: AudioInputSource::Microphone,
            mic_sensitivity: 0.5,
            led_channel_order: 1,
            led_pixel_count: 30,
            sync_responsiveness: 0.7,
            beat_sensitivity: 0.5,
            video_sync_brightness: false,
            multi_light_enabled: false,
            last_sync_mode: SyncMode::Off,
            audio_sync_mode: AudioSyncMode::Rainbow,
            mic_style: 1,
            presets: Preset::defaults(),
            schedules: vec![],
            color_history: vec![],
            default_preset_id: None,
            effect_speed: 0.5,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSnapshot {
    pub connection_state: ConnectionState,
    pub connection_error: Option<String>,
    pub ble_needs_permission: bool,
    pub is_on: bool,
    pub hue: f64,
    pub sat: f64,
    pub brightness: f64,
    pub effect_id: u8,
    pub effect_speed: f64,
    pub effect_mode_active: bool,
    pub sync_mode: SyncMode,
    pub sync_hue: Option<f64>,
    pub sync_sat: Option<f64>,
    pub sync_error: Option<String>,
    pub sync_needs_permission: bool,
    pub sync_transitioning: bool,
    pub audio_sync_mode: AudioSyncMode,
    pub audio_input_source: AudioInputSource,
    pub mic_style: u8,
    pub mic_sensitivity: f64,
    pub led_channel_order: u8,
    pub led_pixel_count: u16,
    pub displays: Vec<DisplayInfo>,
    pub selected_display: Option<u32>,
    pub sync_responsiveness: f64,
    pub beat_sensitivity: f64,
    pub video_sync_brightness: bool,
    pub color_history: Vec<(f64, f64)>,
    pub circadian_enabled: bool,
    pub multi_light_enabled: bool,
    pub connected_light_names: Vec<String>,
    pub auto_connect: bool,
    pub presets: Vec<Preset>,
    pub schedules: Vec<Schedule>,
    pub default_preset_id: Option<Uuid>,
    pub effects: Vec<EffectSection>,
}

pub fn data_dir() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("LightStar")
}

pub fn state_path() -> PathBuf {
    data_dir().join("state.json")
}

pub fn load(path: &Path) -> Persisted {
    let Ok(bytes) = std::fs::read(path) else {
        return Persisted::default();
    };
    match serde_json::from_slice::<Persisted>(&bytes) {
        Ok(mut p) => {
            if p.presets.is_empty() {
                p.presets = Preset::defaults();
            }
            let now = chrono::Utc::now();
            for s in &mut p.schedules {
                if s.last_fired_at.is_none() {
                    s.last_fired_at = Some(now);
                }
            }
            p
        }
        Err(err) => {
            log::warn!("failed to decode state.json ({err}); starting fresh");
            Persisted::default()
        }
    }
}

pub fn save(path: &Path, persisted: &Persisted) {
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(bytes) = serde_json::to_vec_pretty(persisted) {
        let tmp = path.with_extension("json.tmp");
        if std::fs::write(&tmp, bytes).is_ok() {
            let _ = std::fs::rename(tmp, path);
        }
    }
}

pub fn snapshot_from(runtime: &crate::app::Runtime) -> AppSnapshot {
    AppSnapshot {
        connection_state: runtime.connection_state,
        connection_error: runtime.connection_error.clone(),
        ble_needs_permission: runtime.ble_needs_permission,
        is_on: runtime.persisted.is_on,
        hue: runtime.persisted.hue,
        sat: runtime.persisted.sat,
        brightness: runtime.persisted.brightness,
        effect_id: runtime.effect_id,
        effect_speed: runtime.persisted.effect_speed,
        effect_mode_active: runtime.effect_mode_active,
        sync_mode: runtime.sync_mode,
        sync_hue: runtime.sync_color.map(|c| c.0),
        sync_sat: runtime.sync_color.map(|c| c.1),
        sync_error: runtime.sync_error.clone(),
        sync_needs_permission: runtime.sync_needs_permission,
        sync_transitioning: runtime.sync_transitioning,
        audio_sync_mode: runtime.persisted.audio_sync_mode,
        audio_input_source: runtime.persisted.audio_input_source,
        mic_style: runtime.persisted.mic_style,
        mic_sensitivity: runtime.persisted.mic_sensitivity,
        led_channel_order: runtime.persisted.led_channel_order,
        led_pixel_count: runtime.persisted.led_pixel_count,
        displays: runtime.displays.clone(),
        selected_display: runtime.selected_display,
        sync_responsiveness: runtime.persisted.sync_responsiveness,
        beat_sensitivity: runtime.persisted.beat_sensitivity,
        video_sync_brightness: runtime.persisted.video_sync_brightness,
        color_history: runtime.persisted.color_history.clone(),
        circadian_enabled: runtime.persisted.circadian_enabled,
        multi_light_enabled: runtime.persisted.multi_light_enabled,
        connected_light_names: runtime.connected_light_names.clone(),
        auto_connect: runtime.persisted.auto_connect,
        presets: runtime.persisted.presets.clone(),
        schedules: runtime.persisted.schedules.clone(),
        default_preset_id: runtime.persisted.default_preset_id,
        effects: known_effects(),
    }
}
