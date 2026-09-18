import { EMPTY_STATE, type AppSnapshot } from "./types";

type Unlisten = () => void;

function isTauri() {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

async function invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  if (!isTauri()) {
    throw new Error("not tauri");
  }
  const { invoke: inv } = await import("@tauri-apps/api/core");
  return inv<T>(cmd, args);
}

export async function getState(): Promise<AppSnapshot> {
  try {
    return await invoke<AppSnapshot>("get_state");
  } catch {
    return EMPTY_STATE;
  }
}

export async function listenState(cb: (s: AppSnapshot) => void): Promise<Unlisten> {
  if (!isTauri()) return () => undefined;
  const { listen } = await import("@tauri-apps/api/event");
  const un = await listen<AppSnapshot>("state", (e) => cb(e.payload));
  return () => {
    un();
  };
}

export const api = {
  connect: () => invoke<void>("connect"),
  disconnect: () => invoke<void>("disconnect"),
  setPower: (on: boolean) => invoke<void>("set_power", { on }),
  setHue: (hue: number, sat: number) => invoke<void>("set_hue", { hue, sat }),
  setBrightness: (value: number) => invoke<void>("set_brightness", { value }),
  setColorTemperature: (value: number) => invoke<void>("set_color_temperature", { value }),
  setEffect: (id: number) => invoke<void>("set_effect", { id }),
  setEffectSpeed: (value: number) => invoke<void>("set_effect_speed", { value }),
  exitEffectMode: () => invoke<void>("exit_effect_mode"),
  setAnimation: (id: number) => invoke<void>("set_animation", { id }),
  setSyncMode: (mode: string) => invoke<void>("set_sync_mode", { mode }),
  setAudioSyncMode: (mode: string) => invoke<void>("set_audio_sync_mode", { mode }),
  setAudioInput: (source: string) => invoke<void>("set_audio_input", { source }),
  setMicStyle: (style: number) => invoke<void>("set_mic_style", { style }),
  setMicSensitivity: (value: number) => invoke<void>("set_mic_sensitivity", { value }),
  setChannelOrder: (order: number) => invoke<void>("set_channel_order", { order }),
  setPixelCount: (count: number) => invoke<void>("set_pixel_count", { count }),
  setCircadian: (enabled: boolean) => invoke<void>("set_circadian", { enabled }),
  setVideoSyncBrightness: (enabled: boolean) =>
    invoke<void>("set_video_sync_brightness", { enabled }),
  setSyncResponsiveness: (value: number) =>
    invoke<void>("set_sync_responsiveness", { value }),
  setBeatSensitivity: (value: number) => invoke<void>("set_beat_sensitivity", { value }),
  setAutoConnect: (enabled: boolean) => invoke<void>("set_auto_connect", { enabled }),
  setMultiLight: (enabled: boolean) => invoke<void>("set_multi_light", { enabled }),
  applyPreset: (id: string) => invoke<void>("apply_preset", { id }),
  savePreset: (name: string) => invoke<void>("save_preset", { name }),
  deletePreset: (id: string) => invoke<void>("delete_preset", { id }),
  renamePreset: (id: string, name: string) => invoke<void>("rename_preset", { id, name }),
  setDefaultPreset: (id: string | null) => invoke<void>("set_default_preset", { id }),
  restoreDefaultPresets: () => invoke<void>("restore_default_presets"),
  exportPresets: () => invoke<string>("export_presets"),
  importPresets: (json: string) => invoke<void>("import_presets", { json }),
  addSchedule: (payload: {
    label: string;
    hour: number;
    minute: number;
    days: number[];
    action: string;
    useFirmwareTimer: boolean;
  }) =>
    invoke<void>("add_schedule", {
      label: payload.label,
      hour: payload.hour,
      minute: payload.minute,
      days: payload.days,
      action: payload.action,
      useFirmwareTimer: payload.useFirmwareTimer,
    }),
  toggleSchedule: (id: string, enabled: boolean) =>
    invoke<void>("toggle_schedule", { id, enabled }),
  deleteSchedule: (id: string) => invoke<void>("delete_schedule", { id }),
  refreshDisplays: () => invoke<void>("refresh_displays"),
  setDisplay: (id: number | null) => invoke<void>("set_display", { id }),
  quit: () => invoke<void>("quit_app"),
};

export async function registerShortcuts(onPower: () => void, onSync: () => void) {
  if (!isTauri()) return () => undefined;
  try {
    const { register, unregisterAll } = await import("@tauri-apps/plugin-global-shortcut");
    await unregisterAll();
    await register("CommandOrControl+Shift+L", (e) => {
      if (e.state === "Pressed") onPower();
    });
    await register("CommandOrControl+Shift+S", (e) => {
      if (e.state === "Pressed") onSync();
    });
    return () => {
      void unregisterAll();
    };
  } catch {
    return () => undefined;
  }
}

export async function setAutostart(enabled: boolean) {
  if (!isTauri()) return;
  try {
    const auto = await import("@tauri-apps/plugin-autostart");
    if (enabled) await auto.enable();
    else await auto.disable();
  } catch {
    /* plugin unavailable in browser preview */
  }
}

export async function isAutostart(): Promise<boolean> {
  if (!isTauri()) return false;
  try {
    const auto = await import("@tauri-apps/plugin-autostart");
    return await auto.isEnabled();
  } catch {
    return false;
  }
}

