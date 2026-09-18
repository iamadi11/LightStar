#!/bin/bash
# LightStar Protocol Validation Script
# Validates message serialization round-trips

set -e

echo "=== LightStar Protocol Validation ==="
echo ""

# Create a test file
cat > /tmp/protocol-test.swift << 'EOF'
import Foundation

// Minimal protocol definitions for testing
let kLightStarProtocolVersion: UInt16 = 1

enum RemoteMessageType: UInt8, Codable {
    case hello = 0x01
    case helloAck = 0x02
    case pair = 0x03
    case ping = 0x05
    case setPower = 0x20
    case setBrightness = 0x21
    case mouseMove = 0x30
    case error = 0xFF
}

struct RemoteMessage: Codable {
    let type: RemoteMessageType
    let payload: Data
    let timestamp: TimeInterval
    
    init(type: RemoteMessageType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
        self.timestamp = Date().timeIntervalSince1970
    }
    
    init<T: Encodable>(type: RemoteMessageType, content: T) throws {
        self.type = type
        self.payload = try JSONEncoder().encode(content)
        self.timestamp = Date().timeIntervalSince1970
    }
    
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: payload)
    }
}

struct SetPowerMessage: Codable { let on: Bool }
struct SetBrightnessMessage: Codable { let brightness: Double }
struct MouseMoveMessage: Codable { let deltaX: Double; let deltaY: Double }

func encodeMessage(_ message: RemoteMessage) throws -> Data {
    let encoded = try JSONEncoder().encode(message)
    var length = UInt32(encoded.count).bigEndian
    var data = Data(bytes: &length, count: 4)
    data.append(encoded)
    return data
}

func decodeMessage(from data: Data) throws -> (RemoteMessage, Int) {
    guard data.count >= 4 else { throw NSError(domain: "Test", code: 1) }
    let length = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    let totalLength = Int(length) + 4
    guard data.count >= totalLength else { throw NSError(domain: "Test", code: 2) }
    let messageData = data.subdata(in: 4..<totalLength)
    let message = try JSONDecoder().decode(RemoteMessage.self, from: messageData)
    return (message, totalLength)
}

// Tests
var passed = 0
var failed = 0

func test(_ name: String, _ test: () throws -> Bool) {
    do {
        if try test() {
            print("✓ \(name)")
            passed += 1
        } else {
            print("✗ \(name) - assertion failed")
            failed += 1
        }
    } catch {
        print("✗ \(name) - \(error)")
        failed += 1
    }
}

print("Running protocol tests...")
print("")

test("Ping message round-trip") {
    let msg = RemoteMessage(type: .ping)
    let encoded = try encodeMessage(msg)
    let (decoded, _) = try decodeMessage(from: encoded)
    return decoded.type == .ping
}

test("SetPower message round-trip") {
    let msg = try RemoteMessage(type: .setPower, content: SetPowerMessage(on: true))
    let encoded = try encodeMessage(msg)
    let (decoded, _) = try decodeMessage(from: encoded)
    let payload = try decoded.decode(SetPowerMessage.self)
    return payload.on == true
}

test("SetBrightness message round-trip") {
    let msg = try RemoteMessage(type: .setBrightness, content: SetBrightnessMessage(brightness: 0.75))
    let encoded = try encodeMessage(msg)
    let (decoded, _) = try decodeMessage(from: encoded)
    let payload = try decoded.decode(SetBrightnessMessage.self)
    return abs(payload.brightness - 0.75) < 0.0001
}

test("MouseMove message round-trip") {
    let msg = try RemoteMessage(type: .mouseMove, content: MouseMoveMessage(deltaX: 10.5, deltaY: -20.3))
    let encoded = try encodeMessage(msg)
    let (decoded, _) = try decodeMessage(from: encoded)
    let payload = try decoded.decode(MouseMoveMessage.self)
    return abs(payload.deltaX - 10.5) < 0.0001 && abs(payload.deltaY - (-20.3)) < 0.0001
}

test("Multiple messages in stream") {
    var stream = Data()
    stream.append(try encodeMessage(RemoteMessage(type: .ping)))
    stream.append(try encodeMessage(RemoteMessage(type: .ping)))
    
    let (msg1, consumed1) = try decodeMessage(from: stream)
    stream.removeFirst(consumed1)
    let (msg2, _) = try decodeMessage(from: stream)
    
    return msg1.type == .ping && msg2.type == .ping
}

test("Length prefix is big-endian") {
    let msg = RemoteMessage(type: .ping)
    let encoded = try encodeMessage(msg)
    let firstFourBytes = [UInt8](encoded[0..<4])
    // Big-endian means most significant byte first
    // For small messages (<256 bytes), first 3 bytes should be 0
    return firstFourBytes[0] == 0 && firstFourBytes[1] == 0 && firstFourBytes[2] == 0
}

print("")
print("=== Results ===")
print("Passed: \(passed)")
print("Failed: \(failed)")

if failed > 0 {
    exit(1)
}
EOF

echo "Running protocol tests..."
swift /tmp/protocol-test.swift
echo ""
echo "=== PROTOCOL VALIDATION COMPLETE ==="
