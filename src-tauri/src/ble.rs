use btleplug::api::{
    bleuuid::uuid_from_u16, Central, CentralEvent, Manager as _, Peripheral as _, ScanFilter,
    WriteType,
};
use btleplug::platform::{Adapter, Manager, Peripheral};
use futures::StreamExt;
use std::time::Duration;
use tokio::sync::mpsc;
use uuid::Uuid;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const SCAN_TIMEOUT: Duration = Duration::from_secs(10);

pub fn advertised_uuid() -> Uuid {
    uuid_from_u16(0x2022)
}
pub fn write_uuid() -> Uuid {
    uuid_from_u16(0xFFF3)
}
pub fn notify_uuid() -> Uuid {
    uuid_from_u16(0xFFF4)
}

#[derive(Debug)]
pub enum BleMsg {
    Connect { multi: bool },
    Disconnect,
    Write(Vec<u8>),
    SetMulti(bool),
}

#[derive(Debug, Clone)]
pub enum BleEvent {
    Scanning,
    Connecting { name: String },
    Connected { names: Vec<String> },
    Disconnected { reason: Option<String> },
    NotFound,
    PermissionDenied { message: String },
    AdapterOff,
    WriteFailed { message: String },
    TimedOut,
}

struct Light {
    peripheral: Peripheral,
    write: Option<btleplug::api::Characteristic>,
    name: String,
}

pub fn spawn(tx_events: mpsc::UnboundedSender<BleEvent>) -> mpsc::UnboundedSender<BleMsg> {
    let (tx, rx) = mpsc::unbounded_channel();
    tauri::async_runtime::spawn(actor(rx, tx_events));
    tx
}

async fn actor(mut rx: mpsc::UnboundedReceiver<BleMsg>, events: mpsc::UnboundedSender<BleEvent>) {
    let mut session = Session {
        events,
        adapter: None,
        primary: None,
        extras: Vec::new(),
        multi: false,
        user_disconnect: false,
    };
    while let Some(msg) = rx.recv().await {
        match msg {
            BleMsg::Connect { multi } => {
                session.multi = multi;
                session.user_disconnect = false;
                if let Err(err) = session.connect().await {
                    log::warn!("connect failed: {err}");
                    let _ = session.events.send(classify_error(&err));
                }
            }
            BleMsg::Disconnect => {
                session.user_disconnect = true;
                session.disconnect_all().await;
                let _ = session.events.send(BleEvent::Disconnected { reason: None });
            }
            BleMsg::Write(bytes) => {
                session.write(&bytes).await;
            }
            BleMsg::SetMulti(multi) => {
                session.multi = multi;
                if !multi {
                    for extra in session.extras.drain(..) {
                        let _ = extra.peripheral.disconnect().await;
                    }
                }
            }
        }
    }
}

fn classify_error(err: &anyhow::Error) -> BleEvent {
    let msg = err.to_string().to_lowercase();
    if msg.contains("permission") || msg.contains("unauthorized") || msg.contains("not authorized")
    {
        BleEvent::PermissionDenied {
            message: "Bluetooth access denied. Enable LightStar in Privacy & Security → Bluetooth."
                .into(),
        }
    } else if msg.contains("powered off") || msg.contains("not available") {
        BleEvent::AdapterOff
    } else {
        BleEvent::Disconnected {
            reason: Some(err.to_string()),
        }
    }
}

struct Session {
    events: mpsc::UnboundedSender<BleEvent>,
    adapter: Option<Adapter>,
    primary: Option<Light>,
    extras: Vec<Light>,
    multi: bool,
    user_disconnect: bool,
}

impl Session {
    async fn adapter(&mut self) -> anyhow::Result<&Adapter> {
        if self.adapter.is_none() {
            let manager = Manager::new().await?;
            let adapters = manager.adapters().await?;
            let adapter = adapters
                .into_iter()
                .next()
                .ok_or_else(|| anyhow::anyhow!("No Bluetooth adapter available"))?;
            self.adapter = Some(adapter);
        }
        Ok(self.adapter.as_ref().unwrap())
    }

    async fn connect(&mut self) -> anyhow::Result<()> {
        let _ = self.events.send(BleEvent::Scanning);
        let advertised = advertised_uuid();
        {
            let adapter = self.adapter().await?;
            adapter
                .start_scan(ScanFilter {
                    services: vec![advertised],
                })
                .await?;
        }

        let found = self.wait_for_device(SCAN_TIMEOUT).await;
        if let Some(adapter) = &self.adapter {
            let _ = adapter.stop_scan().await;
        }

        let Some(peripheral) = found else {
            let _ = self.events.send(BleEvent::NotFound);
            return Ok(());
        };

        self.handshake_primary(peripheral).await
    }

    async fn wait_for_device(&mut self, timeout: Duration) -> Option<Peripheral> {
        let adapter = self.adapter.as_ref()?;
        let mut events = match adapter.events().await {
            Ok(s) => s,
            Err(err) => {
                log::warn!("adapter events: {err}");
                return None;
            }
        };
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let remain = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remain.is_zero() {
                return None;
            }
            match tokio::time::timeout(remain, events.next()).await {
                Ok(Some(CentralEvent::DeviceDiscovered(id)))
                | Ok(Some(CentralEvent::DeviceUpdated(id))) => {
                    if let Ok(p) = adapter.peripheral(&id).await {
                        if let Ok(Some(props)) = p.properties().await {
                            let has = props.services.iter().any(|u| *u == advertised_uuid())
                                || props.local_name.as_deref().is_some();
                            if has {
                                return Some(p);
                            }
                        } else {
                            return Some(p);
                        }
                    }
                }
                Ok(None) => return None,
                Ok(Some(_)) => {}
                Err(_) => return None,
            }
        }
    }

    async fn handshake_primary(&mut self, peripheral: Peripheral) -> anyhow::Result<()> {
        let name = peripheral
            .properties()
            .await
            .ok()
            .flatten()
            .and_then(|p| p.local_name)
            .unwrap_or_else(|| "GATT--DEMO".into());
        let _ = self.events.send(BleEvent::Connecting { name: name.clone() });

        match tokio::time::timeout(CONNECT_TIMEOUT, peripheral.connect()).await {
            Ok(Ok(())) => {}
            Ok(Err(err)) => return Err(err.into()),
            Err(_) => {
                let _ = peripheral.disconnect().await;
                let _ = self.events.send(BleEvent::TimedOut);
                return Ok(());
            }
        }

        peripheral.discover_services().await?;
        let write = find_write(&peripheral);
        if write.is_none() {
            anyhow::bail!("FFF3 write characteristic not found");
        }
        if let Some(notify) = find_notify(&peripheral) {
            let _ = peripheral.subscribe(&notify).await;
        }

        let light = Light {
            peripheral,
            write,
            name: name.clone(),
        };
        self.primary = Some(light);

        if self.multi {
            self.collect_extras().await;
        }

        let names = self.names();
        let _ = self.events.send(BleEvent::Connected { names });
        Ok(())
    }

    async fn collect_extras(&mut self) {
        let Some(adapter) = &self.adapter else {
            return;
        };
        let Ok(peripherals) = adapter.peripherals().await else {
            return;
        };
        let primary_id = self.primary.as_ref().map(|p| p.peripheral.id());
        for p in peripherals {
            if Some(p.id()) == primary_id {
                continue;
            }
            if self.extras.iter().any(|e| e.peripheral.id() == p.id()) {
                continue;
            }
            if p.connect().await.is_err() {
                continue;
            }
            let _ = p.discover_services().await;
            let write = find_write(&p);
            if write.is_none() {
                let _ = p.disconnect().await;
                continue;
            }
            let name = p
                .properties()
                .await
                .ok()
                .flatten()
                .and_then(|pr| pr.local_name)
                .unwrap_or_else(|| "extra".into());
            self.extras.push(Light {
                peripheral: p,
                write,
                name,
            });
        }
    }

    fn names(&self) -> Vec<String> {
        let mut n = Vec::new();
        if let Some(p) = &self.primary {
            n.push(p.name.clone());
        }
        n.extend(self.extras.iter().map(|e| e.name.clone()));
        n
    }

    async fn write(&mut self, bytes: &[u8]) {
        let mut failed = None;
        if let Some(light) = &self.primary {
            if let Some(ch) = &light.write {
                if let Err(err) = light
                    .peripheral
                    .write(ch, bytes, WriteType::WithResponse)
                    .await
                {
                    failed = Some(err.to_string());
                }
            }
        }
        for extra in &self.extras {
            if let Some(ch) = &extra.write {
                let _ = extra
                    .peripheral
                    .write(ch, bytes, WriteType::WithResponse)
                    .await;
            }
        }
        if let Some(message) = failed {
            let _ = self.events.send(BleEvent::WriteFailed { message });
        }
    }

    async fn disconnect_all(&mut self) {
        if let Some(p) = self.primary.take() {
            let _ = p.peripheral.disconnect().await;
        }
        for extra in self.extras.drain(..) {
            let _ = extra.peripheral.disconnect().await;
        }
        if let Some(adapter) = &self.adapter {
            let _ = adapter.stop_scan().await;
        }
    }
}

fn find_write(p: &Peripheral) -> Option<btleplug::api::Characteristic> {
    p.characteristics()
        .into_iter()
        .find(|c| c.uuid == write_uuid())
}

fn find_notify(p: &Peripheral) -> Option<btleplug::api::Characteristic> {
    p.characteristics()
        .into_iter()
        .find(|c| c.uuid == notify_uuid())
}
