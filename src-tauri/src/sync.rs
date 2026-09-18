use crate::persist::DisplayInfo;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::Sample;
use rustfft::num_complex::Complex;
use rustfft::FftPlanner;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::mpsc;
use xcap::Monitor;

#[derive(Debug, Clone, Copy)]
pub struct FrequencyBands {
    pub bass: f64,
    pub mid: f64,
    pub high: f64,
    pub rms: f64,
    pub flux: f64,
}

pub fn list_displays() -> Vec<DisplayInfo> {
    match Monitor::all() {
        Ok(monitors) => monitors
            .into_iter()
            .enumerate()
            .map(|(i, m)| DisplayInfo {
                id: m.id(),
                name: {
                    let n = m.name();
                    if n.is_empty() {
                        format!("Display {}", i + 1)
                    } else {
                        n.to_string()
                    }
                },
            })
            .collect(),
        Err(err) => {
            log::warn!("list displays: {err}");
            vec![]
        }
    }
}

pub fn sample_screen(selected: Option<u32>) -> Result<(f64, f64, f64), String> {
    let monitors = Monitor::all().map_err(|e| e.to_string())?;
    let monitor = if let Some(id) = selected {
        monitors
            .iter()
            .find(|m| m.id() == id)
            .or_else(|| monitors.first())
    } else {
        monitors.first()
    };
    let Some(monitor) = monitor else {
        return Err("No display found".into());
    };
    let image = monitor.capture_image().map_err(|e| {
        let msg = e.to_string();
        if msg.to_lowercase().contains("permission") || msg.to_lowercase().contains("denied") {
            format!("Screen Recording permission required ({msg})")
        } else {
            msg
        }
    })?;
    // Downsample to ~48×27 like the Swift SCStream config.
    let w = image.width() as usize;
    let h = image.height() as usize;
    if w == 0 || h == 0 {
        return Ok((0.0, 0.0, 0.0));
    }
    let tw = 48usize;
    let th = 27usize;
    let mut pixels = Vec::with_capacity(tw * th);
    for row in 0..th {
        for col in 0..tw {
            let sx = col * w / tw;
            let sy = row * h / th;
            let px = image.get_pixel(sx as u32, sy as u32);
            pixels.push((
                px[0] as f64 / 255.0,
                px[1] as f64 / 255.0,
                px[2] as f64 / 255.0,
            ));
        }
    }
    Ok(lightstar_core::ColorMath::dominant_hsv(&pixels, tw, th))
}

pub struct MicStop {
    running: Arc<AtomicBool>,
}

impl Drop for MicStop {
    fn drop(&mut self) {
        self.running.store(false, Ordering::SeqCst);
    }
}

pub fn start_mic(tx: mpsc::UnboundedSender<FrequencyBands>) -> Result<MicStop, String> {
    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .ok_or_else(|| "Microphone access required (no input device)".to_string())?;
    let config = device
        .default_input_config()
        .map_err(|e| format!("Microphone access required ({e})"))?;
    let sample_rate = config.sample_rate().0 as f64;
    let channels = config.channels() as usize;
    let running = Arc::new(AtomicBool::new(true));
    let sample_format = config.sample_format();
    let stream_config: cpal::StreamConfig = config.into();
    let stream = match sample_format {
        cpal::SampleFormat::F32 => build_stream::<f32>(
            &device,
            &stream_config,
            channels,
            sample_rate,
            tx.clone(),
            running.clone(),
            mic_err,
        )?,
        cpal::SampleFormat::I16 => build_stream::<i16>(
            &device,
            &stream_config,
            channels,
            sample_rate,
            tx.clone(),
            running.clone(),
            mic_err,
        )?,
        cpal::SampleFormat::U16 => build_stream::<u16>(
            &device,
            &stream_config,
            channels,
            sample_rate,
            tx.clone(),
            running.clone(),
            mic_err,
        )?,
        other => return Err(format!("unsupported mic format {other}")),
    };
    stream.play().map_err(|e| e.to_string())?;
    // Leak the stream so it outlives this function; MicStop drops the flag.
    std::mem::forget(stream);
    Ok(MicStop { running })
}

fn mic_err(err: cpal::StreamError) {
    log::warn!("mic stream: {err}");
}

fn build_stream<T>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    channels: usize,
    sample_rate: f64,
    tx: mpsc::UnboundedSender<FrequencyBands>,
    running: Arc<AtomicBool>,
    err_fn: impl Fn(cpal::StreamError) + Send + 'static,
) -> Result<cpal::Stream, String>
where
    T: cpal::SizedSample + Send + 'static,
    f32: cpal::FromSample<T>,
{
    let mut acc: Vec<f32> = Vec::new();
    let mut analyzer = Analyzer::new();
    device
        .build_input_stream(
            config,
            move |data: &[T], _| {
                if !running.load(Ordering::SeqCst) {
                    return;
                }
                let frames = data.len() / channels.max(1);
                for i in 0..frames {
                    let mut mix = 0.0f32;
                    for ch in 0..channels.max(1) {
                        mix += f32::from_sample(data[i * channels.max(1) + ch]);
                    }
                    acc.push(mix / channels.max(1) as f32);
                }
                const N: usize = 512;
                while acc.len() >= N {
                    let window: Vec<f32> = acc.drain(..N).collect();
                    let bands = analyzer.analyze(&window, sample_rate);
                    let _ = tx.send(bands);
                }
            },
            err_fn,
            None,
        )
        .map_err(|e| e.to_string())
}

struct Analyzer {
    planner: FftPlanner<f32>,
    prev_mags: Vec<f32>,
    max_bass: f64,
    max_mid: f64,
    max_high: f64,
    max_flux: f64,
}

impl Analyzer {
    fn new() -> Self {
        Self {
            planner: FftPlanner::new(),
            prev_mags: vec![],
            max_bass: 0.001,
            max_mid: 0.001,
            max_high: 0.001,
            max_flux: 0.001,
        }
    }

    fn analyze(&mut self, samples: &[f32], sample_rate: f64) -> FrequencyBands {
        let n = samples.len();
        let mut sumsq = 0.0f32;
        for s in samples {
            sumsq += s * s;
        }
        let rms_raw = (sumsq / n as f32).sqrt();
        let rms = (rms_raw as f64 * 20.0).min(1.0);

        // Hann window
        let mut buf: Vec<Complex<f32>> = samples
            .iter()
            .enumerate()
            .map(|(i, s)| {
                let w = 0.5 - 0.5 * (2.0 * std::f32::consts::PI * i as f32 / n as f32).cos();
                Complex::new(s * w, 0.0)
            })
            .collect();
        let fft = self.planner.plan_fft_forward(n);
        fft.process(&mut buf);

        let half = n / 2;
        let scale = 1.0 / n as f32;
        let mags: Vec<f32> = buf[..half].iter().map(|c| c.norm() * scale).collect();

        let bin_hz = sample_rate / n as f64;
        let raw_bass = band_rms(&mags, 20.0, 200.0, bin_hz);
        let raw_mid = band_rms(&mags, 200.0, 2000.0, bin_hz);
        let raw_high = band_rms(&mags, 2000.0, 8000.0, bin_hz);

        self.max_bass = (self.max_bass * 0.995).max(raw_bass + 1e-9);
        self.max_mid = (self.max_mid * 0.995).max(raw_mid + 1e-9);
        self.max_high = (self.max_high * 0.995).max(raw_high + 1e-9);

        let mut flux = 0.0;
        if self.prev_mags.len() == half {
            for i in 0..half {
                let d = mags[i] as f64 - self.prev_mags[i] as f64;
                if d > 0.0 {
                    flux += d;
                }
            }
        }
        self.prev_mags = mags;
        self.max_flux = (self.max_flux * 0.99).max(flux + 1e-9);

        FrequencyBands {
            bass: (raw_bass / self.max_bass).min(1.0),
            mid: (raw_mid / self.max_mid).min(1.0),
            high: (raw_high / self.max_high).min(1.0),
            rms,
            flux: (flux / self.max_flux).min(1.0),
        }
    }
}

fn band_rms(mags: &[f32], lo: f64, hi: f64, bin_hz: f64) -> f64 {
    let lo_idx = ((lo / bin_hz) as usize).max(1);
    let hi_idx = ((hi / bin_hz) as usize).min(mags.len().saturating_sub(1));
    if lo_idx > hi_idx {
        return 0.0;
    }
    let slice = &mags[lo_idx..=hi_idx];
    let mut sum = 0.0f32;
    for v in slice {
        sum += v * v;
    }
    (sum / slice.len() as f32).sqrt() as f64
}
