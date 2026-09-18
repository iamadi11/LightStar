use crate::persist::{
    snapshot_from, AudioInputSource, AudioSyncMode, ConnectionState, DisplayInfo, Persisted,
    SyncMode,
};
use crate::sync::{self, FrequencyBands};
use crate::{ble, persist};
use chrono::{Datelike, Timelike};
use lightstar_core::color::{oem_weekday_mask_now, ColorMath};
use lightstar_core::protocol::Cmd;
use lightstar_core::schedule::{Preset, ScheduledAction, Schedule, PENDING_CAP};
use lightstar_core::WriteCoalescer;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::{AppHandle, Emitter};
use tokio::sync::mpsc;

pub struct Host {
    pub inner: Arc<Mutex<Runtime>>,
    pub connected: Arc<AtomicBool>,
    coalescer: Arc<Mutex<WriteCoalescer>>,
    ble_tx: mpsc::UnboundedSender<ble::BleMsg>,
    persist_path: PathBuf,
    sync_tasks: Mutex<Vec<tauri::async_runtime::JoinHandle<()>>>,
    fade_task: Mutex<Option<tauri::async_runtime::JoinHandle<()>>>,
    connect_seq: Mutex<Option<tauri::async_runtime::JoinHandle<()>>>,
}

pub struct Runtime {
    pub persisted: Persisted,
    pub connection_state: ConnectionState,
    pub connection_error: Option<String>,
    pub ble_needs_permission: bool,
    pub effect_id: u8,
    pub effect_mode_active: bool,
    pub sync_mode: SyncMode,
    pub sync_color: Option<(f64, f64)>,
    pub sync_error: Option<String>,
    pub sync_needs_permission: bool,
    pub sync_transitioning: bool,
    pub displays: Vec<DisplayInfo>,
    pub selected_display: Option<u32>,
    pub connected_light_names: Vec<String>,
    pub pending_actions: Vec<ScheduledAction>,
    pub last_screen_h: f64,
    pub last_screen_s: f64,
    pub audio_pulse_h: f64,
    pub beat_hue: f64,
    pub flash_level: f64,
    pub user_disconnect: bool,
}

impl Host {
    pub fn new(persist_path: PathBuf, ble_tx: mpsc::UnboundedSender<ble::BleMsg>) -> Arc<Self> {
        let persisted = persist::load(&persist_path);
        let runtime = Runtime {
            audio_pulse_h: persisted.hue,
            beat_hue: persisted.hue,
            persisted,
            connection_state: ConnectionState::Disconnected,
            connection_error: None,
            ble_needs_permission: false,
            effect_id: 0x01,
            effect_mode_active: false,
            sync_mode: SyncMode::Off,
            sync_color: None,
            sync_error: None,
            sync_needs_permission: false,
            sync_transitioning: false,
            displays: vec![],
            selected_display: None,
            connected_light_names: vec![],
            pending_actions: vec![],
            last_screen_h: 0.0,
            last_screen_s: 1.0,
            flash_level: 0.0,
            user_disconnect: false,
        };
        Arc::new(Self {
            inner: Arc::new(Mutex::new(runtime)),
            connected: Arc::new(AtomicBool::new(false)),
            coalescer: Arc::new(Mutex::new(WriteCoalescer::new())),
            ble_tx,
            persist_path,
            sync_tasks: Mutex::new(Vec::new()),
            fade_task: Mutex::new(None),
            connect_seq: Mutex::new(None),
        })
    }

    pub fn start_background(self: &Arc<Self>, app: AppHandle) {
        self.start_coalescer();
        self.start_schedule_ticker(app.clone());
        self.start_circadian_ticker(app.clone());
        let auto = self.lock().persisted.auto_connect;
        if auto {
            self.connect();
        }
        let _ = app;
    }

    pub fn lock(&self) -> std::sync::MutexGuard<'_, Runtime> {
        self.inner.lock().expect("runtime mutex")
    }

    pub fn emit(&self, app: &AppHandle) {
        let snap = snapshot_from(&self.lock());
        let _ = app.emit("state", snap);
    }

    pub fn persist(&self) {
        let p = self.lock().persisted.clone();
        persist::save(&self.persist_path, &p);
    }

    pub fn snapshot(&self) -> persist::AppSnapshot {
        snapshot_from(&self.lock())
    }

    fn start_coalescer(self: &Arc<Self>) {
        let coalescer = self.coalescer.clone();
        let connected = self.connected.clone();
        let ble_tx = self.ble_tx.clone();
        tauri::async_runtime::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_millis(20));
            loop {
                tick.tick().await;
                if !connected.load(Ordering::SeqCst) {
                    coalescer.lock().expect("coalescer").flush();
                    continue;
                }
                let next = coalescer.lock().expect("coalescer").pop();
                if let Some(frame) = next {
                    let _ = ble_tx.send(ble::BleMsg::Write(frame));
                }
            }
        });
    }

    fn start_schedule_ticker(self: &Arc<Self>, app: AppHandle) {
        let host = Arc::clone(self);
        tauri::async_runtime::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(15));
            loop {
                tick.tick().await;
                host.fire_due(&app);
            }
        });
    }

    fn start_circadian_ticker(self: &Arc<Self>, app: AppHandle) {
        let host = Arc::clone(self);
        tauri::async_runtime::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(60));
            loop {
                tick.tick().await;
                host.apply_circadian(&app);
            }
        });
    }

    pub fn write(&self, bytes: Vec<u8>) {
        if !self.connected.load(Ordering::SeqCst) {
            return;
        }
        self.coalescer.lock().expect("coalescer").enqueue(&bytes);
    }

    pub fn connect(&self) {
        {
            let mut rt = self.lock();
            if rt.connection_state != ConnectionState::Disconnected {
                return;
            }
            rt.user_disconnect = false;
            rt.connection_error = None;
            rt.ble_needs_permission = false;
            rt.connection_state = ConnectionState::Scanning;
            let multi = rt.persisted.multi_light_enabled;
            drop(rt);
            let _ = self.ble_tx.send(ble::BleMsg::Connect { multi });
        }
    }

    pub fn disconnect(&self, app: &AppHandle) {
        if let Some(h) = self.connect_seq.lock().expect("seq").take() {
            h.abort();
        }
        self.stop_sync_inline();
        {
            let mut rt = self.lock();
            rt.user_disconnect = true;
            rt.connection_error = None;
            rt.ble_needs_permission = false;
            rt.persisted.last_sync_mode = SyncMode::Off;
            rt.connection_state = ConnectionState::Disconnected;
            rt.connected_light_names.clear();
        }
        self.connected.store(false, Ordering::SeqCst);
        self.coalescer.lock().expect("coalescer").flush();
        let _ = self.ble_tx.send(ble::BleMsg::Disconnect);
        self.persist();
        self.emit(app);
    }

    pub fn handle_ble_event(self: &Arc<Self>, app: &AppHandle, ev: ble::BleEvent) {
        match ev {
            ble::BleEvent::Scanning => {
                self.lock().connection_state = ConnectionState::Scanning;
            }
            ble::BleEvent::Connecting { name } => {
                let mut rt = self.lock();
                rt.connection_state = ConnectionState::Connecting;
                rt.connected_light_names = vec![name];
            }
            ble::BleEvent::Connected { names } => {
                self.connected.store(true, Ordering::SeqCst);
                {
                    let mut rt = self.lock();
                    rt.connection_state = ConnectionState::Connected;
                    rt.connection_error = None;
                    rt.ble_needs_permission = false;
                    rt.connected_light_names = names;
                }
                self.begin_connect_sequence(app);
            }
            ble::BleEvent::Disconnected { reason } => {
                let user = self.lock().user_disconnect;
                self.connected.store(false, Ordering::SeqCst);
                self.stop_sync_inline();
                self.coalescer.lock().expect("coalescer").flush();
                {
                    let mut rt = self.lock();
                    rt.connection_state = ConnectionState::Disconnected;
                    if !user {
                        rt.connection_error = reason.or_else(|| {
                            Some("Could not reconnect — tap Connect to retry".into())
                        });
                    }
                }
            }
            ble::BleEvent::NotFound => {
                self.connected.store(false, Ordering::SeqCst);
                let mut rt = self.lock();
                rt.connection_state = ConnectionState::Disconnected;
                rt.connection_error =
                    Some("Device not found — make sure it's powered on".into());
            }
            ble::BleEvent::PermissionDenied { message } => {
                let mut rt = self.lock();
                rt.connection_state = ConnectionState::Disconnected;
                rt.ble_needs_permission = true;
                rt.connection_error = Some(message);
            }
            ble::BleEvent::AdapterOff => {
                let mut rt = self.lock();
                rt.connection_state = ConnectionState::Disconnected;
                rt.connection_error = Some("Bluetooth is off — turn it on to connect".into());
            }
            ble::BleEvent::WriteFailed { message } => {
                self.lock().connection_error = Some(format!("Write failed: {message}"));
            }
            ble::BleEvent::TimedOut => {
                self.connected.store(false, Ordering::SeqCst);
                let mut rt = self.lock();
                rt.connection_state = ConnectionState::Disconnected;
                rt.connection_error =
                    Some("Connection timed out — is the light powered on?".into());
            }
        }
        self.emit(app);
    }

    fn begin_connect_sequence(self: &Arc<Self>, app: &AppHandle) {
        if let Some(h) = self.connect_seq.lock().expect("seq").take() {
            h.abort();
        }
        self.send_time_sync();
        let host = Arc::clone(self);
        let app = app.clone();
        let handle = tauri::async_runtime::spawn(async move {
            let target_on = host.lock().persisted.is_on;
            host.write(Cmd::power_off().to_vec());
            tokio::time::sleep(Duration::from_millis(500)).await;
            if target_on {
                host.write(Cmd::power_on().to_vec());
                tokio::time::sleep(Duration::from_millis(500)).await;
            }
            {
                let mut rt = host.lock();
                rt.persisted.is_on = target_on;
            }
            let (h, s, bri, last_sync, circadian, default_id, presets) = {
                let rt = host.lock();
                (
                    rt.persisted.hue,
                    rt.persisted.sat,
                    rt.persisted.brightness,
                    rt.persisted.last_sync_mode,
                    rt.persisted.circadian_enabled,
                    rt.persisted.default_preset_id,
                    rt.persisted.presets.clone(),
                )
            };
            host.write(Cmd::hue(h, s));
            host.write(Cmd::brightness(bri));
            host.push_firmware_timers();
            host.drain_pending(&app);
            if last_sync != SyncMode::Off {
                host.lock().persisted.last_sync_mode = SyncMode::Off;
                host.set_sync_mode(&app, last_sync);
            } else if circadian {
                host.apply_circadian(&app);
            } else if let Some(id) = default_id {
                if let Some(p) = presets.into_iter().find(|p| p.id == id) {
                    host.apply_preset(&app, p);
                }
            }
            host.persist();
            host.emit(&app);
        });
        *self.connect_seq.lock().expect("seq") = Some(handle);
    }

    pub fn send_time_sync(&self) {
        let now = chrono::Local::now();
        let yr = (now.year() - 2000).clamp(0, 255) as u8;
        self.write(Cmd::time_sync(
            yr,
            now.month() as u8,
            now.day() as u8,
            now.hour() as u8,
            now.minute() as u8,
            now.second() as u8,
            oem_weekday_mask_now(),
        ));
    }

    pub fn set_power(&self, app: &AppHandle, on: bool) {
        {
            let mut rt = self.lock();
            rt.persisted.is_on = on;
        }
        if !on {
            if let Some(h) = self.connect_seq.lock().expect("seq").take() {
                h.abort();
            }
            self.stop_sync_inline();
        }
        self.write(if on {
            Cmd::power_on().to_vec()
        } else {
            Cmd::power_off().to_vec()
        });
        self.persist();
        self.emit(app);
    }

    pub fn set_hue(&self, app: &AppHandle, h: f64, s: f64) {
        if self.lock().sync_mode != SyncMode::Off {
            self.stop_sync_inline();
        }
        {
            let mut rt = self.lock();
            rt.persisted.hue = h;
            rt.persisted.sat = s;
            rt.audio_pulse_h = h;
            rt.effect_mode_active = false;
            record_history(&mut rt.persisted.color_history, h, s);
        }
        if let Some(t) = self.fade_task.lock().expect("fade").take() {
            t.abort();
        }
        self.write(Cmd::hue(h, s));
        let bri = self.lock().persisted.brightness;
        self.write(Cmd::brightness(bri));
        self.persist();
        self.emit(app);
    }

    pub fn set_brightness(&self, app: &AppHandle, value: f64) {
        if self.lock().sync_mode != SyncMode::Off {
            self.stop_sync_inline();
        }
        let v = value.clamp(0.0, 1.0);
        self.lock().persisted.brightness = v;
        self.write(Cmd::brightness(v));
        self.persist();
        self.emit(app);
    }

    pub fn set_color_temperature(&self, app: &AppHandle, t: f64) {
        let kelvin = 2700.0 + t.clamp(0.0, 1.0) * 3800.0;
        let (h, s) = ColorMath::kelvin_to_hs(kelvin);
        self.set_hue(app, h, s);
    }

    pub fn set_effect(&self, app: &AppHandle, id: u8) {
        self.stop_sync_inline();
        {
            let mut rt = self.lock();
            rt.effect_id = id;
            rt.effect_mode_active = true;
        }
        self.write(Cmd::effect(id));
        let speed = self.lock().persisted.effect_speed;
        self.write(Cmd::speed(speed));
        self.emit(app);
    }

    pub fn set_effect_speed(&self, app: &AppHandle, value: f64) {
        let v = value.clamp(0.0, 1.0);
        self.lock().persisted.effect_speed = v;
        self.write(Cmd::speed(v));
        self.persist();
        self.emit(app);
    }

    pub fn exit_effect_mode(self: &Arc<Self>, app: &AppHandle) {
        self.lock().effect_mode_active = false;
        if let Some(t) = self.fade_task.lock().expect("fade").take() {
            t.abort();
        }
        self.emit(app);
        let host = Arc::clone(self);
        let app = app.clone();
        let handle = tauri::async_runtime::spawn(async move {
            host.write(Cmd::power_off().to_vec());
            tokio::time::sleep(Duration::from_millis(200)).await;
            let (is_on, h, s, bri) = {
                let rt = host.lock();
                (
                    rt.persisted.is_on,
                    rt.persisted.hue,
                    rt.persisted.sat,
                    rt.persisted.brightness,
                )
            };
            if !is_on {
                return;
            }
            host.write(Cmd::power_on().to_vec());
            tokio::time::sleep(Duration::from_millis(200)).await;
            if !host.lock().persisted.is_on {
                return;
            }
            host.write(Cmd::hue(h, s));
            host.write(Cmd::brightness(bri));
            host.emit(&app);
        });
        *self.fade_task.lock().expect("fade") = Some(handle);
    }

    pub fn set_animation(&self, app: &AppHandle, id: u8) {
        if self.lock().sync_mode != SyncMode::Off {
            self.stop_sync_inline();
        }
        self.write(Cmd::animation(id));
        self.emit(app);
    }

    pub fn apply_preset(&self, app: &AppHandle, preset: Preset) {
        if !self.lock().persisted.is_on {
            self.set_power(app, true);
        }
        let (h, s, _) = preset.hsv();
        self.set_hue(app, h, s);
        self.set_brightness(app, preset.brightness);
    }

    pub fn apply_circadian(&self, app: &AppHandle) {
        let ok = {
            let rt = self.lock();
            rt.persisted.circadian_enabled
                && rt.connection_state == ConnectionState::Connected
                && rt.persisted.is_on
                && rt.sync_mode == SyncMode::Off
        };
        if !ok {
            return;
        }
        self.set_color_temperature(app, ColorMath::circadian_now());
    }

    pub fn set_sync_mode(self: &Arc<Self>, app: &AppHandle, mode: SyncMode) {
        let prev = self.lock().sync_mode;
        self.lock().sync_transitioning = true;
        self.lock().sync_error = None;
        self.lock().sync_needs_permission = false;
        self.emit(app);
        let host = Arc::clone(self);
        let app = app.clone();
        tauri::async_runtime::spawn(async move {
            host.teardown_sync().await;
            host.build_sync(&app, mode, prev).await;
            host.lock().sync_transitioning = false;
            host.persist();
            host.emit(&app);
        });
    }

    async fn teardown_sync(&self) {
        let mut tasks = self.sync_tasks.lock().expect("sync");
        for t in tasks.drain(..) {
            t.abort();
        }
        if self.lock().persisted.audio_input_source == AudioInputSource::StripMic {
            self.write(Cmd::strip_mic(false));
        }
        self.lock().flash_level = 0.0;
    }

    pub fn stop_sync_inline(&self) {
        let mut tasks = self.sync_tasks.lock().expect("sync");
        for t in tasks.drain(..) {
            t.abort();
        }
        if let Some(t) = self.fade_task.lock().expect("fade").take() {
            t.abort();
        }
        {
            let mut rt = self.lock();
            if rt.sync_mode != SyncMode::Off {
                rt.persisted.last_sync_mode = rt.sync_mode;
            }
            if rt.persisted.audio_input_source == AudioInputSource::StripMic {
                drop(rt);
                self.write(Cmd::strip_mic(false));
            }
        }
        {
            let mut rt = self.lock();
            rt.sync_mode = SyncMode::Off;
            rt.sync_color = None;
            rt.sync_transitioning = false;
            rt.flash_level = 0.0;
        }
    }

    async fn build_sync(self: &Arc<Self>, app: &AppHandle, mode: SyncMode, prev: SyncMode) {
        self.lock().effect_mode_active = false;
        if mode != SyncMode::Off && self.lock().connection_state != ConnectionState::Connected {
            self.lock().sync_mode = SyncMode::Off;
            self.lock().sync_error = Some("Not connected".into());
            return;
        }
        match mode {
            SyncMode::Off => {
                self.lock().sync_mode = SyncMode::Off;
                self.fade_to_steady(app, prev);
            }
            SyncMode::Video => match self.start_video(app) {
                Ok(()) => self.lock().sync_mode = SyncMode::Video,
                Err(err) => {
                    self.lock().sync_mode = SyncMode::Off;
                    self.set_sync_error(err);
                    self.restore_steady();
                }
            },
            SyncMode::Audio => {
                let h = self.lock().persisted.hue;
                self.lock().beat_hue = h;
                self.lock().audio_pulse_h = h;
                match self.start_audio(app, false) {
                    Ok(()) => self.lock().sync_mode = SyncMode::Audio,
                    Err(err) => {
                        self.lock().sync_mode = SyncMode::Off;
                        self.set_sync_error(err);
                        self.restore_steady();
                    }
                }
            }
            SyncMode::Combined => {
                let video_ok = self.start_video(app).is_ok();
                let audio_ok = self.start_audio(app, true).is_ok();
                self.lock().sync_mode = match (video_ok, audio_ok) {
                    (true, true) => SyncMode::Combined,
                    (true, false) => SyncMode::Video,
                    (false, true) => SyncMode::Audio,
                    _ => SyncMode::Off,
                };
                if self.lock().sync_mode == SyncMode::Off {
                    self.restore_steady();
                }
            }
        }
    }

    fn start_video(self: &Arc<Self>, app: &AppHandle) -> Result<(), String> {
        let host = Arc::clone(self);
        let app = app.clone();
        let selected = self.lock().selected_display;
        let handle = tauri::async_runtime::spawn(async move {
            let mut smooth_h = -1.0;
            let mut smooth_s = 0.0;
            let mut smooth_v = -1.0;
            let mut last_write = std::time::Instant::now() - Duration::from_secs(1);
            let mut tick = tokio::time::interval(Duration::from_millis(50));
            loop {
                tick.tick().await;
                let (mode, is_on, resp, video_bri) = {
                    let rt = host.lock();
                    (
                        rt.sync_mode,
                        rt.persisted.is_on,
                        rt.persisted.sync_responsiveness,
                        rt.persisted.video_sync_brightness,
                    )
                };
                if !mode.is_video() || !is_on {
                    continue;
                }
                let sampled = match tokio::task::spawn_blocking(move || {
                    sync::sample_screen(selected)
                })
                .await
                {
                    Ok(Ok(hsv)) => hsv,
                    Ok(Err(err)) => {
                        host.set_sync_error(err);
                        host.emit(&app);
                        break;
                    }
                    Err(_) => break,
                };
                let (h, s, v) = sampled;
                if v <= 0.04 {
                    continue;
                }
                let now = std::time::Instant::now();
                if now.duration_since(last_write) < Duration::from_millis(50) {
                    continue;
                }
                if smooth_h < 0.0 {
                    smooth_h = h;
                    smooth_s = s;
                    smooth_v = v;
                }
                let mut dh = h - smooth_h;
                if dh > 0.5 {
                    dh -= 1.0;
                }
                if dh < -0.5 {
                    dh += 1.0;
                }
                smooth_h = (smooth_h + dh * resp).rem_euclid(1.0);
                smooth_s += (s - smooth_s) * resp;
                smooth_v += (v - smooth_v) * 0.15;
                let last_h = host.lock().last_screen_h;
                let hue_delta = (smooth_h - last_h).abs().min(1.0 - (smooth_h - last_h).abs());
                if hue_delta <= 0.008 && now.duration_since(last_write) < Duration::from_millis(500)
                {
                    continue;
                }
                last_write = now;
                let boosted_s = if smooth_s < 0.3 {
                    (smooth_s * 3.0).min(1.0)
                } else {
                    (smooth_s * 1.5).min(1.0)
                };
                {
                    let mut rt = host.lock();
                    rt.last_screen_h = smooth_h;
                    rt.last_screen_s = boosted_s;
                    rt.sync_color = Some((smooth_h, boosted_s));
                }
                host.write(Cmd::hue(smooth_h, boosted_s));
                if video_bri && host.lock().sync_mode == SyncMode::Video {
                    host.write(Cmd::brightness((smooth_v * 1.3).clamp(0.05, 1.0)));
                }
                host.emit(&app);
            }
        });
        self.sync_tasks
            .lock()
            .expect("sync")
            .push(handle);
        Ok(())
    }

    fn start_audio(self: &Arc<Self>, app: &AppHandle, combined: bool) -> Result<(), String> {
        let source = self.lock().persisted.audio_input_source;
        if source == AudioInputSource::StripMic {
            let (style, sens) = {
                let rt = self.lock();
                (rt.persisted.mic_style, rt.persisted.mic_sensitivity)
            };
            self.write(Cmd::strip_mic(true));
            self.write(Cmd::mic_style(style));
            self.write(Cmd::mic_sensitivity((sens * 255.0) as i32));
            return Ok(());
        }
        let _ = combined;
        let host = Arc::clone(self);
        let app = app.clone();
        let (tx, mut rx) = mpsc::unbounded_channel::<FrequencyBands>();
        match sync::start_mic(tx) {
            Ok(stop) => {
                let handle = tauri::async_runtime::spawn(async move {
                    let mut last_write = std::time::Instant::now() - Duration::from_secs(1);
                    let mut silence_start: Option<std::time::Instant> = None;
                    while let Some(bands) = rx.recv().await {
                        let (mode, is_on, beat_sens, audio_mode) = {
                            let rt = host.lock();
                            (
                                rt.sync_mode,
                                rt.persisted.is_on,
                                rt.persisted.beat_sensitivity,
                                rt.persisted.audio_sync_mode,
                            )
                        };
                        if !mode.is_audio() || !is_on {
                            continue;
                        }
                        let now = std::time::Instant::now();
                        if bands.rms < 0.01 {
                            let start = silence_start.get_or_insert(now);
                            if now.duration_since(*start) >= Duration::from_secs(2)
                                && mode == SyncMode::Audio
                            {
                                host.lock().persisted.last_sync_mode = SyncMode::Audio;
                                host.set_sync_mode(&app, SyncMode::Off);
                                break;
                            }
                        } else {
                            silence_start = None;
                        }
                        if now.duration_since(last_write) < Duration::from_millis(33) {
                            continue;
                        }
                        last_write = now;
                        let beat_threshold = 1.0 - beat_sens * 0.8;
                        let is_beat = bands.flux > beat_threshold && bands.rms > 0.03;
                        if mode == SyncMode::Combined {
                            let (lh, ls) = {
                                let rt = host.lock();
                                (rt.last_screen_h, rt.last_screen_s)
                            };
                            if is_beat {
                                host.lock().flash_level = 1.0;
                                host.write(Cmd::hue(lh, (ls * 1.3 + 0.15).min(1.0)));
                            } else {
                                let mut rt = host.lock();
                                rt.flash_level = (rt.flash_level * 0.82).max(0.0);
                            }
                            let flash = host.lock().flash_level;
                            host.lock().sync_color = Some((lh, ls));
                            let bri =
                                (bands.bass * 0.55 + bands.rms * 0.15 + flash * 0.80).clamp(0.04, 1.0);
                            host.write(Cmd::brightness(bri));
                            host.emit(&app);
                            continue;
                        }
                        match audio_mode {
                            AudioSyncMode::Rainbow => {
                                let mut rt = host.lock();
                                if is_beat {
                                    rt.beat_hue = (rt.beat_hue + 1.0 / 12.0) % 1.0;
                                } else {
                                    rt.beat_hue = (rt.beat_hue + bands.high * 0.006) % 1.0;
                                }
                                let hue = rt.beat_hue;
                                drop(rt);
                                let sat = (0.6 + bands.mid * 0.4).min(1.0);
                                host.lock().sync_color = Some((hue, sat));
                                host.write(Cmd::audio_hue(hue, sat));
                                host.write(Cmd::brightness(
                                    (bands.bass * 1.3 + bands.rms * 0.3).clamp(0.05, 1.0),
                                ));
                            }
                            AudioSyncMode::Pulse => {
                                let hue = host.lock().audio_pulse_h;
                                host.lock().sync_color = Some((hue, 1.0));
                                host.write(Cmd::audio_hue(hue, (0.8 + bands.mid * 0.2).min(1.0)));
                                host.write(Cmd::brightness(
                                    (bands.bass * 1.5 + bands.rms * 0.2).clamp(0.03, 1.0),
                                ));
                            }
                            AudioSyncMode::Frequency => {
                                let h_total = bands.mid + bands.high + 0.001;
                                let h = (bands.mid * (120.0 / 360.0) + bands.high * (240.0 / 360.0))
                                    / h_total;
                                host.lock().sync_color = Some((h, 1.0));
                                host.write(Cmd::audio_hue(h, 1.0));
                                let avg = (bands.bass + bands.mid + bands.high) / 3.0;
                                host.write(Cmd::brightness(
                                    (avg * 1.5 + bands.rms * 0.2).clamp(0.05, 1.0),
                                ));
                            }
                        }
                        host.emit(&app);
                    }
                    drop(stop);
                });
                self.sync_tasks
                    .lock()
                    .expect("sync")
                    .push(handle);
                Ok(())
            }
            Err(err) => Err(err),
        }
    }

    fn set_sync_error(&self, err: String) {
        let mut rt = self.lock();
        let lower = err.to_lowercase();
        let is_mic = lower.contains("microphone") || lower.contains("mic");
        let is_screen = lower.contains("screen") || lower.contains("capture") || lower.contains("permission");
        rt.sync_needs_permission = is_mic || is_screen;
        rt.sync_error = Some(if is_mic {
            "Microphone access required. Open Privacy & Security → Microphone and enable LightStar.".into()
        } else if is_screen {
            "Screen Recording access required. Open Privacy & Security → Screen Recording and enable LightStar.".into()
        } else {
            err
        });
    }

    fn restore_steady(&self) {
        if !self.lock().persisted.is_on {
            return;
        }
        let (h, s, bri) = {
            let rt = self.lock();
            (rt.persisted.hue, rt.persisted.sat, rt.persisted.brightness)
        };
        self.write(Cmd::hue(h, s));
        self.write(Cmd::brightness(bri));
    }

    fn fade_to_steady(self: &Arc<Self>, _app: &AppHandle, prev: SyncMode) {
        if !self.lock().persisted.is_on {
            return;
        }
        let (target_h, target_s, target_bri, start_h, start_s, start_bri) = {
            let rt = self.lock();
            let (sh, ss, sb) = match prev {
                SyncMode::Video | SyncMode::Combined => (rt.last_screen_h, rt.last_screen_s, rt.persisted.brightness),
                SyncMode::Audio => (rt.audio_pulse_h, 0.9, 1.0),
                SyncMode::Off => {
                    drop(rt);
                    self.restore_steady();
                    return;
                }
            };
            (rt.persisted.hue, rt.persisted.sat, rt.persisted.brightness, sh, ss, sb)
        };
        let hue_dist = (start_h - target_h).abs().min(1.0 - (start_h - target_h).abs());
        if hue_dist <= 0.02 && (start_s - target_s).abs() <= 0.05 && (start_bri - target_bri).abs() <= 0.05 {
            self.restore_steady();
            return;
        }
        if let Some(t) = self.fade_task.lock().expect("fade").take() {
            t.abort();
        }
        let host = Arc::clone(self);
        let handle = tauri::async_runtime::spawn(async move {
            let steps = 18;
            for i in 1..=steps {
                let t = i as f64 / steps as f64;
                let e = if t < 0.5 { 2.0 * t * t } else { -1.0 + (4.0 - 2.0 * t) * t };
                let mut dh = target_h - start_h;
                if dh > 0.5 {
                    dh -= 1.0;
                }
                if dh < -0.5 {
                    dh += 1.0;
                }
                let h = (start_h + dh * e).rem_euclid(1.0);
                let s = (start_s + (target_s - start_s) * e).clamp(0.0, 1.0);
                let bri = (start_bri + (target_bri - start_bri) * e).clamp(0.0, 1.0);
                host.write(Cmd::hue(h, s));
                host.write(Cmd::brightness(bri));
                tokio::time::sleep(Duration::from_micros(16_700)).await;
            }
            host.restore_steady();
        });
        *self.fade_task.lock().expect("fade") = Some(handle);
    }

    pub fn fire_due(&self, app: &AppHandle) {
        let now = chrono::Local::now();
        let mut due = Vec::new();
        {
            let mut rt = self.lock();
            for s in rt.persisted.schedules.iter_mut() {
                if s.is_due(now, 15 * 60) {
                    s.last_fired_at = Some(chrono::Utc::now());
                    due.push(s.action.clone());
                }
            }
        }
        if due.is_empty() {
            return;
        }
        for action in due {
            self.perform_action(app, action);
        }
        self.persist();
        self.emit(app);
    }

    fn perform_action(&self, app: &AppHandle, action: ScheduledAction) {
        let connected = self.lock().connection_state == ConnectionState::Connected;
        if !connected {
            let mut rt = self.lock();
            if rt.pending_actions.len() < PENDING_CAP {
                rt.pending_actions.push(action);
            }
            drop(rt);
            self.connect();
            return;
        }
        self.apply_action(app, action);
    }

    fn apply_action(&self, app: &AppHandle, action: ScheduledAction) {
        match action {
            ScheduledAction::PowerOn => self.set_power(app, true),
            ScheduledAction::PowerOff => self.set_power(app, false),
            ScheduledAction::Preset {
                color_hue,
                color_sat,
                brightness,
            } => {
                if !self.lock().persisted.is_on {
                    self.set_power(app, true);
                }
                self.set_hue(app, color_hue, color_sat);
                self.set_brightness(app, brightness);
            }
        }
    }

    fn drain_pending(&self, app: &AppHandle) {
        let queued = {
            let mut rt = self.lock();
            std::mem::take(&mut rt.pending_actions)
        };
        for action in queued {
            self.apply_action(app, action);
        }
    }

    pub fn push_firmware_timers(&self) {
        if self.lock().connection_state != ConnectionState::Connected {
            return;
        }
        let schedules = self.lock().persisted.schedules.clone();
        let mut slot: u8 = 1;
        for schedule in schedules.into_iter().filter(|s| s.firmware_timer_enabled()) {
            let power_on = !matches!(schedule.action, ScheduledAction::PowerOff);
            self.write(Cmd::weekly_timer(
                slot,
                power_on,
                schedule.is_enabled,
                Schedule::oem_day_mask(&schedule.days),
                schedule.hour as u8,
                schedule.minute as u8,
            ));
            slot = slot.wrapping_add(1);
            if slot == 0 {
                break;
            }
        }
    }

    pub fn refresh_displays(&self, app: &AppHandle) {
        self.lock().displays = sync::list_displays();
        self.emit(app);
    }

    pub fn set_multi_enabled(&self, enabled: bool) {
        let _ = self.ble_tx.send(ble::BleMsg::SetMulti(enabled));
        if !enabled {
            let mut rt = self.lock();
            if rt.connected_light_names.len() > 1 {
                rt.connected_light_names.truncate(1);
            }
        }
    }
}

fn record_history(history: &mut Vec<(f64, f64)>, h: f64, s: f64) {
    if s <= 0.05 {
        return;
    }
    history.retain(|(oh, os)| (oh - h).abs() > 0.03 || (os - s).abs() > 0.08);
    history.insert(0, (h, s));
    history.truncate(12);
}
