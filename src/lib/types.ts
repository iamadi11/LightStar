export type ConnectionState = "disconnected" | "scanning" | "connecting" | "connected";
export type SyncMode = "off" | "video" | "audio" | "combined";
export type AudioSyncMode = "rainbow" | "pulse" | "frequency";
export type AudioInputSource = "microphone" | "stripMic";

export type Effect = { name: string; id: number };
export type EffectSection = { group: string; label: string; effects: Effect[] };

export type Preset = {
  id: string;
  name: string;
  red: number;
  green: number;
  blue: number;
  brightness: number;
};

export type ScheduledAction =
  | { type: "powerOn" }
  | { type: "powerOff" }
  | { type: "preset"; colorHue: number; colorSat: number; brightness: number };

export type Schedule = {
  id: string;
  label: string;
  hour: number;
  minute: number;
  days: number[];
  isEnabled: boolean;
  action: ScheduledAction;
  lastFiredAt: string | null;
  useFirmwareTimer: boolean;
};

export type DisplayInfo = { id: number; name: string };

export type AppSnapshot = {
  connectionState: ConnectionState;
  connectionError: string | null;
  bleNeedsPermission: boolean;
  isOn: boolean;
  hue: number;
  sat: number;
  brightness: number;
  effectId: number;
  effectSpeed: number;
  effectModeActive: boolean;
  syncMode: SyncMode;
  syncHue: number | null;
  syncSat: number | null;
  syncError: string | null;
  syncNeedsPermission: boolean;
  syncTransitioning: boolean;
  audioSyncMode: AudioSyncMode;
  audioInputSource: AudioInputSource;
  micStyle: number;
  micSensitivity: number;
  ledChannelOrder: number;
  ledPixelCount: number;
  displays: DisplayInfo[];
  selectedDisplay: number | null;
  syncResponsiveness: number;
  beatSensitivity: number;
  videoSyncBrightness: boolean;
  colorHistory: [number, number][];
  circadianEnabled: boolean;
  multiLightEnabled: boolean;
  connectedLightNames: string[];
  autoConnect: boolean;
  presets: Preset[];
  schedules: Schedule[];
  defaultPresetId: string | null;
  effects: EffectSection[];
};

export const EMPTY_STATE: AppSnapshot = {
  connectionState: "disconnected",
  connectionError: null,
  bleNeedsPermission: false,
  isOn: false,
  hue: 0.08,
  sat: 0.7,
  brightness: 1,
  effectId: 1,
  effectSpeed: 0.5,
  effectModeActive: false,
  syncMode: "off",
  syncHue: null,
  syncSat: null,
  syncError: null,
  syncNeedsPermission: false,
  syncTransitioning: false,
  audioSyncMode: "rainbow",
  audioInputSource: "microphone",
  micStyle: 1,
  micSensitivity: 0.5,
  ledChannelOrder: 1,
  ledPixelCount: 30,
  displays: [],
  selectedDisplay: null,
  syncResponsiveness: 0.7,
  beatSensitivity: 0.5,
  videoSyncBrightness: false,
  colorHistory: [],
  circadianEnabled: false,
  multiLightEnabled: false,
  connectedLightNames: [],
  autoConnect: true,
  presets: [
    { id: "reading", name: "Reading", red: 1, green: 0.95, blue: 0.8, brightness: 1 },
    { id: "movie", name: "Movie", red: 0.1, green: 0, blue: 0.3, brightness: 0.3 },
    { id: "party", name: "Party", red: 1, green: 0, blue: 0.5, brightness: 1 },
    { id: "relax", name: "Relax", red: 0.8, green: 0.4, blue: 0.1, brightness: 0.5 },
  ],
  schedules: [],
  defaultPresetId: null,
  effects: [],
};

export function hsvToCss(h: number, s: number, v = 1): string {
  const { r, g, b } = hsvToRgb(h, s, v);
  return `rgb(${Math.round(r * 255)} ${Math.round(g * 255)} ${Math.round(b * 255)})`;
}

export function hsvToRgb(h: number, s: number, v: number) {
  const hh = ((h % 1) + 1) % 1;
  const i = Math.floor(hh * 6);
  const f = hh * 6 - i;
  const p = v * (1 - s);
  const q = v * (1 - f * s);
  const t = v * (1 - (1 - f) * s);
  switch (i % 6) {
    case 0:
      return { r: v, g: t, b: p };
    case 1:
      return { r: q, g: v, b: p };
    case 2:
      return { r: p, g: v, b: t };
    case 3:
      return { r: p, g: q, b: v };
    case 4:
      return { r: t, g: p, b: v };
    default:
      return { r: v, g: p, b: q };
  }
}

export function rgbToCss(r: number, g: number, b: number) {
  return `rgb(${Math.round(r * 255)} ${Math.round(g * 255)} ${Math.round(b * 255)})`;
}
