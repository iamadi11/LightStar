import CryptoKit
import Foundation

enum HomeKitCrypto {
    static func hkdf(ikm: Data, salt: String, info: String) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: Data(salt.utf8),
            info: Data(info.utf8),
            outputByteCount: 32
        )
    }

    /// Four zero bytes, then the 8-byte label. `PS-Msg05` fills that label.
    static func nonce(label: String) -> Data {
        var nonce = Data(count: 12)
        let bytes = Array(label.utf8.prefix(8))
        for (offset, byte) in bytes.enumerated() {
            nonce[4 + offset] = byte
        }
        return nonce
    }

    static func nonce(counter: UInt64) -> Data {
        var nonce = Data(count: 12)
        var value = counter.littleEndian
        withUnsafeBytes(of: &value) { raw in
            nonce.replaceSubrange(4..<12, with: raw)
        }
        return nonce
    }

    static func seal(key: SymmetricKey, nonce: Data, aad: Data, plaintext: Data) throws -> Data {
        let box = try ChaChaPoly.seal(
            plaintext,
            using: key,
            nonce: try ChaChaPoly.Nonce(data: nonce),
            authenticating: aad
        )
        return box.ciphertext + box.tag
    }

    static func open(key: SymmetricKey, nonce: Data, aad: Data, ciphertextAndTag: Data) throws -> Data {
        guard ciphertextAndTag.count >= 16 else { throw HomeKitLampError.protocolError }
        let tagStart = ciphertextAndTag.index(ciphertextAndTag.endIndex, offsetBy: -16)
        let box = try ChaChaPoly.SealedBox(
            nonce: try ChaChaPoly.Nonce(data: nonce),
            ciphertext: ciphertextAndTag[..<tagStart],
            tag: ciphertextAndTag[tagStart...]
        )
        return try ChaChaPoly.open(box, using: key, authenticating: aad)
    }

    static func encryptFrames(key: SymmetricKey, counter: inout UInt64, plaintext: Data) throws -> Data {
        var output = Data()
        var offset = plaintext.startIndex
        while offset < plaintext.endIndex {
            let end = plaintext.index(offset, offsetBy: 1024, limitedBy: plaintext.endIndex) ?? plaintext.endIndex
            let chunk = plaintext[offset..<end]
            var length = UInt16(chunk.count).littleEndian
            let lengthBytes = Data(bytes: &length, count: 2)
            output.append(lengthBytes)
            output.append(try seal(key: key, nonce: nonce(counter: counter), aad: lengthBytes, plaintext: Data(chunk)))
            counter += 1
            offset = end
        }
        return output
    }

    static func decryptFrames(key: SymmetricKey, counter: inout UInt64, input: inout Data) throws -> Data {
        var output = Data()
        while input.count >= 2 {
            let start = input.startIndex
            let length = Int(input[start]) | (Int(input[input.index(after: start)]) << 8)
            let frame = 2 + length + 16
            guard frame >= 18, input.count >= frame else { break }
            let end = input.index(start, offsetBy: frame)
            let frameData = Data(input[start..<end])
            let aad = frameData.prefix(2)
            let body = frameData.dropFirst(2)
            output.append(try open(key: key, nonce: nonce(counter: counter), aad: Data(aad), ciphertextAndTag: Data(body)))
            counter += 1
            input.removeFirst(frame)
        }
        return output
    }
}

enum HomeKitLampError: Error {
    case protocolError
    case authentication
    case alreadyPaired
    case unreachable
}
