import Foundation

// Protobuf by hand: six fields of one CASTV2 frame don't justify a protobuf runtime.
nonisolated struct CastMessage: Sendable {
    var source: String
    var destination: String
    var namespace: String
    var payload: String

    func framed() -> Data {
        var body: [UInt8] = []
        Self.appendVarintField(1, 0, to: &body)
        Self.appendStringField(2, source, to: &body)
        Self.appendStringField(3, destination, to: &body)
        Self.appendStringField(4, namespace, to: &body)
        Self.appendVarintField(5, 0, to: &body)
        Self.appendStringField(6, payload, to: &body)
        let length = UInt32(body.count).bigEndian
        return withUnsafeBytes(of: length) { Data($0) } + Data(body)
    }

    init(source: String, destination: String, namespace: String, payload: String) {
        self.source = source
        self.destination = destination
        self.namespace = namespace
        self.payload = payload
    }

    init?(body: ArraySlice<UInt8>) {
        var strings: [UInt64: String] = [:]
        var index = body.startIndex
        while index < body.endIndex {
            guard let key = Self.readVarint(body, &index) else { return nil }
            let field = key >> 3
            switch key & 7 {
            case 0:
                guard Self.readVarint(body, &index) != nil else { return nil }
            case 1:
                index += 8
            case 2:
                guard let length = Self.readVarint(body, &index),
                      let end = body.index(index, offsetBy: Int(length), limitedBy: body.endIndex) else { return nil }
                strings[field] = String(decoding: body[index..<end], as: UTF8.self)
                index = end
            case 5:
                index += 4
            default:
                return nil
            }
        }
        guard let namespace = strings[4] else { return nil }
        self.init(source: strings[2] ?? "", destination: strings[3] ?? "", namespace: namespace,
                  payload: strings[6] ?? "{}")
    }

    private static func appendVarint(_ value: UInt64, to bytes: inout [UInt8]) {
        var value = value
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
    }

    private static func appendVarintField(_ field: UInt64, _ value: UInt64, to bytes: inout [UInt8]) {
        appendVarint(field << 3, to: &bytes)
        appendVarint(value, to: &bytes)
    }

    private static func appendStringField(_ field: UInt64, _ value: String, to bytes: inout [UInt8]) {
        let utf8 = Array(value.utf8)
        appendVarint(field << 3 | 2, to: &bytes)
        appendVarint(UInt64(utf8.count), to: &bytes)
        bytes.append(contentsOf: utf8)
    }

    private static func readVarint(_ bytes: ArraySlice<UInt8>, _ index: inout ArraySlice<UInt8>.Index) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.endIndex, shift < 64 {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }
}
