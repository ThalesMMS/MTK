import Foundation

enum DatasetContentFingerprint {
    private static let fnvOffsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let fnvPrime: UInt64 = 1_099_511_628_211
    private static let fullHashLimit = 1_048_576
    private static let edgeSampleByteCount = 65_536
    private static let interiorSampleCount = 4_096

    static func make(for data: Data) -> UInt64 {
        data.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            guard !bytes.isEmpty else {
                return fnvOffsetBasis
            }

            if bytes.count <= fullHashLimit {
                return makeFullHash(bytes)
            }

            var hash = fnvOffsetBasis
            let edgeCount = min(edgeSampleByteCount, bytes.count / 4)
            mix(bytes: bytes, range: 0..<edgeCount, into: &hash)

            let tailStart = bytes.count - edgeCount
            if tailStart > edgeCount {
                mix(bytes: bytes, range: tailStart..<bytes.count, into: &hash)
            }

            let interiorStart = edgeCount
            let interiorEnd = tailStart
            if interiorEnd > interiorStart {
                let stride = max(1, (interiorEnd - interiorStart) / interiorSampleCount)
                var index = interiorStart
                while index < interiorEnd {
                    mix(byte: bytes[index], into: &hash)
                    index += stride
                }
            }

            return hash
        }
    }

    private static func makeFullHash(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt64 {
        var hash = fnvOffsetBasis
        for byte in bytes {
            mix(byte: byte, into: &hash)
        }
        return hash
    }

    private static func mix(bytes: UnsafeBufferPointer<UInt8>,
                            range: Range<Int>,
                            into hash: inout UInt64) {
        for index in range {
            mix(byte: bytes[index], into: &hash)
        }
    }

    private static func mix(byte: UInt8,
                            into hash: inout UInt64) {
        hash ^= UInt64(byte)
        hash &*= fnvPrime
    }
}
