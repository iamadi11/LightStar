//! Hue LUT, CCT synthesis, circadian curve, RGB↔HSV.
//! Hand-calibrated 2026-08-23; purple/magenta (305–360°) recalibrated 2026-08-24.

use chrono::{DateTime, Datelike, Timelike};

pub struct ColorMath;

impl ColorMath {
    /// `(observed_degrees, send_degrees)` — `obs` is strictly non-decreasing.
    pub const HUE_LUT: &'static [(f64, f64)] = &[
        (0.0, 0.0),
        (8.0, 0.0),
        (20.0, 10.0),
        (32.0, 20.0),
        (41.0, 30.0),
        (60.0, 40.0),
        (89.0, 50.0),
        (109.0, 60.0),
        (123.0, 70.0),
        (135.0, 80.0),
        (145.0, 90.0),
        (149.0, 120.0),
        (173.0, 130.0),
        (188.0, 140.0),
        (198.0, 150.0),
        (203.0, 160.0),
        (206.0, 170.0),
        (209.0, 180.0),
        (212.0, 190.0),
        (215.0, 200.0),
        (217.0, 210.0),
        (220.0, 220.0),
        (222.0, 230.0),
        (226.0, 240.0),
        (229.0, 250.0),
        (239.0, 260.0),
        (247.0, 270.0),
        (252.0, 280.0),
        (255.0, 290.0),
        (259.0, 300.0),
        (264.0, 310.0),
        (269.0, 320.0),
        (276.0, 330.0),
        (286.0, 340.0),
        (305.0, 351.0),
        (310.0, 353.0),
        (320.0, 355.0),
        (330.0, 357.0),
        (340.0, 358.0),
        (360.0, 360.0),
    ];

    /// `h` is 0–1. Returns the LUT-corrected hue in degrees 0–360.
    pub fn corrected_hue_deg(h: f64) -> f64 {
        let mut deg = (h * 360.0) % 360.0;
        if deg < 0.0 {
            deg += 360.0;
        }
        let lut = Self::HUE_LUT;
        for i in 0..lut.len() - 1 {
            let (lo_obs, lo_send) = lut[i];
            let (hi_obs, hi_send) = lut[i + 1];
            if deg >= lo_obs && deg <= hi_obs {
                let t = if (hi_obs - lo_obs) < 0.001 {
                    0.0
                } else {
                    (deg - lo_obs) / (hi_obs - lo_obs)
                };
                return lo_send + t * (hi_send - lo_send);
            }
        }
        deg
    }

    /// Kelvin → (hue 0–1, saturation 0–1).
    pub fn kelvin_to_hs(k: f64) -> (f64, f64) {
        if k < 3350.0 {
            let t = (k - 2700.0) / 650.0;
            (0.08 - t * 0.02, 0.8 - t * 0.5)
        } else if k < 5000.0 {
            let t = (k - 3350.0) / 1650.0;
            (0.06 - t * 0.06, 0.3 - t * 0.3)
        } else {
            let t = ((k - 5000.0) / 1500.0).min(1.0);
            (0.55 + t * 0.08, t * 0.25)
        }
    }

    /// 0 = 2700K warm, 1 = 6500K cool.
    pub fn circadian_cct_value<Tz: chrono::TimeZone>(date: DateTime<Tz>) -> f64 {
        let t = date.hour() as f64 + date.minute() as f64 / 60.0;
        if (6.0..12.0).contains(&t) {
            (t - 6.0) / 6.0
        } else if (12.0..17.0).contains(&t) {
            1.0
        } else if (17.0..22.0).contains(&t) {
            1.0 - (t - 17.0) / 5.0
        } else {
            0.0
        }
    }

    pub fn circadian_now() -> f64 {
        Self::circadian_cct_value(chrono::Local::now())
    }

    pub fn rgb_to_hsv(r: f64, g: f64, b: f64) -> (f64, f64, f64) {
        let mx = r.max(g).max(b);
        let mn = r.min(g).min(b);
        let d = mx - mn;
        let s = if mx < 1e-6 { 0.0 } else { d / mx };
        let mut h = 0.0;
        if d > 1e-6 {
            if (mx - r).abs() < 1e-12 {
                h = (g - b) / d;
            } else if (mx - g).abs() < 1e-12 {
                h = 2.0 + (b - r) / d;
            } else {
                h = 4.0 + (r - g) / d;
            }
            h = (h / 6.0) % 1.0;
            if h < 0.0 {
                h += 1.0;
            }
        }
        (h, s, mx)
    }

    pub fn hsv_to_rgb(h: f64, s: f64, v: f64) -> (f64, f64, f64) {
        let h = ((h % 1.0) + 1.0) % 1.0;
        let i = (h * 6.0).floor();
        let f = h * 6.0 - i;
        let p = v * (1.0 - s);
        let q = v * (1.0 - f * s);
        let t = v * (1.0 - (1.0 - f) * s);
        match (i as i32) % 6 {
            0 => (v, t, p),
            1 => (q, v, p),
            2 => (p, v, t),
            3 => (p, q, v),
            4 => (t, p, v),
            _ => (v, p, q),
        }
    }

    /// Dominant color via hue histogram on edge-weighted pixels.
    /// Ignores dark (v < 0.12) and desaturated (s < 0.15) pixels.
    pub fn dominant_hsv(pixels: &[(f64, f64, f64)], width: usize, height: usize) -> (f64, f64, f64) {
        const BINS: usize = 36;
        let mut histogram = [0.0f64; BINS];
        let mut bin_sat = [0.0f64; BINS];
        let mut bin_val = [0.0f64; BINS];
        let mut bin_count = [0i32; BINS];
        let mut total_v = 0.0;
        let mut pix_count = 0;

        for row in 0..height {
            for col in 0..width {
                let idx = row * width + col;
                if idx >= pixels.len() {
                    continue;
                }
                let is_edge = row == 0 || row == height.saturating_sub(1) || col == 0 || col == width.saturating_sub(1);
                let wt = if is_edge { 3.0 } else { 1.0 };
                let (r, g, b) = pixels[idx];
                let (hh, ss, vv) = Self::rgb_to_hsv(r, g, b);
                total_v += vv * wt;
                pix_count += 1;
                if vv <= 0.12 || ss <= 0.15 {
                    continue;
                }
                let bin = ((hh * BINS as f64) as usize).min(BINS - 1);
                histogram[bin] += wt * ss * vv;
                bin_sat[bin] += ss;
                bin_val[bin] += vv;
                bin_count[bin] += 1;
            }
        }

        let mut max_bin = 0;
        let mut max_w = 0.0;
        for i in 0..BINS {
            if histogram[i] > max_w {
                max_w = histogram[i];
                max_bin = i;
            }
        }
        if max_w > 0.0 && bin_count[max_bin] > 0 {
            let h = (max_bin as f64 + 0.5) / BINS as f64;
            let n = bin_count[max_bin] as f64;
            return (h, (bin_sat[max_bin] / n).min(1.0), (bin_val[max_bin] / n).min(1.0));
        }
        let avg_v = if pix_count > 0 {
            total_v / pix_count as f64
        } else {
            0.0
        };
        (0.0, 0.0, avg_v)
    }
}

/// Local weekday matching Foundation Calendar: 1=Sun … 7=Sat.
pub fn calendar_weekday(date: DateTime<chrono::Local>) -> u32 {
    date.weekday().number_from_sunday()
}

/// OEM bitmask: bit0=Mon … bit6=Sun. Calendar weekday 1=Sun,2=Mon,…,7=Sat.
pub fn oem_weekday_mask_now() -> u8 {
    let wd = calendar_weekday(chrono::Local::now());
    1u8 << ((wd + 5) % 7)
}
