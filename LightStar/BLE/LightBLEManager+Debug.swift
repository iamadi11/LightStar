import Foundation

extension LightBLEManager {

    // MARK: - Protocol dump
    // Single comprehensive sweep:
    //   1. Device state queries
    //   2. BC00–BC1F command sweep (0-byte + 1-byte payloads)
    //   3. BC0F mic-mode sweep (b1 0-3, b2 0-8)
    //   4. BC13 animation sweep (ID 0x01-0x3C, 3s each)
    //   5. BC11 sub-param sweep
    //   All TX and RX logged to probeLog; auto-saved to Desktop on finish.
    func protocolDump() {
        guard !probeRunning, connectionState == .connected else { return }
        probeRunning = true
        notifyTapHandler = nil

        let ts = Date()
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        probeLog = [
            "╔══════════════════════════════════════╗",
            "║   LightStar — Protocol Dump          ║",
            "╚══════════════════════════════════════╝",
            "Started: \(fmt.string(from: ts))",
            "→ TX  ← RX",
            "",
        ]

        probeTask = Task { @MainActor in
            self.notifyTapHandler = { [weak self] data in
                guard let self else { return }
                let rx = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                self.probeLog.append("  ← \(rx)")
            }

            let tx: ([UInt8], String) -> Void = { bytes, label in
                let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                self.probeLog.append("→ [\(label)] \(hex)")
                self.write(bytes)
            }
            func ms(_ n: Int) async { try? await Task.sleep(nanoseconds: UInt64(n) * 1_000_000) }

            self.probeLog.append("── 1. State queries ────────────────────────────────────────")
            self.write(Cmd.powerOn)
            self.write(Cmd.brightness(1.0))
            await ms(400)
            for (cmd, label) in [(([0xBC, 0x06, 0x00, 0x55] as [UInt8]), "status?"),
                                  ([0xBC, 0x00, 0x00, 0x55], "ping?"),
                                  ([0xBC, 0x02, 0x00, 0x55], "query02?"),
                                  ([0xBC, 0x08, 0x00, 0x55], "query08?")] {
                if Task.isCancelled { break }
                tx(cmd, label)
                await ms(600)
            }

            self.probeLog.append("")
            self.probeLog.append("── 2. BC00–BC1F sweep (0-byte + 1-byte payload) ─────────────")
            let knownCmds: Set<UInt8> = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0B, 0x0D, 0x0F, 0x11, 0x12, 0x13]
            for cmd: UInt8 in 0x00...0x1F {
                if Task.isCancelled { break }
                let tag = knownCmds.contains(cmd) ? "KNOWN" : "?"
                tx([0xBC, cmd, 0x00, 0x55], String(format: "BC%02X 0b[%@]", cmd, tag))
                await ms(200)
                tx([0xBC, 0x06, 0x00, 0x55], "status?")
                await ms(300)
                tx([0xBC, cmd, 0x01, 0x01, 0x55], String(format: "BC%02X b=01", cmd))
                await ms(200)
                tx([0xBC, 0x06, 0x00, 0x55], "status?")
                await ms(300)
            }

            self.probeLog.append("")
            self.probeLog.append("── 3. BC0F mic-mode sweep (b1 0x00–0x03, b2 0x00–0x08) ─────")
            for b1: UInt8 in 0x00...0x03 {
                for b2: UInt8 in 0x00...0x08 {
                    if Task.isCancelled { break }
                    tx([0xBC, 0x0F, 0x02, b1, b2, 0x55], String(format: "BC0F b1=%02X b2=%02X", b1, b2))
                    await ms(200)
                    tx([0xBC, 0x06, 0x00, 0x55], "status?")
                    await ms(400)
                }
            }

            self.probeLog.append("")
            self.probeLog.append("── 4. BC13 animation sweep (ID 0x01–0x3C, 3s each) ──────────")
            self.probeLog.append("   !! Play music near strip — watch for audio beam !!")
            self.write(Cmd.powerOn)
            self.write(Cmd.brightness(1.0))
            await ms(500)
            for id: UInt8 in 0x01...0x3C {
                if Task.isCancelled { break }
                tx([0xBC, 0x13, 0x01, id, 0x55], String(format: "anim ID=0x%02X", id))
                await ms(300)
                tx([0xBC, 0x06, 0x00, 0x55], "status?")
                await ms(2700)
            }

            self.probeLog.append("")
            self.probeLog.append("── 5. BC11 sub-param sweep (0x01–0x06) ──────────────────────")
            for v: UInt8 in 0x01...0x06 {
                if Task.isCancelled { break }
                tx([0xBC, 0x11, 0x01, v, 0x55], String(format: "BC11 val=0x%02X", v))
                await ms(300)
                tx([0xBC, 0x06, 0x00, 0x55], "status?")
                await ms(600)
            }

            self.notifyTapHandler = nil
            self.probeLog.append("")
            self.probeLog.append("═══════════════════════════════════════════════════════════")
            self.probeLog.append("Finished: \(fmt.string(from: Date()))")
            self.saveProbeLog()
            self.probeRunning = false
        }
    }

    func saveProbeLog() {
        guard !probeLog.isEmpty else { return }
        let ts = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/lightstar-protocol-\(ts).txt")
        let content = probeLog.joined(separator: "\n")
        try? content.write(to: url, atomically: true, encoding: .utf8)
        probeLog.append("Saved → \(url.lastPathComponent)")
    }
}
