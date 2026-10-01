import Foundation

enum HomeKitTLV {
    static let method: UInt8 = 0x00
    static let identifier: UInt8 = 0x01
    static let salt: UInt8 = 0x02
    static let publicKey: UInt8 = 0x03
    static let proof: UInt8 = 0x04
    static let encryptedData: UInt8 = 0x05
    static let state: UInt8 = 0x06
    static let error: UInt8 = 0x07
    static let signature: UInt8 = 0x0A

    static func encode(_ items: [(UInt8, Data)]) -> Data {
        var out = Data()
        for (type, value) in items {
            var rest = value
            if rest.isEmpty {
                out.append(type)
                out.append(0)
                continue
            }
            while !rest.isEmpty {
                let chunk = rest.prefix(255)
                out.append(type)
                out.append(UInt8(chunk.count))
                out.append(contentsOf: chunk)
                rest.removeFirst(chunk.count)
            }
        }
        return out
    }

    static func decode(_ data: Data) -> [UInt8: Data] {
        var result: [UInt8: Data] = [:]
        var index = data.startIndex
        while index + 2 <= data.endIndex {
            let type = data[index]
            let length = Int(data[data.index(after: index)])
            let valueStart = data.index(index, offsetBy: 2)
            guard let valueEnd = data.index(valueStart, offsetBy: length, limitedBy: data.endIndex) else { break }
            result[type, default: Data()].append(data[valueStart..<valueEnd])
            index = valueEnd
        }
        return result
    }

    static func byte(_ value: UInt8) -> Data { Data([value]) }
}
