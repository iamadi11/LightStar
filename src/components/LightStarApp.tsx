"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { api, getState, listenState, registerShortcuts, setAutostart, isAutostart } from "@/lib/api";
import {
  EMPTY_STATE,
  hsvToCss,
  rgbToCss,
  type AppSnapshot,
  type SyncMode,
} from "@/lib/types";

type Tab = "light" | "sync" | "effects" | "clock" | "setup";

export default function LightStarApp() {
  const [s, setS] = useState<AppSnapshot>(EMPTY_STATE);
  const [tab, setTab] = useState<Tab>("light");
  const [hue, setHue] = useState(0.08);
  const [sat, setSat] = useState(0.7);
  const [temp, setTemp] = useState(0.4);
  const [colorMode, setColorMode] = useState<"color" | "white">("color");
  const [presetName, setPresetName] = useState("");
  const [showSave, setShowSave] = useState(false);
  const [launchAtLogin, setLaunchAtLogin] = useState(false);
  const [animIndex, setAnimIndex] = useState(0);
  const ignoreColor = useRef(false);

  useEffect(() => {
    let unlisten: (() => void) | undefined;
    void (async () => {
      const initial = await getState();
      setS(initial);
      if (initial.sat > 0.05) {
        setHue(initial.hue);
        setSat(initial.sat);
      }
      unlisten = await listenState((next) => {
        setS(next);
        if (!ignoreColor.current && next.sat > 0.05) {
          setHue(next.hue);
          setSat(next.sat);
        }
      });
      setLaunchAtLogin(await isAutostart());
    })();
    return () => unlisten?.();
  }, []);

  useEffect(() => {
    let off: (() => void) | undefined;
    void registerShortcuts(
      () => void api.setPower(!s.isOn),
      () => {
        const next: SyncMode = s.syncMode === "off" ? "video" : "off";
        void api.setSyncMode(next);
      },
    ).then((u) => {
      off = u;
    });
    return () => off?.();
  }, [s.isOn, s.syncMode]);

  const sendColor = useCallback((h: number, sa: number) => {
    ignoreColor.current = true;
    setHue(h);
    setSat(sa);
    void api.setHue(h, sa);
    setTimeout(() => {
      ignoreColor.current = false;
    }, 120);
  }, []);

  const connected = s.connectionState === "connected";
  const preview = s.syncHue != null && s.syncSat != null
    ? hsvToCss(s.syncHue, s.syncSat)
    : hsvToCss(hue, sat);
  const animIds = useMemo(() => {
    const ids: number[] = [];
    for (let i = 0; i <= 255; i++) {
      if (i !== 0x3d && i !== 0x5b && i !== 0x96) ids.push(i);
    }
    return ids;
  }, []);

  return (
    <div
      className="shell"
      style={{
        ["--glow" as string]: preview,
      }}
    >
      <div className="glow" />
      <header className="top">
        <div className="brand">
          <span className={`orb ${s.connectionState} ${s.isOn && connected ? "on" : ""}`} />
          <div>
            <h1>LightStar</h1>
            <p className={s.connectionError ? "err" : s.connectionState}>{statusLine(s)}</p>
          </div>
        </div>
        <div className="top-actions">
          {busy(s.connectionState) ? (
            <button className="ghost" onClick={() => void api.disconnect()}>
              Cancel
            </button>
          ) : connected ? (
            <button className="ghost danger" onClick={() => void api.disconnect()}>
              Disconnect
            </button>
          ) : (
            <button className="primary" onClick={() => void api.connect()}>
              Connect
            </button>
          )}
        </div>
      </header>

      <nav className="tabs">
        {(["light", "sync", "effects", "clock", "setup"] as Tab[]).map((t) => (
          <button key={t} className={tab === t ? "active" : ""} onClick={() => setTab(t)}>
            {t}
          </button>
        ))}
      </nav>

      <main className="body">
        {!connected && tab !== "setup" ? (
          <ConnectCard s={s} />
        ) : tab === "light" ? (
          <section className="stack">
            <div className="power-row">
              <button
                className={`power ${s.isOn ? "lit" : ""}`}
                onClick={() => void api.setPower(!s.isOn)}
                aria-label="Power"
              >
                <span />
              </button>
              <div>
                <strong>{s.isOn ? "On" : "Off"}</strong>
                <p>⌘⇧L toggles power</p>
              </div>
              <div className="swatch" style={{ background: preview }} />
            </div>

            <div className="card">
              <div className="row">
                <label>Color</label>
                <div className="seg">
                  <button
                    className={colorMode === "color" ? "on" : ""}
                    onClick={() => setColorMode("color")}
                  >
                    Color
                  </button>
                  <button
                    className={colorMode === "white" ? "on" : ""}
                    onClick={() => setColorMode("white")}
                  >
                    White
                  </button>
                </div>
              </div>
              {colorMode === "color" ? (
                <>
                  <GradientSlider
                    label="Hue"
                    value={hue}
                    gradient="linear-gradient(90deg, #ff0040, #ffbf00, #00e676, #00b0ff, #7c4dff, #ff0040)"
                    onChange={(v) => sendColor(v, sat)}
                  />
                  <GradientSlider
                    label="Saturation"
                    value={sat}
                    gradient={`linear-gradient(90deg, ${hsvToCss(hue, 0)}, ${hsvToCss(hue, 1)})`}
                    onChange={(v) => sendColor(hue, v)}
                  />
                  {s.colorHistory.length > 0 && (
                    <div className="history">
                      {s.colorHistory.slice(0, 10).map(([h, sa], i) => (
                        <button
                          key={`${h}-${sa}-${i}`}
                          style={{ background: hsvToCss(h, sa) }}
                          onClick={() => sendColor(h, sa)}
                          aria-label="Recent color"
                        />
                      ))}
                    </div>
                  )}
                </>
              ) : (
                <>
                  <GradientSlider
                    label={
                      s.circadianEnabled
                        ? "Temperature · auto"
                        : `Temperature · ${Math.round(2700 + temp * 3800)}K`
                    }
                    value={temp}
                    disabled={s.circadianEnabled}
                    gradient="linear-gradient(90deg, #ffc278, #ffffff, #deeaff)"
                    onChange={(v) => {
                      setTemp(v);
                      void api.setColorTemperature(v);
                    }}
                  />
                  <label className="check">
                    <input
                      type="checkbox"
                      checked={s.circadianEnabled}
                      onChange={(e) => void api.setCircadian(e.target.checked)}
                    />
                    Circadian auto-adjust
                    <small>Warm at night · cool in the morning</small>
                  </label>
                </>
              )}
            </div>

            <div className="card">
              <label>Brightness · {Math.round(s.brightness * 100)}%</label>
              <input
                type="range"
                min={0}
                max={1}
                step={0.01}
                value={s.brightness}
                onChange={(e) => void api.setBrightness(Number(e.target.value))}
              />
            </div>

            <div className="card">
              <div className="row">
                <label>Scenes</label>
                <div className="icon-btns">
                  <button onClick={() => setShowSave(true)} title="Save current">
                    +
                  </button>
                </div>
              </div>
              <div className="presets">
                {s.presets.map((p) => (
                  <button
                    key={p.id}
                    className="preset"
                    onClick={() => void api.applyPreset(p.id)}
                    onContextMenu={(e) => {
                      e.preventDefault();
                      const name = window.prompt("Rename scene", p.name);
                      if (name) void api.renamePreset(p.id, name);
                    }}
                  >
                    <i style={{ background: rgbToCss(p.red, p.green, p.blue) }} />
                    {p.name}
                    {s.defaultPresetId === p.id ? <em>★</em> : null}
                    <span
                      className="x"
                      onClick={(e) => {
                        e.stopPropagation();
                        void api.deletePreset(p.id);
                      }}
                    >
                      ×
                    </span>
                  </button>
                ))}
              </div>
              {s.presets.length === 0 && (
                <button className="ghost" onClick={() => void api.restoreDefaultPresets()}>
                  Restore defaults
                </button>
              )}
              {showSave && (
                <form
                  className="save-row"
                  onSubmit={(e) => {
                    e.preventDefault();
                    const name = presetName.trim() || "Custom";
                    void api.savePreset(name);
                    setPresetName("");
                    setShowSave(false);
                  }}
                >
                  <input
                    autoFocus
                    placeholder="Scene name"
                    value={presetName}
                    onChange={(e) => setPresetName(e.target.value)}
                  />
                  <button className="primary" type="submit">
                    Save
                  </button>
                  <button type="button" className="ghost" onClick={() => setShowSave(false)}>
                    Cancel
                  </button>
                </form>
              )}
            </div>
          </section>
        ) : tab === "sync" ? (
          <SyncPanel s={s} />
        ) : tab === "effects" ? (
          <EffectsPanel s={s} animIds={animIds} animIndex={animIndex} setAnimIndex={setAnimIndex} />
        ) : tab === "clock" ? (
          <ClockPanel s={s} />
        ) : (
          <SetupPanel
            s={s}
            launchAtLogin={launchAtLogin}
            setLaunchAtLogin={setLaunchAtLogin}
          />
        )}
      </main>
    </div>
  );
}

function ConnectCard({ s }: { s: AppSnapshot }) {
  return (
    <div className="connect">
      {busy(s.connectionState) ? (
        <>
          <div className="spinner" />
          <p>{s.connectionState === "scanning" ? "Scanning for the bar…" : "Connecting…"}</p>
        </>
      ) : (
        <>
          <div className="empty-orb" />
          <p>{s.connectionError ?? "No light bar connected"}</p>
          <button className="primary lg" onClick={() => void api.connect()}>
            Connect to light bar
          </button>
        </>
      )}
    </div>
  );
}

function SyncPanel({ s }: { s: AppSnapshot }) {
  const modes: SyncMode[] = ["off", "video", "audio", "combined"];
  return (
    <section className="stack">
      <div className="card">
        <div className="row">
          <label>Sync</label>
          {s.syncHue != null && <i className="dot" style={{ background: hsvToCss(s.syncHue, s.syncSat ?? 1) }} />}
        </div>
        <div className="seg wrap">
          {modes.map((m) => (
            <button
              key={m}
              className={s.syncMode === m ? "on" : ""}
              disabled={s.syncTransitioning}
              onClick={() => void api.setSyncMode(m)}
            >
              {m === "combined" ? "Video+Audio" : m[0].toUpperCase() + m.slice(1)}
            </button>
          ))}
        </div>
        {s.syncError && <p className={s.syncMode === "off" ? "err" : "warn"}>{s.syncError}</p>}
        <p className="hint">{syncHint(s)}</p>
      </div>

      {s.syncMode === "audio" && (
        <div className="card">
          <label>Audio look</label>
          <div className="seg">
            {(["rainbow", "pulse", "frequency"] as const).map((m) => (
              <button
                key={m}
                className={s.audioSyncMode === m ? "on" : ""}
                onClick={() => void api.setAudioSyncMode(m)}
              >
                {m}
              </button>
            ))}
          </div>
          <label>Input</label>
          <div className="seg">
            <button
              className={s.audioInputSource === "microphone" ? "on" : ""}
              onClick={() => void api.setAudioInput("microphone")}
            >
              Microphone
            </button>
            <button
              className={s.audioInputSource === "stripMic" ? "on" : ""}
              onClick={() => void api.setAudioInput("stripMic")}
            >
              Strip mic
            </button>
          </div>
          {s.audioInputSource === "stripMic" ? (
            <>
              <label>Style</label>
              <div className="seg wrap">
                {[
                  [1, "Classic"],
                  [2, "Soft"],
                  [3, "Dynamic"],
                  [4, "Disco"],
                ].map(([id, label]) => (
                  <button
                    key={id}
                    className={s.micStyle === id ? "on" : ""}
                    onClick={() => void api.setMicStyle(Number(id))}
                  >
                    {label}
                  </button>
                ))}
              </div>
              <label>Sensitivity · {Math.round(s.micSensitivity * 100)}%</label>
              <input
                type="range"
                min={0}
                max={1}
                step={0.01}
                value={s.micSensitivity}
                onChange={(e) => void api.setMicSensitivity(Number(e.target.value))}
              />
            </>
          ) : (
            <>
              <label>Beat sensitivity · {Math.round(s.beatSensitivity * 100)}%</label>
              <input
                type="range"
                min={0}
                max={1}
                step={0.01}
                value={s.beatSensitivity}
                onChange={(e) => void api.setBeatSensitivity(Number(e.target.value))}
              />
            </>
          )}
        </div>
      )}

      {(s.syncMode === "video" || s.syncMode === "combined") && (
        <div className="card">
          <div className="row">
            <label>Display</label>
            <button className="ghost" onClick={() => void api.refreshDisplays()}>
              Refresh
            </button>
          </div>
          <select
            value={s.selectedDisplay ?? ""}
            onChange={(e) =>
              void api.setDisplay(e.target.value === "" ? null : Number(e.target.value))
            }
          >
            <option value="">Primary display</option>
            {s.displays.map((d) => (
              <option key={d.id} value={d.id}>
                {d.name}
              </option>
            ))}
          </select>
          <label>Responsiveness · {Math.round(s.syncResponsiveness * 100)}%</label>
          <input
            type="range"
            min={0.1}
            max={1}
            step={0.01}
            value={s.syncResponsiveness}
            onChange={(e) => void api.setSyncResponsiveness(Number(e.target.value))}
          />
          {s.syncMode === "video" && (
            <label className="check">
              <input
                type="checkbox"
                checked={s.videoSyncBrightness}
                onChange={(e) => void api.setVideoSyncBrightness(e.target.checked)}
              />
              Follow screen brightness
            </label>
          )}
        </div>
      )}
    </section>
  );
}

function EffectsPanel({
  s,
  animIds,
  animIndex,
  setAnimIndex,
}: {
  s: AppSnapshot;
  animIds: number[];
  animIndex: number;
  setAnimIndex: (n: number) => void;
}) {
  const current = animIds[Math.min(animIndex, animIds.length - 1)] ?? 0;
  return (
    <section className="stack">
      <div className="card">
        <div className="row">
          <label>Effects</label>
          {s.effectModeActive && (
            <button className="ghost" onClick={() => void api.exitEffectMode()}>
              Solid color
            </button>
          )}
        </div>
        {s.effects.map((sec) => (
          <div key={sec.label} className="fx-group">
            <small>{sec.label}</small>
            <div className="fx-grid">
              {sec.effects.map((fx) => (
                <button
                  key={fx.id}
                  className={s.effectModeActive && s.effectId === fx.id ? "on" : ""}
                  onClick={() => void api.setEffect(fx.id)}
                >
                  {fx.name}
                </button>
              ))}
            </div>
          </div>
        ))}
        {s.effectModeActive && (
          <>
            <label>Speed · {Math.round(s.effectSpeed * 100)}%</label>
            <input
              type="range"
              min={0}
              max={1}
              step={0.01}
              value={s.effectSpeed}
              onChange={(e) => void api.setEffectSpeed(Number(e.target.value))}
            />
          </>
        )}
      </div>
      <div className="card">
        <label>
          Animations · scene {animIndex + 1}/{animIds.length} (0x
          {current.toString(16).padStart(2, "0")})
        </label>
        <input
          type="range"
          min={0}
          max={animIds.length - 1}
          step={1}
          value={animIndex}
          onChange={(e) => {
            const i = Number(e.target.value);
            setAnimIndex(i);
            void api.setAnimation(animIds[i] ?? 0);
          }}
        />
        <div className="row wrap">
          <button
            className="ghost"
            onClick={() => {
              const i = Math.max(0, animIndex - 1);
              setAnimIndex(i);
              void api.setAnimation(animIds[i] ?? 0);
            }}
          >
            ◀
          </button>
          <button
            className="ghost"
            onClick={() => {
              const i = Math.min(animIds.length - 1, animIndex + 1);
              setAnimIndex(i);
              void api.setAnimation(animIds[i] ?? 0);
            }}
          >
            ▶
          </button>
          <button className="ghost" onClick={() => void api.setAnimation(current)}>
            Play
          </button>
          <button
            className="ghost"
            onClick={() => {
              const i = Math.floor(Math.random() * animIds.length);
              setAnimIndex(i);
              void api.setAnimation(animIds[i] ?? 0);
            }}
          >
            Random
          </button>
          <button className="ghost" onClick={() => void api.exitEffectMode()}>
            Stop
          </button>
        </div>
      </div>
    </section>
  );
}

function ClockPanel({ s }: { s: AppSnapshot }) {
  const [label, setLabel] = useState("");
  const [time, setTime] = useState("08:00");
  const [days, setDays] = useState<number[]>([2, 3, 4, 5, 6]);
  const [action, setAction] = useState("powerOn");
  const [fw, setFw] = useState(false);
  const dayLabels = [
    [1, "Su"],
    [2, "Mo"],
    [3, "Tu"],
    [4, "We"],
    [5, "Th"],
    [6, "Fr"],
    [7, "Sa"],
  ] as const;

  return (
    <section className="stack">
      <div className="card">
        <label>Schedules</label>
        {s.schedules.length === 0 && <p className="hint">Nothing yet — add a time below.</p>}
        {s.schedules.map((sch) => (
          <div key={sch.id} className="sched">
            <input
              type="checkbox"
              checked={sch.isEnabled}
              onChange={(e) => void api.toggleSchedule(sch.id, e.target.checked)}
            />
            <div>
              <strong>{sch.label}</strong>
              <small>
                {pad(sch.hour)}:{pad(sch.minute)} · {daysLabel(sch.days)}
                {sch.useFirmwareTimer ? " · firmware" : ""}
              </small>
            </div>
            <em>{actionLabel(sch.action)}</em>
            <button className="ghost" onClick={() => void api.deleteSchedule(sch.id)}>
              ×
            </button>
          </div>
        ))}
      </div>
      <form
        className="card"
        onSubmit={(e) => {
          e.preventDefault();
          const [hour, minute] = time.split(":").map(Number);
          void api.addSchedule({
            label,
            hour: hour || 0,
            minute: minute || 0,
            days,
            action,
            useFirmwareTimer: fw,
          });
          setLabel("");
        }}
      >
        <label>Add schedule</label>
        <input
          placeholder="Morning"
          value={label}
          onChange={(e) => setLabel(e.target.value)}
        />
        <input type="time" value={time} onChange={(e) => setTime(e.target.value)} />
        <div className="seg wrap">
          {dayLabels.map(([id, name]) => (
            <button
              type="button"
              key={id}
              className={days.includes(id) ? "on" : ""}
              onClick={() =>
                setDays((d) => (d.includes(id) ? d.filter((x) => x !== id) : [...d, id]))
              }
            >
              {name}
            </button>
          ))}
        </div>
        <div className="seg">
          <button type="button" className={action === "powerOn" ? "on" : ""} onClick={() => setAction("powerOn")}>
            On
          </button>
          <button type="button" className={action === "powerOff" ? "on" : ""} onClick={() => setAction("powerOff")}>
            Off
          </button>
          <button type="button" className={action === "current" ? "on" : ""} onClick={() => setAction("current")}>
            Current color
          </button>
        </div>
        <label className="check">
          <input type="checkbox" checked={fw} onChange={(e) => setFw(e.target.checked)} />
          Firmware timer (works with Mac asleep)
        </label>
        <button className="primary" type="submit" disabled={days.length === 0}>
          Add
        </button>
      </form>
    </section>
  );
}

function SetupPanel({
  s,
  launchAtLogin,
  setLaunchAtLogin,
}: {
  s: AppSnapshot;
  launchAtLogin: boolean;
  setLaunchAtLogin: (v: boolean) => void;
}) {
  return (
    <section className="stack">
      <div className="card">
        <label>Strip</label>
        <div className="row">
          <span>Channel order</span>
          <select
            value={s.ledChannelOrder}
            onChange={(e) => void api.setChannelOrder(Number(e.target.value))}
          >
            <option value={1}>RGB</option>
            <option value={2}>RBG</option>
            <option value={3}>GRB</option>
            <option value={4}>GBR</option>
            <option value={5}>BRG</option>
            <option value={6}>BGR</option>
          </select>
        </div>
        <div className="row">
          <span>LED count</span>
          <input
            type="number"
            min={8}
            max={300}
            value={s.ledPixelCount}
            onChange={(e) => void api.setPixelCount(Number(e.target.value))}
          />
        </div>
      </div>
      <div className="card">
        <label>App</label>
        <label className="check">
          <input
            type="checkbox"
            checked={launchAtLogin}
            onChange={(e) => {
              setLaunchAtLogin(e.target.checked);
              void setAutostart(e.target.checked);
            }}
          />
          Launch at login
        </label>
        <label className="check">
          <input
            type="checkbox"
            checked={s.autoConnect}
            onChange={(e) => void api.setAutoConnect(e.target.checked)}
          />
          Auto-connect on launch
        </label>
        <label className="check">
          <input
            type="checkbox"
            checked={s.multiLightEnabled}
            onChange={(e) => void api.setMultiLight(e.target.checked)}
          />
          Multi-light (connect all nearby bars)
        </label>
        {s.connectedLightNames.length > 0 && (
          <p className="hint">{s.connectedLightNames.join(", ")}</p>
        )}
      </div>
      <div className="card">
        <label>Scenes file</label>
        <div className="row wrap">
          <button
            className="ghost"
            onClick={async () => {
              const json = await api.exportPresets();
              const blob = new Blob([json], { type: "application/json" });
              const a = document.createElement("a");
              a.href = URL.createObjectURL(blob);
              a.download = "LightStar Presets.json";
              a.click();
            }}
          >
            Export JSON
          </button>
          <label className="ghost file">
            Import JSON
            <input
              type="file"
              accept="application/json"
              hidden
              onChange={async (e) => {
                const file = e.target.files?.[0];
                if (!file) return;
                void api.importPresets(await file.text());
                e.target.value = "";
              }}
            />
          </label>
        </div>
      </div>
      <button className="danger-block" onClick={() => void api.quit()}>
        Quit LightStar
      </button>
    </section>
  );
}

function GradientSlider({
  label,
  value,
  gradient,
  onChange,
  disabled,
}: {
  label: string;
  value: number;
  gradient: string;
  onChange: (v: number) => void;
  disabled?: boolean;
}) {
  const ref = useRef<HTMLDivElement>(null);
  function at(clientX: number) {
    const el = ref.current;
    if (!el) return;
    const r = el.getBoundingClientRect();
    onChange(Math.min(1, Math.max(0, (clientX - r.left) / r.width)));
  }
  return (
    <div className={`gslide ${disabled ? "off" : ""}`}>
      <small>{label}</small>
      <div
        ref={ref}
        className="track"
        style={{ background: gradient }}
        onPointerDown={(e) => {
          if (disabled) return;
          (e.target as HTMLElement).setPointerCapture(e.pointerId);
          at(e.clientX);
        }}
        onPointerMove={(e) => {
          if (disabled || e.buttons === 0) return;
          at(e.clientX);
        }}
      >
        <span style={{ left: `${value * 100}%` }} />
      </div>
    </div>
  );
}

function statusLine(s: AppSnapshot) {
  if (s.connectionError) return s.connectionError;
  switch (s.connectionState) {
    case "connected":
      return s.isOn ? "Connected · On" : "Connected · Off";
    case "scanning":
      return "Scanning for device…";
    case "connecting":
      return "Connecting…";
    default:
      return "Not connected";
  }
}

function busy(c: AppSnapshot["connectionState"]) {
  return c === "scanning" || c === "connecting";
}

function syncHint(s: AppSnapshot) {
  switch (s.syncMode) {
    case "off":
      return "No sync — color picker and scenes are active";
    case "video":
      return s.videoSyncBrightness
        ? "Edges weighted 3× · screen brightness → strip · ~20 Hz"
        : "Edges weighted 3× · brightness stays at slider · ~20 Hz";
    case "audio":
      if (s.audioInputSource === "stripMic") {
        return "Strip's onboard mic · style + sensitivity above";
      }
      if (s.audioSyncMode === "pulse") return "Bass → brightness · keeps current color";
      if (s.audioSyncMode === "frequency") return "Bass → red · mid → green · treble → blue";
      return "Beats → hue · treble → drift · bass → brightness";
    case "combined":
      return "Screen → color · audio beats → brightness";
  }
}

function pad(n: number) {
  return n.toString().padStart(2, "0");
}

function daysLabel(days: number[]) {
  const set = new Set(days);
  if (set.size === 7) return "Every day";
  const weekdays = [2, 3, 4, 5, 6];
  if (weekdays.every((d) => set.has(d)) && set.size === 5) return "Weekdays";
  if (set.size === 2 && set.has(1) && set.has(7)) return "Weekends";
  const names = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"];
  return [...set].sort().map((d) => names[d - 1]).join(",");
}

function actionLabel(action: AppSnapshot["schedules"][number]["action"]) {
  if (action.type === "powerOn") return "On";
  if (action.type === "powerOff") return "Off";
  return "Scene";
}
