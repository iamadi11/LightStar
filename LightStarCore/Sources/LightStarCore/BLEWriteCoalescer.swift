import Foundation

// Coalesces BLE writes: keyed by command sub-byte (bytes[1]), latest value wins.
// BC0D also keys on bytes[4]: the on- and off-timer are separate frames.
// Insertion-ordered array with replace-in-place so apply(_:) write order is preserved.
// Drains one entry per 20ms tick so the ATT stack always has headroom; a
// colour and the brightness right behind it go out in the same tick when the
// radio has room, so brightness doesn't trail the colour by a tick.
@MainActor
public final class BLEWriteCoalescer {
    private struct Item {
        var cmd: UInt16
        var data: Data
    }

    private var items: [Item] = []
    // nonisolated(unsafe): Timer is only created/invalidated on the main actor;
    // deinit must be able to invalidate it under Swift 6 isolation rules.
    nonisolated(unsafe) private var timer: Timer?
    private let send: @MainActor (Data) -> Void
    private let isConnected: @MainActor () -> Bool
    /// Room for another Write Without Response right now.
    private let canSendMore: @MainActor () -> Bool

    public init(send: @escaping @MainActor (Data) -> Void,
         isConnected: @escaping @MainActor () -> Bool,
         canSendMore: @escaping @MainActor () -> Bool = { false }) {
        self.send = send
        self.isConnected = isConnected
        self.canSendMore = canSendMore
    }

    /// Colour (static or streaming) and brightness: one visible change, sent together.
    static func sendsTogether(_ a: UInt16, _ b: UInt16) -> Bool {
        let colour: Set<UInt16> = [0x04, 0x09]
        return (colour.contains(a) && b == 0x05) || (a == 0x05 && colour.contains(b))
    }

    deinit { timer?.invalidate() }

    static func key(_ bytes: [UInt8]) -> UInt16 {
        let cmd = UInt16(bytes[1])
        return cmd == 0x0D && bytes.count > 4 ? cmd | UInt16(bytes[4]) << 8 : cmd
    }

    public func enqueue(_ bytes: [UInt8]) {
        guard isConnected(), bytes.count >= 2 else { return }
        // Hue/brightness after BC01-off wakes the strip: power-off must be the
        // only remaining frame.
        if StripPowerWritePolicy.isPowerOffFrame(bytes) {
            items.removeAll()
        }
        let cmd = Self.key(bytes)
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
        // The timer fires on the main run loop: no Task hop, which added a
        // scheduling delay to every frame.
        let t = Timer(timeInterval: 0.020, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func tick() {
        guard isConnected() else { flush(); return }
        guard !items.isEmpty else {
            timer?.invalidate(); timer = nil; return
        }
        let item = items.removeFirst()
        send(item.data)
        if let next = items.first, Self.sendsTogether(item.cmd, next.cmd), canSendMore() {
            items.removeFirst()
            send(next.data)
        }
    }

    public func flush() {
        timer?.invalidate()
        timer = nil
        items.removeAll()
    }

    /// Drop the queue and send this frame now. Power on/off must not wait for
    /// the 20ms drain — a with-response backlog never delivers that tick.
    public func sendNow(_ bytes: [UInt8]) {
        guard isConnected(), bytes.count >= 2 else { return }
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
