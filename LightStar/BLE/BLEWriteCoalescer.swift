import Foundation

// Coalesces BLE writes: keyed by command sub-byte (bytes[1]), latest value wins.
// Drains one entry per 20ms tick so the ATT stack always has headroom.
@MainActor final class BLEWriteCoalescer {
    private var queue: [UInt8: Data] = [:]
    nonisolated(unsafe) private var timer: Timer?
    private let send: @MainActor (Data) -> Void
    private let isConnected: @MainActor () -> Bool

    init(send: @escaping @MainActor (Data) -> Void,
         isConnected: @escaping @MainActor () -> Bool) {
        self.send = send
        self.isConnected = isConnected
    }

    deinit { timer?.invalidate() }

    func enqueue(_ bytes: [UInt8]) {
        guard isConnected(), bytes.count >= 2 else { return }
        queue[bytes[1]] = Data(bytes)
        guard timer == nil else { return }
        startTimer()
    }

    private func startTimer() {
        let t = Timer(timeInterval: 0.020, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isConnected() else { self.flush(); return }
                guard let (cmd, data) = self.queue.first else {
                    // Queue drained — stop timer; don't clear queue (flush does that on disconnect)
                    self.timer?.invalidate(); self.timer = nil; return
                }
                self.queue.removeValue(forKey: cmd)
                self.send(data)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func flush() {
        timer?.invalidate()
        timer = nil
        queue.removeAll()
    }
}
