enum FECFixtureEncoder {
    static let audioMatrix: [[UInt8]] = [
        [0x77, 0x40, 0x38, 0x0e],
        [0xc7, 0xa7, 0x0d, 0x6c],
    ]

    static func videoParity(data: [[UInt8]], parityShards: Int) -> [[UInt8]] {
        let matrix = (0..<parityShards).map { row in
            (0..<data.count).map { column in
                inverse(UInt8((parityShards + column) ^ row))
            }
        }
        return parity(data: data, matrix: matrix)
    }

    static func parity(data: [[UInt8]], matrix: [[UInt8]]) -> [[UInt8]] {
        guard let shardSize = data.first?.count else { return [] }
        return matrix.map { row in
            (0..<shardSize).map { byte in
                zip(row, data).reduce(UInt8(0)) { result, pair in
                    result ^ multiply(pair.0, pair.1[byte])
                }
            }
        }
    }

    private static func inverse(_ value: UInt8) -> UInt8 {
        power(value, exponent: 254)
    }

    private static func power(_ value: UInt8, exponent: Int) -> UInt8 {
        var result: UInt8 = 1
        var factor = value
        var exponent = exponent
        while exponent > 0 {
            if exponent & 1 == 1 { result = multiply(result, factor) }
            factor = multiply(factor, factor)
            exponent >>= 1
        }
        return result
    }

    private static func multiply(_ lhs: UInt8, _ rhs: UInt8) -> UInt8 {
        var result: UInt8 = 0
        var left = lhs
        var right = rhs
        for _ in 0..<8 {
            if right & 1 == 1 { result ^= left }
            let carry = left & 0x80
            left &<<= 1
            if carry != 0 { left ^= 0x1d }
            right >>= 1
        }
        return result
    }
}
