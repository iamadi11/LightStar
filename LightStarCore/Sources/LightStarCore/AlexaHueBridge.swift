#if os(macOS)
import Foundation
import Network
import Darwin
import Combine

/// Local Philips Hue API + SSDP responder so an Echo Dot can discover LightStar
/// and drive the connected BLE strip through `LightBLEManager`.
///
/// Architecture:
/// ```
/// Echo Dot ──SSDP/HTTP Hue API──► LightStar (this bridge)
///                                      │
///                                      ▼
///                               LightBLEManager ──BLE──► strip
/// ```
@MainActor
public final class AlexaHueBridge: ObservableObject {

    public enum BridgeState: Equatable, Sendable {
        case stopped
        case starting
        case running(port: UInt16)
        case error(String)
    }

    public static let defaultPort: UInt16 = 9123
    public static let enabledDefaultsKey = "alexaHueBridgeEnabled"
    public static let bridgeIdDefaultsKey = "alexaHueBridgeId"
    public static let usernameDefaultsKey = "alexaHueBridgeUsername"

    @Published public private(set) var state: BridgeState = .stopped

    /// Stable Hue bridge id (hex) persisted across launches for Alexa pairing.
    public let bridgeId: String
    /// Username Alexa receives on link; reused so re-discovery keeps working.
    public private(set) var apiUsername: String

    public var onApplyState: ((HueLightStatePatch) -> Void)?
    public var getLightSnapshot: (() -> HueLightSnapshot)?

    private var httpListener: NWListener?
    private var ssdpConnection: NWConnectionGroup?
    private let queue = DispatchQueue(label: "lightstar.alexa.hue", qos: .userInitiated)
    private let lightId = "1"
    private let lightName = "LightStar"

    public init(
        bridgeId: String? = nil,
        apiUsername: String? = nil
    ) {
        let storedId = UserDefaults.standard.string(forKey: Self.bridgeIdDefaultsKey)
        let id = bridgeId
            ?? storedId
            ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        if storedId == nil {
            UserDefaults.standard.set(id, forKey: Self.bridgeIdDefaultsKey)
        }
        self.bridgeId = id

        let storedUser = UserDefaults.standard.string(forKey: Self.usernameDefaultsKey)
        let user = apiUsername
            ?? storedUser
            ?? "lightstar\(String(id.prefix(8)))"
        if storedUser == nil {
            UserDefaults.standard.set(user, forKey: Self.usernameDefaultsKey)
        }
        self.apiUsername = user
    }

    public func start(port: UInt16 = AlexaHueBridge.defaultPort) {
        switch state {
        case .stopped, .error:
            stopListeners()
        default:
            return
        }
        state = .starting
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            httpListener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            httpListener?.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor in
                    self?.handleHTTPListenerState(newState, port: port)
                }
            }
            httpListener?.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.acceptHTTP(connection)
                }
            }
            httpListener?.start(queue: queue)
            startSSDP(advertisedPort: port)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    public func stop() {
        stopListeners()
        state = .stopped
    }

    // MARK: - HTTP

    private func handleHTTPListenerState(_ newState: NWListener.State, port: UInt16) {
        switch newState {
        case .ready:
            state = .running(port: port)
        case .failed(let error):
            stopListeners()
            state = .error(error.localizedDescription)
        case .cancelled:
            if case .error = state { break }
            state = .stopped
        default:
            break
        }
    }

    private func acceptHTTP(_ connection: NWConnection) {
        let session = HueHTTPSession(connection: connection) { [weak self] request in
            await MainActor.run {
                self?.handleHTTP(request) ?? HueHTTPResponse(status: 503, body: Data("bridge offline".utf8))
            }
        }
        session.start(queue: queue)
    }

    private func handleHTTP(_ request: HueHTTPRequest) -> HueHTTPResponse {
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        let method = request.method.uppercased()

        if path == "/description.xml" || path.hasSuffix("/description.xml") {
            return HueHTTPResponse(status: 200, contentType: "application/xml", body: Data(descriptionXML().utf8))
        }

        // Pairing: POST /api
        if method == "POST", path == "/api" || path == "/api/" {
            let body = #"[{"success":{"username":"\#(apiUsername)"}}]"#
            return json(body)
        }

        // Allow unauthenticated discovery of lights list for stubborn Echo firmware.
        if method == "GET", path == "/api/nouser/config" {
            return json(configJSON(linkButton: true))
        }

        guard let route = parseAPIRoute(path) else {
            return HueHTTPResponse(status: 404, body: Data("not found".utf8))
        }

        switch (method, route.resource) {
        case ("GET", .root), ("GET", .config):
            return json(configJSON(linkButton: false))
        case ("GET", .lights):
            return json(lightsDictionaryJSON())
        case ("GET", .light):
            return json(singleLightJSON())
        case ("PUT", .lightState):
            applyStatePatch(from: request.body)
            return json(#"[{"success":{"/lights/\#(lightId)/state/on":true}}]"#)
        default:
            return HueHTTPResponse(status: 404, body: Data("not found".utf8))
        }
    }

    private enum APIResource {
        case root
        case config
        case lights
        case light
        case lightState
    }

    private func parseAPIRoute(_ path: String) -> (user: String, resource: APIResource)? {
        // /api/<user>/...
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "api" else { return nil }
        let user = parts[1]
        if parts.count == 2 { return (user, .root) }
        switch parts[2] {
        case "config":
            return (user, .config)
        case "lights":
            if parts.count == 3 { return (user, .lights) }
            if parts.count == 4 { return (user, .light) }
            if parts.count >= 5, parts[4] == "state" { return (user, .lightState) }
            return (user, .light)
        default:
            return nil
        }
    }

    private func applyStatePatch(from body: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
        var patch = HueLightStatePatch()
        if let on = obj["on"] as? Bool { patch.on = on }
        if let bri = obj["bri"] as? Int { patch.brightness = HueColorMapping.brightnessFromHueBri(bri) }
        if let hue = obj["hue"] as? Int { patch.hue = HueColorMapping.hueFraction(fromHueHue: hue) }
        if let sat = obj["sat"] as? Int { patch.saturation = HueColorMapping.saturationFromHueSat(sat) }
        if let ct = obj["ct"] as? Int {
            patch.kelvin = HueColorMapping.kelvin(fromMireds: ct)
        }
        onApplyState?(patch)
    }

    private func json(_ string: String) -> HueHTTPResponse {
        HueHTTPResponse(status: 200, contentType: "application/json", body: Data(string.utf8))
    }

    private func lightsDictionaryJSON() -> String {
        #"{"\#(lightId)":\#(singleLightJSON())}"#
    }

    private func singleLightJSON() -> String {
        let snap = getLightSnapshot?() ?? HueLightSnapshot(isOn: false, hue: 0, saturation: 0, brightness: 1)
        let bri = HueColorMapping.hueBri(fromBrightness: snap.brightness)
        let hue = HueColorMapping.hueHue(fromFraction: snap.hue)
        let sat = HueColorMapping.hueSat(fromSaturation: snap.saturation)
        return """
        {"state":{"on":\(snap.isOn ? "true" : "false"),"bri":\(bri),"hue":\(hue),"sat":\(sat),"effect":"none","xy":[0.0,0.0],"ct":370,"alert":"none","colormode":"hs","mode":"homeautomation","reachable":true},"type":"Extended color light","name":"\(lightName)","modelid":"LCT007","manufacturername":"Philips","productname":"LightStar","uniqueid":"\(bridgeId)-01","swversion":"1.0.0"}
        """
    }

    private func configJSON(linkButton: Bool) -> String {
        """
        {"name":"LightStar Hue Bridge","mac":"00:11:22:33:44:55","dhcp":true,"ipaddress":"127.0.0.1","netmask":"255.255.255.0","gateway":"127.0.0.1","proxyaddress":"none","proxyport":0,"bridgeid":"\(bridgeId.uppercased())","UTC":"\(isoNow())","localtime":"\(isoNow())","timezone":"none","modelid":"BSB002","datastoreversion":"70","swversion":"1941063050","apiversion":"1.22.0","linkbutton":\(linkButton ? "true" : "false"),"factorynew":false,"replacesbridgeid":null,"starterkitid":"","whitelist":{"\(apiUsername)":{"last use date":"\(isoNow())","create date":"\(isoNow())","name":"Alexa#LightStar"}}}
        """
    }

    private func descriptionXML() -> String {
        let port: UInt16 = {
            if case .running(let p) = state { return p }
            return Self.defaultPort
        }()
        let host = localIPv4() ?? "127.0.0.1"
        let udn = "uuid:\(bridgeId)"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0">
          <specVersion><major>1</major><minor>0</minor></specVersion>
          <URLBase>http://\(host):\(port)/</URLBase>
          <device>
            <deviceType>urn:schemas-upnp-org:device:Basic:1</deviceType>
            <friendlyName>LightStar Hue Bridge (\(host))</friendlyName>
            <manufacturer>Royal Philips Electronics</manufacturer>
            <manufacturerURL>http://www.philips.com</manufacturerURL>
            <modelDescription>Philips hue Personal Wireless Lighting</modelDescription>
            <modelName>Philips hue bridge 2015</modelName>
            <modelNumber>BSB002</modelNumber>
            <modelURL>http://www.meethue.com</modelURL>
            <serialNumber>\(bridgeId)</serialNumber>
            <UDN>\(udn)</UDN>
            <presentationURL>index.html</presentationURL>
          </device>
        </root>
        """
    }

    private func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    // MARK: - SSDP

    private func startSSDP(advertisedPort: UInt16) {
        // Minimal UDP responder on 1900 for M-SEARCH. Echo discovers LOCATION here.
        let host = localIPv4() ?? "127.0.0.1"
        let udn = "uuid:\(bridgeId)"
        let response =
            "HTTP/1.1 200 OK\r\n" +
            "CACHE-CONTROL: max-age=100\r\n" +
            "EXT:\r\n" +
            "LOCATION: http://\(host):\(advertisedPort)/description.xml\r\n" +
            "SERVER: LightStar/1.0 UPnP/1.0 IpBridge/1.22.0\r\n" +
            "ST: urn:schemas-upnp-org:device:basic:1\r\n" +
            "USN: \(udn)::urn:schemas-upnp-org:device:basic:1\r\n" +
            "hue-bridgeid: \(bridgeId.uppercased())\r\n\r\n"

        SSDPResponder.shared.start(responseUTF8: response, queue: queue)
    }

    private func stopListeners() {
        httpListener?.cancel()
        httpListener = nil
        SSDPResponder.shared.stop()
        ssdpConnection = nil
    }

    private func localIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let iface = p.pointee
            if iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: iface.ifa_name)
                if name == "en0" || name.hasPrefix("en") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        iface.ifa_addr,
                        socklen_t(iface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    let ip = String(cString: hostname)
                    if !ip.hasPrefix("127.") {
                        address = ip
                        if name == "en0" { break }
                    }
                }
            }
            ptr = iface.ifa_next
        }
        return address
    }
}

// MARK: - Public models

public struct HueLightStatePatch: Sendable {
    public var on: Bool?
    public var hue: Double?
    public var saturation: Double?
    public var brightness: Double?
    public var kelvin: Double?

    public init(on: Bool? = nil, hue: Double? = nil, saturation: Double? = nil, brightness: Double? = nil, kelvin: Double? = nil) {
        self.on = on
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
        self.kelvin = kelvin
    }
}

public struct HueLightSnapshot: Sendable {
    public var isOn: Bool
    public var hue: Double
    public var saturation: Double
    public var brightness: Double

    public init(isOn: Bool, hue: Double, saturation: Double, brightness: Double) {
        self.isOn = isOn
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }
}

// MARK: - Tiny HTTP

struct HueHTTPRequest: Sendable {
    var method: String
    var path: String
    var body: Data
}

struct HueHTTPResponse: Sendable {
    var status: Int
    var contentType: String
    var body: Data

    init(status: Int, contentType: String = "text/plain", body: Data) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }
}

private final class HueHTTPSession: @unchecked Sendable {
    private let connection: NWConnection
    private let handler: @Sendable (HueHTTPRequest) async -> HueHTTPResponse
    private var buffer = Data()

    init(connection: NWConnection, handler: @escaping @Sendable (HueHTTPRequest) async -> HueHTTPResponse) {
        self.connection = connection
        self.handler = handler
    }

    func start(queue: DispatchQueue) {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if let request = self.parseRequest() {
                    Task {
                        let response = await self.handler(request)
                        self.send(response)
                    }
                    return
                }
            }
            if isComplete || error != nil {
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }

    private func parseRequest() -> HueHTTPRequest? {
        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let tokens = requestLine.split(separator: " ")
        guard tokens.count >= 2 else { return nil }
        let method = String(tokens[0])
        let path = String(tokens[1])
        var contentLength = 0
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                contentLength = Int(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
            }
        }
        let bodyStart = headerRange.upperBound
        guard buffer.count >= bodyStart + contentLength else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        buffer.removeAll(keepingCapacity: true)
        return HueHTTPRequest(method: method, path: path, body: body)
    }

    private func send(_ response: HueHTTPResponse) {
        let reason = response.status == 200 ? "OK" : "Error"
        var header = "HTTP/1.1 \(response.status) \(reason)\r\n"
        header += "Content-Type: \(response.contentType)\r\n"
        header += "Content-Length: \(response.body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }
}

// MARK: - SSDP multicast responder (BSD sockets)

private final class SSDPResponder: @unchecked Sendable {
    static let shared = SSDPResponder()
    private var socketFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var responseData = Data()

    func start(responseUTF8: String, queue: DispatchQueue) {
        stop()
        responseData = Data(responseUTF8.utf8)
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(1900).bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            return
        }

        var mreq = ip_mreq(
            imr_multiaddr: in_addr(s_addr: inet_addr("239.255.255.250")),
            imr_interface: in_addr(s_addr: INADDR_ANY.bigEndian)
        )
        setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))

        socketFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            self?.handleRead()
        }
        src.setCancelHandler {
            close(fd)
        }
        source = src
        src.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    private func handleRead() {
        var buf = [UInt8](repeating: 0, count: 2048)
        var addr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(socketFD, &buf, buf.count, 0, $0, &addrLen)
            }
        }
        guard n > 0 else { return }
        let text = String(bytes: buf[0..<n], encoding: .utf8)?.uppercased() ?? ""
        guard text.contains("M-SEARCH"), text.contains("SSDP:DISCOVER") else { return }
        // Hue-related search targets Alexa uses.
        let interesting =
            text.contains("URN:SCHEMAS-UPNP-ORG:DEVICE:BASIC:1")
            || text.contains("UPNP:ROOTDEVICE")
            || text.contains("SSDP:ALL")
            || text.contains("DEVICE:BASIC")
        guard interesting else { return }
        _ = responseData.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketFD, raw.baseAddress, responseData.count, 0, $0, addrLen)
                }
            }
        }
    }
}

#endif
