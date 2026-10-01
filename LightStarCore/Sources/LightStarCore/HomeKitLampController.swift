#if os(macOS)
import CryptoKit
import Foundation
import Network

public struct HomeKitPairingRecord: Codable, Sendable {
    public var controllerID: String
    public var controllerSeed: Data
    public var accessoryID: String
    public var accessoryKey: Data
}

public enum HomeKitLampState: Equatable, Sendable {
    case stopped
    case searching
    case needsCode
    case pairing
    case following(String)
    case failed(String)
}

/// Mi Bedside Lamp 2 no longer exposes Yeelight LAN Control. It still speaks
/// HomeKit on the local network, so colour follows the strip after the code
/// on the lamp base is entered once.
@MainActor
@Observable
public final class HomeKitLampController {
    nonisolated public static let pairingDefaultsKey = "homekitLampPairing"

    public private(set) var state: HomeKitLampState = .stopped
    public var onFollowing: (() -> Void)?

    private let engine = HomeKitLampEngine()
    private var started = false

    public init() {
        engine.setHandler { [weak self] event in
            Task { @MainActor in
                guard let self, self.started else { return }
                switch event {
                case .searching:
                    self.state = .searching
                case .needsCode:
                    if self.state != .pairing { self.state = .needsCode }
                case .pairing:
                    self.state = .pairing
                case .following(let name):
                    let first = self.state != .following(name)
                    self.state = .following(name)
                    if first { self.onFollowing?() }
                case .failed(let message):
                    self.state = .failed(message)
                }
            }
        }
    }

    public func start() {
        guard !started else { return }
        started = true
        state = .searching
        engine.start()
    }

    public func stop() {
        guard started else { return }
        started = false
        state = .stopped
        engine.stop()
    }

    public func connect(setupCode raw: String) {
        guard let code = HomeKitSRP.setupCode(raw) else {
            state = .failed("Enter the 8-digit code from the base of the lamp")
            return
        }
        state = .pairing
        engine.pair(code: code)
    }

    public func submit(_ update: YeelightMirrorUpdate) {
        engine.submit(update)
    }
}

private enum HomeKitLampEvent: Sendable {
    case searching
    case needsCode
    case pairing
    case following(String)
    case failed(String)
}

private struct HomeKitLampTarget: Sendable {
    var name: String
    var endpoint: NWEndpoint
    var deviceID: String
    var unpaired: Bool
}

private final class HomeKitLampEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "lightstar.homekit", qos: .userInitiated)
    private var handler: (@Sendable (HomeKitLampEvent) -> Void)?
    private var running = false
    private var browser: NWBrowser?
    private var target: HomeKitLampTarget?
    private var link: HomeKitLink?
    private var onIID: Int?
    private var brightnessIID: Int?
    private var hueIID: Int?
    private var saturationIID: Int?
    private var accessoryID = 1
    private var desired = YeelightMirrorState()
    private var sent = YeelightMirrorState()
    private var flushScheduled = false
    private var generation = 0

    func setHandler(_ handler: @escaping @Sendable (HomeKitLampEvent) -> Void) {
        queue.async { self.handler = handler }
    }

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.generation += 1
            self.emit(.searching)
            self.browse()
            if self.storedPairing() != nil {
                self.openSession(setupCode: nil)
            }
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.generation += 1
            self.browser?.cancel()
            self.browser = nil
            self.link?.cancel()
            self.link = nil
        }
    }

    func pair(code: String) {
        queue.async {
            guard self.running else { return }
            self.emit(.pairing)
            self.openSession(setupCode: code)
        }
    }

    func submit(_ update: YeelightMirrorUpdate) {
        queue.async {
            guard self.running else { return }
            self.desired.apply(update)
            self.flush()
            self.scheduleFlush()
        }
    }

    private func browse() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_hap._tcp", domain: nil), using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.queue.async { self?.consider(results) }
        }
        browser.start(queue: queue)
    }

    private func consider(_ results: Set<NWBrowser.Result>) {
        guard running else { return }
        let lamps = results.compactMap { result -> HomeKitLampTarget? in
            guard case .bonjour(let txt) = result.metadata else { return nil }
            let model = txt["md"] ?? ""
            let name = result.endpoint.debugDescription
            let instance = endpointName(result.endpoint)
            guard model == "MJCTD02YL" || instance.hasPrefix("MiBedsideLamp") else { return nil }
            return HomeKitLampTarget(
                name: instance.isEmpty ? "Mi Bedside Lamp" : instance,
                endpoint: result.endpoint,
                deviceID: txt["id"] ?? instance,
                unpaired: (txt["sf"] ?? "1") == "1"
            )
        }
        guard let lamp = lamps.first else { return }
        let changed = target?.deviceID != lamp.deviceID || target?.unpaired != lamp.unpaired
        target = lamp
        guard changed || link == nil else { return }
        if lamp.unpaired, storedPairing()?.accessoryID != lamp.deviceID {
            emit(.needsCode)
        } else if link == nil {
            openSession(setupCode: nil)
        }
    }

    private func endpointName(_ endpoint: NWEndpoint) -> String {
        if case .service(let name, _, _, _) = endpoint { return name }
        return ""
    }

    private func openSession(setupCode: String?) {
        guard let target else {
            emit(.searching)
            return
        }
        if target.unpaired && setupCode == nil && storedPairing() == nil {
            emit(.needsCode)
            return
        }
        link?.cancel()
        let session = generation
        let link = HomeKitLink(endpoint: target.endpoint)
        self.link = link
        link.start(queue: queue) { [weak self] in
            self?.queue.async {
                guard let self, self.running, self.generation == session else { return }
                self.establish(link, target: target, setupCode: setupCode, session: session)
            }
        }
    }

    private func establish(_ link: HomeKitLink, target: HomeKitLampTarget, setupCode: String?, session: Int) {
        Task {
            do {
                if let code = setupCode {
                    let record = try await HomeKitPairing.pair(link: link, setupCode: code, deviceID: target.deviceID)
                    self.save(record)
                    link.cancel()
                    guard self.running, self.generation == session else { return }
                    self.openSession(setupCode: nil)
                    return
                }
                guard let record = self.storedPairing() else {
                    self.emit(.needsCode)
                    return
                }
                let keys = try await HomeKitPairing.verify(link: link, record: record)
                link.installEncryption(write: keys.write, read: keys.read)
                let body = try await link.request(method: "GET", path: "/accessories", body: nil, contentType: nil)
                guard self.running, self.generation == session else { return }
                self.rememberCharacteristics(body)
                self.sent = YeelightMirrorState()
                self.emit(.following(target.name))
                self.flush()
            } catch HomeKitLampError.alreadyPaired {
                self.emit(.failed("Remove the lamp from the Home app, then enter the code on its base"))
            } catch HomeKitLampError.authentication {
                self.emit(.failed("That code was rejected. Use the 8 digits on the lamp base"))
            } catch {
                if self.storedPairing() == nil {
                    self.emit(.needsCode)
                } else {
                    self.emit(.failed("Could not reach the lamp"))
                }
            }
        }
    }

    private func hapType(_ type: String, equals value: UInt32) -> Bool {
        let head = type.split(separator: "-").first.map(String.init) ?? type
        return UInt32(head, radix: 16) == value
    }

    private func rememberCharacteristics(_ body: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let accessories = json["accessories"] as? [[String: Any]] else { return }
        for accessory in accessories {
            accessoryID = accessory["aid"] as? Int ?? 1
            let services = accessory["services"] as? [[String: Any]] ?? []
            for service in services {
                let chars = service["characteristics"] as? [[String: Any]] ?? []
                for item in chars {
                    guard let iid = item["iid"] as? Int, let type = (item["type"] as? String)?.lowercased() else { continue }
                    if hapType(type, equals: 0x25) { onIID = iid }
                    if hapType(type, equals: 0x08) { brightnessIID = iid }
                    if hapType(type, equals: 0x13) { hueIID = iid }
                    if hapType(type, equals: 0x2F) { saturationIID = iid }
                }
            }
        }
    }

    private func flush() {
        guard link?.encrypted == true else { return }
        guard Date().timeIntervalSince(lastFlush) >= 0.15 || lastFlush == .distantPast else { return }
        var writes: [[String: Any]] = []
        if let power = desired.power, power != sent.power, let iid = onIID {
            writes.append(["aid": accessoryID, "iid": iid, "value": power])
            sent.power = power
        }
        if let hue = desired.hue, let saturation = desired.saturation, let hueIID, let saturationIID {
            let nextHue = YeelightColor.hueDegrees(hue)
            let nextSat = YeelightColor.saturationPercent(saturation)
            if nextHue != sent.hue.map(YeelightColor.hueDegrees) || nextSat != sent.saturation.map(YeelightColor.saturationPercent) {
                writes.append(["aid": accessoryID, "iid": hueIID, "value": nextHue])
                writes.append(["aid": accessoryID, "iid": saturationIID, "value": nextSat])
                sent.hue = Double(nextHue) / 360
                sent.saturation = Double(nextSat) / 100
            }
        }
        if let brightness = desired.brightness, let iid = brightnessIID {
            let next = YeelightColor.brightnessPercent(brightness)
            if next != sent.brightness.map(YeelightColor.brightnessPercent) {
                writes.append(["aid": accessoryID, "iid": iid, "value": next])
                sent.brightness = Double(next) / 100
            }
        }
        guard !writes.isEmpty, let body = try? JSONSerialization.data(withJSONObject: ["characteristics": writes]) else { return }
        lastFlush = Date()
        let link = self.link
        Task {
            _ = try? await link?.request(method: "PUT", path: "/characteristics", body: body, contentType: "application/hap+json")
        }
    }

    private var lastFlush = Date.distantPast

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        let session = generation
        queue.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            guard self.running, self.generation == session else { return }
            self.flush()
        }
    }

    private func storedPairing() -> HomeKitPairingRecord? {
        guard let data = UserDefaults.standard.data(forKey: HomeKitLampController.pairingDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(HomeKitPairingRecord.self, from: data)
    }

    private func save(_ record: HomeKitPairingRecord) {
        if let data = try? JSONEncoder().encode(record) {
            UserDefaults.standard.set(data, forKey: HomeKitLampController.pairingDefaultsKey)
        }
    }

    private func emit(_ event: HomeKitLampEvent) {
        handler?(event)
    }
}

private struct HomeKitSessionKeys {
    var write: SymmetricKey
    var read: SymmetricKey
}

private enum HomeKitPairing {
    static func pair(link: HomeKitLink, setupCode: String, deviceID: String) async throws -> HomeKitPairingRecord {
        let seed = Curve25519.Signing.PrivateKey()
        let controllerID = UUID().uuidString
        let m1 = HomeKitTLV.encode([
            (HomeKitTLV.state, HomeKitTLV.byte(1)),
            (HomeKitTLV.method, HomeKitTLV.byte(0))
        ])
        let m2 = HomeKitTLV.decode(try await link.request(method: "POST", path: "/pair-setup", body: m1, contentType: "application/pairing+tlv8"))
        if m2[HomeKitTLV.error] == Data([0x06]) { throw HomeKitLampError.alreadyPaired }
        guard let salt = m2[HomeKitTLV.salt], let serverKey = m2[HomeKitTLV.publicKey] else { throw HomeKitLampError.protocolError }
        var srp = HomeKitSRPClient(password: setupCode)
        srp.setServer(salt: salt, publicKey: serverKey)
        let m3 = HomeKitTLV.encode([
            (HomeKitTLV.state, HomeKitTLV.byte(3)),
            (HomeKitTLV.publicKey, srp.clientPublicBytes),
            (HomeKitTLV.proof, srp.clientProof())
        ])
        let m4 = HomeKitTLV.decode(try await link.request(method: "POST", path: "/pair-setup", body: m3, contentType: "application/pairing+tlv8"))
        if m4[HomeKitTLV.error] == Data([0x02]) { throw HomeKitLampError.authentication }
        guard let proof = m4[HomeKitTLV.proof], srp.verifyServerProof(proof) else { throw HomeKitLampError.authentication }
        let encryptKey = HomeKitCrypto.hkdf(ikm: srp.sessionKeyBytes, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let deviceX = keyData(HomeKitCrypto.hkdf(ikm: srp.sessionKeyBytes, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info"))
        let publicKey = seed.publicKey.rawRepresentation
        let info = deviceX + Data(controllerID.utf8) + publicKey
        let signature = try seed.signature(for: info)
        let inner = HomeKitTLV.encode([
            (HomeKitTLV.identifier, Data(controllerID.utf8)),
            (HomeKitTLV.publicKey, publicKey),
            (HomeKitTLV.signature, Data(signature))
        ])
        let sealed = try HomeKitCrypto.seal(key: encryptKey, nonce: HomeKitCrypto.nonce(label: "PS-Msg05"), aad: Data(), plaintext: inner)
        let m5 = HomeKitTLV.encode([
            (HomeKitTLV.state, HomeKitTLV.byte(5)),
            (HomeKitTLV.encryptedData, sealed)
        ])
        let m6 = HomeKitTLV.decode(try await link.request(method: "POST", path: "/pair-setup", body: m5, contentType: "application/pairing+tlv8"))
        if m6[HomeKitTLV.error] != nil { throw HomeKitLampError.authentication }
        guard let encrypted = m6[HomeKitTLV.encryptedData] else { throw HomeKitLampError.protocolError }
        let opened = try HomeKitCrypto.open(key: encryptKey, nonce: HomeKitCrypto.nonce(label: "PS-Msg06"), aad: Data(), ciphertextAndTag: encrypted)
        let accessory = HomeKitTLV.decode(opened)
        guard let accessoryID = accessory[HomeKitTLV.identifier],
              let accessoryKey = accessory[HomeKitTLV.publicKey],
              let accessorySignature = accessory[HomeKitTLV.signature] else { throw HomeKitLampError.protocolError }
        let accessoryX = keyData(HomeKitCrypto.hkdf(ikm: srp.sessionKeyBytes, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info"))
        let accessoryInfo = accessoryX + accessoryID + accessoryKey
let accessoryPublicKey = try Curve25519.Signing.PublicKey(rawRepresentation: accessoryKey)
        guard accessoryPublicKey.isValidSignature(accessorySignature, for: accessoryInfo) else {
            throw HomeKitLampError.authentication
        }
        return HomeKitPairingRecord(
            controllerID: controllerID,
            controllerSeed: seed.rawRepresentation,
            accessoryID: deviceID,
            accessoryKey: accessoryKey
        )
    }

    static func verify(link: HomeKitLink, record: HomeKitPairingRecord) async throws -> HomeKitSessionKeys {
        let seed = try Curve25519.Signing.PrivateKey(rawRepresentation: record.controllerSeed)
        let session = Curve25519.KeyAgreement.PrivateKey()
        let m1 = HomeKitTLV.encode([
            (HomeKitTLV.state, HomeKitTLV.byte(1)),
            (HomeKitTLV.publicKey, session.publicKey.rawRepresentation)
        ])
        let m2 = HomeKitTLV.decode(try await link.request(method: "POST", path: "/pair-verify", body: m1, contentType: "application/pairing+tlv8"))
        guard let accessoryPublic = m2[HomeKitTLV.publicKey], let encrypted = m2[HomeKitTLV.encryptedData] else {
            throw HomeKitLampError.protocolError
        }
        let shared = try session.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: accessoryPublic))
        let sharedData = shared.withUnsafeBytes { Data($0) }
        let verifyKey = HomeKitCrypto.hkdf(ikm: sharedData, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        let opened = try HomeKitCrypto.open(key: verifyKey, nonce: HomeKitCrypto.nonce(label: "PV-Msg02"), aad: Data(), ciphertextAndTag: encrypted)
        let inner = HomeKitTLV.decode(opened)
        guard let identifier = inner[HomeKitTLV.identifier], let signature = inner[HomeKitTLV.signature] else {
            throw HomeKitLampError.protocolError
        }
        let accessoryInfo = accessoryPublic + identifier + session.publicKey.rawRepresentation
        let accessoryLongTerm = try Curve25519.Signing.PublicKey(rawRepresentation: record.accessoryKey)
        guard accessoryLongTerm.isValidSignature(signature, for: accessoryInfo) else {
            throw HomeKitLampError.authentication
        }
        let controllerInfo = session.publicKey.rawRepresentation + Data(record.controllerID.utf8) + accessoryPublic
        let controllerSignature = try seed.signature(for: controllerInfo)
        let reply = HomeKitTLV.encode([
            (HomeKitTLV.identifier, Data(record.controllerID.utf8)),
            (HomeKitTLV.signature, Data(controllerSignature))
        ])
        let sealed = try HomeKitCrypto.seal(key: verifyKey, nonce: HomeKitCrypto.nonce(label: "PV-Msg03"), aad: Data(), plaintext: reply)
        let m3 = HomeKitTLV.encode([
            (HomeKitTLV.state, HomeKitTLV.byte(3)),
            (HomeKitTLV.encryptedData, sealed)
        ])
        let m4 = HomeKitTLV.decode(try await link.request(method: "POST", path: "/pair-verify", body: m3, contentType: "application/pairing+tlv8"))
        if m4[HomeKitTLV.error] != nil { throw HomeKitLampError.authentication }
        return HomeKitSessionKeys(
            write: HomeKitCrypto.hkdf(ikm: sharedData, salt: "Control-Salt", info: "Control-Write-Encryption-Key"),
            read: HomeKitCrypto.hkdf(ikm: sharedData, salt: "Control-Salt", info: "Control-Read-Encryption-Key")
        )
    }

    private static func keyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}

private final class HomeKitLink: @unchecked Sendable {
    let endpoint: NWEndpoint
    private var connection: NWConnection?
    private var cipherBuffer = Data()
    private var plainBuffer = Data()
    private var waiters: [(Result<Data, Error>) -> Void] = []
    private var writeKey: SymmetricKey?
    private var readKey: SymmetricKey?
    private var writeCount: UInt64 = 0
    private var readCount: UInt64 = 0
    private let lock = NSLock()
    var encrypted: Bool { writeKey != nil }

    init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
    }

    func start(queue: DispatchQueue, ready: @escaping @Sendable () -> Void) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { state in
            if case .ready = state { ready() }
            if case .failed = state {
                self.fail(HomeKitLampError.unreachable)
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func installEncryption(write: SymmetricKey, read: SymmetricKey) {
        lock.lock()
        writeKey = write
        readKey = read
        writeCount = 0
        readCount = 0
        lock.unlock()
    }

    func request(method: String, path: String, body: Data?, contentType: String?) async throws -> Data {
        var header = "\(method) \(path) HTTP/1.1\r\nHost: MiBedsideLamp.local\r\nConnection: keep-alive\r\n"
        if let contentType, let body {
            header += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        }
        header += "\r\n"
        var raw = Data(header.utf8)
        if let body { raw.append(body) }
        let outbound = try encodedRequest(raw)
        try await send(outbound)
        let response = try await nextPayload()
        return try httpBody(response)
    }

    private func encodedRequest(_ raw: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let writeKey else { return raw }
        return try HomeKitCrypto.encryptFrames(key: writeKey, counter: &writeCount, plaintext: raw)
    }

    func cancel() {
        connection?.cancel()
        fail(HomeKitLampError.unreachable)
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection?.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func nextPayload() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let message = takeMessage() {
                lock.unlock()
                continuation.resume(returning: message)
                return
            }
            waiters.append { result in
                continuation.resume(with: result)
            }
            lock.unlock()
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.accept(data) }
            if error != nil || isComplete {
                self.fail(error ?? HomeKitLampError.unreachable)
                return
            }
            self.receive()
        }
    }

    private func accept(_ data: Data) {
        lock.lock()
        if readKey != nil {
            cipherBuffer.append(data)
            if let readKey, let plain = try? HomeKitCrypto.decryptFrames(key: readKey, counter: &readCount, input: &cipherBuffer) {
                plainBuffer.append(plain)
            }
        } else {
            plainBuffer.append(data)
        }
        deliverLocked()
        lock.unlock()
    }

    private func deliverLocked() {
        while !waiters.isEmpty, let message = takeMessage() {
            let waiter = waiters.removeFirst()
            waiter(.success(message))
        }
    }

    private func takeMessage() -> Data? {
        guard let headerEnd = plainBuffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let header = plainBuffer[..<headerEnd.lowerBound]
        let contentLength = headerText(Data(header))
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
        let total = plainBuffer.distance(from: plainBuffer.startIndex, to: headerEnd.upperBound) + contentLength
        guard plainBuffer.count >= total else { return nil }
        let message = plainBuffer.prefix(total)
        plainBuffer.removeFirst(total)
        return Data(message)
    }

    private func headerText(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }

    private func httpBody(_ response: Data) throws -> Data {
        guard let headerEnd = response.range(of: Data("\r\n\r\n".utf8)) else { throw HomeKitLampError.protocolError }
        let status = headerText(response.prefix(through: min(response.index(response.startIndex, offsetBy: 12), response.endIndex)))
        if status.contains(" 470") { throw HomeKitLampError.alreadyPaired }
        return response.suffix(from: headerEnd.upperBound)
    }

    private func fail(_ error: Error) {
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter(.failure(error)) }
    }
}
#endif
