import Foundation

// Coalesces BLE writes: keyed by command sub-byte (bytes[1]), latest value wins.
// Insertion-ordered array with replace-in-place so apply(_:) write order is preserved.
// Drains one entry per 20ms tick so the ATT stack always has headroom.
@MainActor
public final class BLEWriteCoalescer {
    private struct Item {
        var cmd: UInt8
        var data: Data
    }

    private var items: [Item] = []
    /// Bumped when pending frames are discarded (flush / power-off). In-flight
    /// timer Tasks must not send a hue/brightness they already `removeFirst`'d.
    private var drainGeneration: UInt64 = 0
    // nonisolated(unsafe): Timer is only created/invalidated on the main actor;
    // deinit must be able to invalidate it under Swift 6 isolation rules.
    nonisolated(unsafe) private var timer: Timer?
    private let send: @MainActor (Data) -> Void
    private let isConnected: @MainActor () -> Bool

    public init(send: @escaping @MainActor (Data) -> Void,
         isConnected: @escaping @MainActor () -> Bool) {
        self.send = send
        self.isConnected = isConnected
    }

    deinit { timer?.invalidate() }

    public func enqueue(_ bytes: [UInt8]) {
        guard isConnected(), bytes.count >= 2 else { return }
        // Hue/brightness after BC01-off wakes the strip. Power-off must be the
        // only remaining frame, and stale drain Tasks must not send what they
        // already popped.
        if StripPowerWritePolicy.isPowerOffFrame(bytes) {
            drainGeneration &+= 1
            items.removeAll()
        }
        let cmd = bytes[1]
        let data = Data(bytes)
        if let idx = items.firstIndex(where: { $0.cmd == cmd }) {
            items[idx].data = data
        } else {
            items.append(Item(cmd: cmd, data: data))
        }
        guard timer == nil else { return }
        startTimer()
    }

    private func startTimer() {
        let t = Timer(timeInterval: 0.020, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let gen = self.drainGeneration
                guard self.isConnected() else { self.flush(); return }
                guard !self.items.isEmpty else {
                    self.timer?.invalidate(); self.timer = nil; return
                }
                let item = self.items.removeFirst()
                guard gen == self.drainGeneration else { return }
                self.send(item.data)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func flush() {
        drainGeneration &+= 1
        timer?.invalidate()
        timer = nil
        items.removeAll()
    }

    /// Drop the queue and send this frame now. Power on/off must not wait for
    /// the 20ms drain — a with-response backlog never delivers that tick.
    public func sendNow(_ bytes: [UInt8]) {
        guard isConnected(), bytes.count >= 2 else { return }
        drainGeneration &+= 1
        items.removeAll()
        timer?.invalidate()
        timer = nil
        send(Data(bytes))
    }

    /// Synchronous drain for tests — does not send, returns remaining frames in order.
    public func drainOrderedForTesting() -> [Data] {
        let out = items.map(\.data)
        items.removeAll()
        timer?.invalidate()
        timer = nil
        return out
    }
}
