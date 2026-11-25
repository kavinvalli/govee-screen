import CoreBluetooth

/// H617A BLE frames: [kind, command, payload..., zero padding, xor checksum], 20 bytes.
/// Mirrors govee_protocol.py, which was checked byte-for-byte against app captures.
enum Govee {
    static let controlUUID = CBUUID(string: "00010203-0405-0607-0809-0a0b0c0d2b11")

    static let segmentCount = 15
    static let allSegments: UInt16 = 0x7FFF

    static func frame(_ command: UInt8, _ payload: [UInt8] = [], kind: UInt8 = 0x33) -> Data {
        var bytes = [kind, command] + payload
        bytes += Array(repeating: 0, count: 19 - bytes.count)
        bytes.append(bytes.reduce(0, ^))
        return Data(bytes)
    }

    static func power(_ on: Bool) -> Data { frame(0x01, [on ? 1 : 0]) }

    /// The H617A uses a 1–100 scale.
    static func brightness(_ percent: Int) -> Data { frame(0x04, [UInt8(max(1, min(100, percent)))]) }

    /// 33 05 15 01 R G B 00×5 <mask lo> <mask hi>: one colour on every segment in `mask`.
    static func segmentColor(_ c: RGB8, mask: UInt16) -> Data {
        frame(0x05, [0x15, 0x01, c.r, c.g, c.b, 0, 0, 0, 0, 0, UInt8(mask & 0xFF), UInt8(mask >> 8)])
    }

    /// Power-state query, used to keep an idle connection alive.
    static let keepalive = frame(0x01, kind: 0xAA)
}

struct RGB8: Equatable {
    var r, g, b: UInt8

    init(_ v: SIMD3<Float>) {
        let c = v.rounded(.toNearestOrAwayFromZero).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 255))
        r = UInt8(c.x); g = UInt8(c.y); b = UInt8(c.z)
    }

    func distance(_ o: RGB8) -> Int {
        max(abs(Int(r) - Int(o.r)), abs(Int(g) - Int(o.g)), abs(Int(b) - Int(o.b)))
    }
}
