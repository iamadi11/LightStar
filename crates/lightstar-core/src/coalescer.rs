//! Coalesces BLE writes: keyed by command sub-byte (`bytes[1]`), latest value wins.
//! Insertion-ordered with replace-in-place so drain order is preserved.
//! The 20 ms tick lives in the Tauri host; this type is the queue itself.

#[derive(Default)]
pub struct WriteCoalescer {
    items: Vec<(u8, Vec<u8>)>,
}

impl WriteCoalescer {
    pub fn new() -> Self {
        Self { items: Vec::new() }
    }

    pub fn enqueue(&mut self, bytes: &[u8]) {
        if bytes.len() < 2 {
            return;
        }
        let cmd = bytes[1];
        if let Some(existing) = self.items.iter_mut().find(|(c, _)| *c == cmd) {
            existing.1 = bytes.to_vec();
        } else {
            self.items.push((cmd, bytes.to_vec()));
        }
    }

    pub fn pop(&mut self) -> Option<Vec<u8>> {
        if self.items.is_empty() {
            None
        } else {
            Some(self.items.remove(0).1)
        }
    }

    pub fn flush(&mut self) {
        self.items.clear();
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    /// Synchronous drain for tests — does not send.
    pub fn drain(&mut self) -> Vec<Vec<u8>> {
        let out: Vec<Vec<u8>> = self.items.drain(..).map(|(_, d)| d).collect();
        out
    }
}
