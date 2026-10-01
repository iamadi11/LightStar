import CryptoKit
import Foundation
import BigInt

/// HomeKit pair-setup SRP-6a, 3072-bit group, SHA-512.
/// Public values are padded to the width of N, matching the HAP pairing buffer.
enum HomeKitSRP {
    static let modulusBytes = 384
    static let modulus = BigUInt(modulusHex, radix: 16)!
    static let generator = BigUInt(5)

    static func pad(_ value: BigUInt, width: Int = modulusBytes) -> Data {
        let raw = value.serialize()
        if raw.count >= width { return Data(raw.suffix(width)) }
        return Data(count: width - raw.count) + raw
    }

    static func setupCode(_ raw: String) -> String? {
        let digits = raw.filter(\.isNumber)
        guard digits.count == 8 else { return nil }
        let chars = Array(digits)
        return "\(chars[0])\(chars[1])\(chars[2])-\(chars[3])\(chars[4])-\(chars[5])\(chars[6])\(chars[7])"
    }
}

struct HomeKitSRPClient {
    let username: String
    let password: String
    private let privateExponent: BigUInt
    let clientPublic: BigUInt
    private var salt = Data()
    private var serverPublic = BigUInt(0)
    private var sessionKey = Data()

    init(username: String = "Pair-Setup", password: String, privateExponent: BigUInt? = nil) {
        self.username = username
        self.password = password
        let secret = privateExponent ?? BigUInt(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        self.privateExponent = secret
        self.clientPublic = HomeKitSRP.generator.power(secret, modulus: HomeKitSRP.modulus)
    }

    var clientPublicBytes: Data { HomeKitSRP.pad(clientPublic) }

    mutating func setServer(salt: Data, publicKey: Data) {
        self.salt = salt
        self.serverPublic = BigUInt(publicKey)
        let shared = sharedSecret()
        sessionKey = Data(SHA512.hash(data: HomeKitSRP.pad(shared)))
    }

    func clientProof() -> Data {
        var hash = SHA512()
        hash.update(data: hNxorHg())
        hash.update(data: Data(SHA512.hash(data: Data(username.utf8))))
        hash.update(data: salt)
        hash.update(data: clientPublicBytes)
        hash.update(data: HomeKitSRP.pad(serverPublic))
        hash.update(data: sessionKey)
        return Data(hash.finalize())
    }

    func verifyServerProof(_ proof: Data) -> Bool {
        var hash = SHA512()
        hash.update(data: clientPublicBytes)
        hash.update(data: clientProof())
        hash.update(data: sessionKey)
        return Data(hash.finalize()) == proof
    }

    var sessionKeyBytes: Data { sessionKey }

    private func sharedSecret() -> BigUInt {
        let u = hashInteger(clientPublicBytes + HomeKitSRP.pad(serverPublic))
        let x = passwordExponent()
        let k = multiplier()
        let gx = HomeKitSRP.generator.power(x, modulus: HomeKitSRP.modulus)
        var base = serverPublic
        let kgx = (k * gx) % HomeKitSRP.modulus
        if base >= kgx {
            base -= kgx
        } else {
            base = base + HomeKitSRP.modulus - kgx
        }
        let exponent = privateExponent + (u * x)
        return base.power(exponent, modulus: HomeKitSRP.modulus)
    }

    private func passwordExponent() -> BigUInt {
        let inner = Data(SHA512.hash(data: Data("\(username):\(password)".utf8)))
        return hashInteger(salt + inner)
    }

    private func multiplier() -> BigUInt {
        hashInteger(HomeKitSRP.pad(HomeKitSRP.modulus) + HomeKitSRP.pad(HomeKitSRP.generator))
    }

    private func hNxorHg() -> Data {
        let n = Data(SHA512.hash(data: HomeKitSRP.pad(HomeKitSRP.modulus)))
        // HomeKit hashes g as its minimal bytes. Padding it to N makes the proof fail.
        let g = Data(SHA512.hash(data: Data([UInt8(HomeKitSRP.generator)])))
        return Data(zip(n, g).map { $0 ^ $1 })
    }

    private func hashInteger(_ data: Data) -> BigUInt {
        BigUInt(Data(SHA512.hash(data: data)))
    }
}

private let modulusHex = """
FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B\
302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE6\
49286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D\
670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718\
3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7D\
B3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200C\
BBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
"""
