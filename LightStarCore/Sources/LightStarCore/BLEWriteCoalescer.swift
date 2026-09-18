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
                guard self.isConnected() else { self.flush(); return }
                guard !self.items.isEmpty else {
                    self.timer?.invalidate(); self.timer = nil; return
                }
                let item = self.items.removeFirst()
                self.send(item.data)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func flush() {
        timer?.invalidate()
        timer = nil
        items.removeAll()
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
