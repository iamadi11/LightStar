mod app;
mod ble;
mod commands;
mod persist;
mod sync;

use crate::app::Host;
use persist::state_path;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{Emitter, Manager};
use tauri_plugin_autostart::MacosLauncher;

pub fn run() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_autostart::init(
            MacosLauncher::LaunchAgent,
            Some(vec![]),
        ))
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .setup(|app| {
            let (ble_tx_events, mut ble_rx) = tokio::sync::mpsc::unbounded_channel();
            let ble_cmd = ble::spawn(ble_tx_events);
            let host = Host::new(state_path(), ble_cmd);
            host.start_background(app.handle().clone());

            let host_events = host.clone();
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                while let Some(ev) = ble_rx.recv().await {
                    host_events.handle_ble_event(&handle, ev);
                }
            });

            app.manage(host);

            let show = MenuItem::with_id(app, "show", "Open LightStar", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit LightStar", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &quit])?;
            let _tray = TrayIconBuilder::new()
                .icon(app.default_window_icon().cloned().unwrap_or_else(|| {
                    tauri::image::Image::new(&[0, 0, 0, 255], 1, 1)
                }))
                .menu(&menu)
                .show_menu_on_left_click(false)
                .tooltip("LightStar")
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        show_main(tray.app_handle());
                    }
                })
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => show_main(app),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .build(app)?;

            if let Some(window) = app.get_webview_window("main") {
                let _ = window.show();
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_state,
            commands::connect,
            commands::disconnect,
            commands::set_power,
            commands::set_hue,
            commands::set_brightness,
            commands::set_color_temperature,
            commands::set_effect,
            commands::set_effect_speed,
            commands::exit_effect_mode,
            commands::set_animation,
            commands::set_sync_mode,
            commands::set_audio_sync_mode,
            commands::set_audio_input,
            commands::set_mic_style,
            commands::set_mic_sensitivity,
            commands::set_channel_order,
            commands::set_pixel_count,
            commands::set_circadian,
            commands::set_video_sync_brightness,
            commands::set_sync_responsiveness,
            commands::set_beat_sensitivity,
            commands::set_auto_connect,
            commands::set_multi_light,
            commands::apply_preset,
            commands::save_preset,
            commands::delete_preset,
            commands::rename_preset,
            commands::set_default_preset,
            commands::restore_default_presets,
            commands::export_presets,
            commands::import_presets,
            commands::add_schedule,
            commands::toggle_schedule,
            commands::delete_schedule,
            commands::refresh_displays,
            commands::set_display,
            commands::quit_app,
        ])
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running LightStar");
}

fn show_main(app: &tauri::AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.set_focus();
        let _ = w.unminimize();
    }
}

// Keep Emitter in scope for type inference on emit calls from Host.
#[allow(dead_code)]
fn _emit_bound<T: serde::Serialize + Clone>(app: &tauri::AppHandle, payload: T) {
    let _ = app.emit("state", payload);
}
