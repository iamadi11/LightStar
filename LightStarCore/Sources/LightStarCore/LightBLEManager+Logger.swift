import Foundation

public extension LightBLEManager {

    // MARK: - Device info save

    public func saveDeviceLog() {
        guard !deviceLog.isEmpty else { return }
        #if os(macOS) && DEBUG
        let ts = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/lightstar-device-info-\(ts).txt")
        let content = "=== LightStar Device Info ===\n" + deviceLog.joined(separator: "\n")
        try? content.write(to: url, atomically: true, encoding: .utf8)
        deviceLog.append("Saved → \(url.lastPathComponent)")
        #endif
    }

    public func saveFullBackup() {
        #if os(macOS)
        let ts = Int(Date().timeIntervalSince1970)
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let base = desktop.appendingPathComponent("lightstar-backup-\(ts)").path

        var txt = """
        ╔══════════════════════════════════════════════════════╗
        ║          LightStar — Device Backup                   ║
        ╚══════════════════════════════════════════════════════╝
        Date: \(Date())

        ── Advertisement ────────────────────────────────────────
        RSSI: \(capturedRSSI) dBm
        Name: \(peripheral?.name ?? "unknown")
        UUID: \(peripheral?.identifier.uuidString ?? "unknown")

        """
        for (k, v) in capturedAdvertisementStrings.sorted(by: { $0.key < $1.key }) {
            txt += "  \(k): \(v)\n"
        }

        txt += "\n── GATT Profile ─────────────────────────────────────\n"
        txt += deviceLog.joined(separator: "\n")

        txt += """


        ── Known BC/55 Commands (confirmed via APK reverse-engineering 2026-08-26) ──
        Frame: BC [cmd] [data_len] [data × data_len] 55
        Transport: ATT Write-with-Response on FFF3
        Service: 0000FFF0-0000-1000-8000-00805F9B34FB
        Notify:  0000FFF4-0000-1000-8000-00805F9B34FB (device never sends)
        Scan UUID: 0x2022 (filterByte1=0x22 filterByte2=0x20)

        BC01 01 [00/01] 55                            — Power OFF / ON
        BC02 01 [1–6] 55                              — LED channel order (1=RGB…6=BGR)
        BC03 02 hi lo 55                              — Pixel count (8–300, 2-byte BE)
        BC04 06 H_hi H_lo S_hi S_lo 00 00 55         — Hue (0–360 BE) + Sat (0–1000 BE), static
        BC05 06 B_hi B_lo 00 00 00 00 55             — Brightness (100–1000 BE)
        BC06 02 [hi] [lo] 55                          — Effect mode (58 IDs: see knownEffects)
        BC07 01 [0/1] 55                              — Effect direction (0=backward 1=forward)
        BC08 01 [0–255] 55                            — Effect speed
        BC09 06 H_hi H_lo S_hi S_lo 00 00 55         — Streaming color (audio sync via BC09)
        BC0B 07 yr mo day hr min sec dow 55          — Time sync (auto-sent on connect)
        BC0D 06 01 [on/off] [enabled] [day] [hr] [min] 55 — Weekly device timer
        BC0F 01 [00/01] 55                            — Strip's onboard mic ON/OFF
        BC11 01 [1–4] 55                              — Onboard mic style: 1=Classic 2=Soft 3=Dynamic 4=Disco
        BC12 01 [0–255] 55                            — Mic sensitivity
        BC13 01 [id 0x00–0xFD] 55                    — Firmware animation scenes (253 scenes)

        ── Restore Instructions ─────────────────────────────────
        If custom firmware breaks the device:
        1. Identify chip from lightstar-device-info-*.txt (look for DFU service UUID)
        2. Nordic nRF (FE59 / 1530): flash OEM firmware via nRF Connect DFU
        3. Telink TLSR: requires USB programmer + Telink BDT tool
        4. Restore git tag: git checkout pre-firmware-research
           Then rebuild from Xcode — the app will work with OEM firmware again.

        Git snapshot: pre-firmware-research tag (run: git log --oneline -5)
        """

        #if DEBUG
        try? txt.write(toFile: "\(base).txt", atomically: true, encoding: .utf8)

        let json: [String: Any] = [
            "timestamp": ts,
            "deviceName": peripheral?.name ?? "unknown",
            "deviceUUID": peripheral?.identifier.uuidString ?? "unknown",
            "rssi": capturedRSSI,
            "gattLog": deviceLog,
            "advertisement": capturedAdvertisementStrings,
            "knownCommands": [
                ["cmd": "BC01", "desc": "Power", "format": "BC 01 01 [00=off|01=on] 55"],
                ["cmd": "BC02", "desc": "LED channel order", "format": "BC 02 01 [1=RGB..6=BGR] 55"],
                ["cmd": "BC03", "desc": "Pixel count", "format": "BC 03 02 hi lo 55"],
                ["cmd": "BC04", "desc": "Static color (Hue+Sat)", "format": "BC 04 06 H_hi H_lo S_hi S_lo 00 00 55"],
                ["cmd": "BC05", "desc": "Brightness", "format": "BC 05 06 B_hi B_lo 00 00 00 00 55"],
                ["cmd": "BC06", "desc": "Effect (58 IDs)", "format": "BC 06 02 hi lo 55"],
                ["cmd": "BC07", "desc": "Effect direction", "format": "BC 07 01 [0=back|1=fwd] 55"],
                ["cmd": "BC08", "desc": "Effect speed (0-255)", "format": "BC 08 01 [0-255] 55"],
                ["cmd": "BC09", "desc": "Streaming color (audio sync)", "format": "BC 09 06 H_hi H_lo S_hi S_lo 00 00 55"],
                ["cmd": "BC0B", "desc": "Time sync", "format": "BC 0B 07 yr mo day hr min sec dow 55"],
                ["cmd": "BC0F", "desc": "Strip onboard mic", "format": "BC 0F 01 [0=off|1=on] 55"],
                ["cmd": "BC11", "desc": "Mic style", "format": "BC 11 01 [1=Classic|2=Soft|3=Dynamic|4=Disco] 55"],
                ["cmd": "BC12", "desc": "Mic sensitivity (0-255)", "format": "BC 12 01 [0-255] 55"],
                ["cmd": "BC13", "desc": "Firmware animation scene", "format": "BC 13 01 [id 0x00-0xFD] 55"],
            ]
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            try? jsonStr.write(toFile: "\(base).json", atomically: true, encoding: .utf8)
        }

        deviceLog.append("")
        deviceLog.append("✓ Backup saved:")
        deviceLog.append("  \(base).txt")
        deviceLog.append("  \(base).json")
        #endif
        #endif
    }

    public func saveDeviceInfoIfComplete() {
        #if os(macOS) && DEBUG
        guard deviceLog.contains(where: { $0.hasPrefix("  READ") }) else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let existing = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("lightstar-device-info-") } ?? []
        guard existing.isEmpty else { return }
        saveDeviceLog()
        #endif
    }

    // MARK: - Time sync (BC0B — auto-sent on connect, matches OEM app behaviour)

    public func sendTimeSync() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let now = Date()
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: now)
        let yr  = UInt8((c.year ?? 2024) - 2000)
        let mo  = UInt8(c.month ?? 1)
        let day = UInt8(c.day ?? 1)
        let hr  = UInt8(c.hour ?? 0)
        let mn  = UInt8(c.minute ?? 0)
        let sc  = UInt8(c.second ?? 0)
        // OEM bitmask: bit0=Mon…bit6=Sun. Calendar weekday: 1=Sun,2=Mon,…,7=Sat
        let wd  = UInt8(1 << (((c.weekday ?? 1) + 5) % 7))
        write(Cmd.timeSync(year: yr, month: mo, day: day, hour: hr, minute: mn, second: sc, weekdayMask: wd))
    }
}
