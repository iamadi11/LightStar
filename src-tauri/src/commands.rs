use crate::app::Host;
use crate::persist::{AudioInputSource, AudioSyncMode, SyncMode};
use lightstar_core::protocol::Cmd;
use lightstar_core::schedule::{Preset, ScheduledAction, Schedule};
use std::collections::BTreeSet;
use std::sync::Arc;
use tauri::{AppHandle, State};
use uuid::Uuid;

#[tauri::command]
pub fn get_state(host: State<Arc<Host>>) -> crate::persist::AppSnapshot {
    host.snapshot()
}

#[tauri::command]
pub fn connect(app: AppHandle, host: State<Arc<Host>>) {
    host.connect();
    host.emit(&app);
}

#[tauri::command]
pub fn disconnect(app: AppHandle, host: State<Arc<Host>>) {
    host.disconnect(&app);
}

#[tauri::command]
pub fn set_power(app: AppHandle, host: State<Arc<Host>>, on: bool) {
    host.set_power(&app, on);
}

#[tauri::command]
pub fn set_hue(app: AppHandle, host: State<Arc<Host>>, hue: f64, sat: f64) {
    host.set_hue(&app, hue, sat);
}

#[tauri::command]
pub fn set_brightness(app: AppHandle, host: State<Arc<Host>>, value: f64) {
    host.set_brightness(&app, value);
}

#[tauri::command]
pub fn set_color_temperature(app: AppHandle, host: State<Arc<Host>>, value: f64) {
    host.set_color_temperature(&app, value);
}

#[tauri::command]
pub fn set_effect(app: AppHandle, host: State<Arc<Host>>, id: u8) {
    host.set_effect(&app, id);
}

#[tauri::command]
pub fn set_effect_speed(app: AppHandle, host: State<Arc<Host>>, value: f64) {
    host.set_effect_speed(&app, value);
}

#[tauri::command]
pub fn exit_effect_mode(app: AppHandle, host: State<Arc<Host>>) {
    Arc::clone(&*host).exit_effect_mode(&app);
}

#[tauri::command]
pub fn set_animation(app: AppHandle, host: State<Arc<Host>>, id: u8) {
    host.set_animation(&app, id);
}

#[tauri::command]
pub fn set_sync_mode(app: AppHandle, host: State<Arc<Host>>, mode: String) {
    let mode = parse_sync(&mode);
    Arc::clone(&*host).set_sync_mode(&app, mode);
}

#[tauri::command]
pub fn set_audio_sync_mode(app: AppHandle, host: State<Arc<Host>>, mode: String) {
    host.lock().persisted.audio_sync_mode = match mode.as_str() {
        "pulse" => AudioSyncMode::Pulse,
        "frequency" => AudioSyncMode::Frequency,
        _ => AudioSyncMode::Rainbow,
    };
    host.persist();
    host.emit(&app);
}

#[tauri::command]
pub fn set_audio_input(app: AppHandle, host: State<Arc<Host>>, source: String) {
    let parsed = match source.as_str() {
        "stripMic" => AudioInputSource::StripMic,
        _ => AudioInputSource::Microphone,
    };
    let restart = {
        let mut rt = host.lock();
        let old = rt.persisted.audio_input_source;
        rt.persisted.audio_input_source = parsed;
        old != parsed && rt.sync_mode == SyncMode::Audio
    };
    if restart {
        Arc::clone(&*host).set_sync_mode(&app, SyncMode::Audio);
    }
    host.persist();
    host.emit(&app);
}

#[tauri::command]
pub fn set_mic_style(app: AppHandle, host: State<Arc<Host>>, style: u8) {
    host.lock().persisted.mic_style = style.clamp(1, 4);
    if host.lock().persisted.audio_input_source == AudioInputSource::StripMic {
        host.write(Cmd::mic_style(style.clamp(1, 4)));
    }
    host.persist();
    host.emit(&app);
}

#[tauri::command]
pub fn set_mic_sensitivity(app: AppHandle, host: State<Arc<Host>>, value: f64) {
    let v = value.clamp(0.0, 1.0);
    host.lock().persisted.mic_sensitivity = v;
    if host.lock().persisted.audio_input_source == AudioInputSource::StripMic {
        host.write(Cmd::mic_sensitivity((v * 255.0) as i32));
    }
    host.persist();
    host.emit(&app);
}

#[tauri::command]
pub fn set_channel_order(app: AppHandle, host: State<Arc<Host>>, order: u8) {
    host.lock().persisted.led_channel_order = order.clamp(1, 6);
    host.write(Cmd::channel_order(order.clamp(1, 6)));
    host.persist();
    host.emit(&app);
}

#[tauri::command]
pub fn set_pixel_count(app: AppHandle, host: State<Arc<Host>>, count: u16) {
    let n = count.clamp(8, 300);
    host.lock().persisted.led_pixel_count = n;
    host.write(Cmd::pixel_count(n as i32));
    host.persist();
    host.emit(&app);
}

#[tauri::command]
pub fn set_circadian(app: AppHandle, host: State<Arc<Host>>, enabled: bool) {
    host.lock().persisted.circadian_enabled = enabled;
    if enabled {
        host.apply_circadian(&app);
    }
    host.persist();
    host.emit(&app);
}

#[tauri::command]
pub fn set_video_sync_brightness(app: AppHandle, host: State<Arc<Host>>, enabled: bool) {
    host.lock().persisted.video_sync_brightness = enabled;
    host.persist();
    host.emit(&app);
}

#[tauri::command]
pub fn set_sync_responsiveness(app: AppHandle, host: State<Arc<Host>>, value: f64) {
    host.lock().persisted.sync_responsiveness = value.clamp(0.1, 1.0);
    host.persist();
    host.emit(&app);
}

#[tauri::command]
pub fn set_beat_sensitivity(app: AppHandle, host: State<Arc<Host>>, value: f64) {
    host.lock().persisted.beat_sensitivity = value.clamp(0.0, 1.0);
    host.persist();
    host.emit(&app);
}

#[tauri::command]
pub fn set_auto_connect(app: AppHandle, host: State<Arc<Host>>, enabled: bool) {
    host.lock().persisted.auto_connect = enabled;
    host.persist();
    host.emit(&app);
}

#[tauri::command]
pub fn set_multi_light(app: AppHandle, host: State<Arc<Host>>, enabled: bool) {
    host.lock().persisted.multi_light_enabled = enabled;
    host.set_multi_enabled(enabled);
    host.persist();
    host.emit(&app);
}

#[tauri::command]
pub fn apply_preset(app: AppHandle, host: State<Arc<Host>>, id: Uuid) {
    let preset = host
        .lock()
        .persisted
        .presets
        .iter()
        .find(|p| p.id == id)
        .cloned();
    if let Some(p) = preset {
        host.apply_preset(&app, p);
    }
}

#[tauri::command]
pub fn save_preset(app: AppHandle, host: State<Arc<Host>>, name: String) {
    let (h, s, bri) = {
        let rt = host.lock();
        (rt.persisted.hue, rt.persisted.sat, rt.persisted.brightness)
    };
    let (r, g, b) = lightstar_core::ColorMath::hsv_to_rgb(h, s, 1.0);
    let preset = Preset {
        id: Uuid::new_v4(),
        name,
        red: r,
        green: g,
        blue: b,
        brightness: bri,
    };
    host.lock().persisted.presets.push(preset);
    host.persist();
    host.emit(&app);
}

#[tauri::command]
pub fn delete_preset(app: AppHandle, host: State<Arc<Host>>, id: Uuid) {
    let mut rt = host.lock();
    if rt.persisted.default_preset_id == Some(id) {
        rt.persisted.default_preset_id = None;
    }
    rt.persisted.presets.retain(|p| p.id != id);
    drop(rt);
    host.persist();
    host.emit(&app);
}

#[tauri::command]
pub fn rename_preset(app: AppHandle, host: State<Arc<Host>>, id: Uuid, name: String) {
    if let Some(p) = host
        .lock()
        .persisted
        .presets
        .iter_mut()
        .find(|p| p.id == id)
    {
        p.name = name;
    }
    host.persist();
    host.emit(&app);
}

#[tauri::command]
pub fn set_default_preset(app: AppHandle, host: State<Arc<Host>>, id: Option<Uuid>) {
    host.lock().persisted.default_preset_id = id;
    host.persist();
    host.emit(&app);
}

#[tauri::command]
pub fn restore_default_presets(app: AppHandle, host: State<Arc<Host>>) {
    host.lock().persisted.presets = Preset::defaults();
    host.persist();
    host.emit(&app);
}

#[tauri::command]
pub fn export_presets(host: State<Arc<Host>>) -> Result<String, String> {
    serde_json::to_string_pretty(&host.lock().persisted.presets).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn import_presets(app: AppHandle, host: State<Arc<Host>>, json: String) -> Result<(), String> {
    let incoming: Vec<Preset> = serde_json::from_str(&json).map_err(|e| e.to_string())?;
    {
        let mut rt = host.lock();
        for p in incoming {
            if !rt.persisted.presets.iter().any(|e| e.id == p.id) {
                rt.persisted.presets.push(p);
            }
        }
    }
    host.persist();
    host.emit(&app);
    Ok(())
}

#[tauri::command]
pub fn add_schedule(
    app: AppHandle,
    host: State<Arc<Host>>,
    label: String,
    hour: u32,
    minute: u32,
    days: Vec<u32>,
    action: String,
    use_firmware_timer: bool,
) {
    let act = match action.as_str() {
        "powerOff" => ScheduledAction::PowerOff,
        "current" => {
            let rt = host.lock();
            ScheduledAction::Preset {
                color_hue: rt.persisted.hue,
                color_sat: rt.persisted.sat,
                brightness: rt.persisted.brightness,
            }
        }
        _ => ScheduledAction::PowerOn,
    };
    let schedule = Schedule {
        id: Uuid::new_v4(),
        label: if label.trim().is_empty() {
            "Schedule".into()
        } else {
            label
        },
        hour,
        minute,
        days: days.into_iter().collect::<BTreeSet<_>>(),
        is_enabled: true,
        action: act,
        last_fired_at: Some(chrono::Utc::now()),
        use_firmware_timer,
    };
    host.lock().persisted.schedules.push(schedule);
    host.push_firmware_timers();
    host.persist();
    host.emit(&app);
}

#[tauri::command]
pub fn toggle_schedule(app: AppHandle, host: State<Arc<Host>>, id: Uuid, enabled: bool) {
    if let Some(s) = host
        .lock()
        .persisted
        .schedules
        .iter_mut()
        .find(|s| s.id == id)
    {
        s.is_enabled = enabled;
    }
    host.push_firmware_timers();
    host.persist();
    host.emit(&app);
}

#[tauri::command]
pub fn delete_schedule(app: AppHandle, host: State<Arc<Host>>, id: Uuid) {
    host.lock().persisted.schedules.retain(|s| s.id != id);
    host.push_firmware_timers();
    host.persist();
    host.emit(&app);
}

#[tauri::command]
pub fn refresh_displays(app: AppHandle, host: State<Arc<Host>>) {
    host.refresh_displays(&app);
}

#[tauri::command]
pub fn set_display(app: AppHandle, host: State<Arc<Host>>, id: Option<u32>) {
    let restart = {
        let mut rt = host.lock();
        let old = rt.selected_display;
        rt.selected_display = id;
        old != id && rt.sync_mode.is_video()
    };
    if restart {
        let mode = host.lock().sync_mode;
        Arc::clone(&*host).set_sync_mode(&app, mode);
    }
    host.emit(&app);
}

#[tauri::command]
pub fn quit_app(app: AppHandle) {
    app.exit(0);
}

fn parse_sync(mode: &str) -> SyncMode {
    match mode {
        "video" => SyncMode::Video,
        "audio" => SyncMode::Audio,
        "combined" => SyncMode::Combined,
        _ => SyncMode::Off,
    }
}
