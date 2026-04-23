import Metal

@testable import MTKCore

enum MPRTextureReadbackHelper {
    enum ReadbackError: LocalizedError {
        case textureFormatMismatch(expected: MTLPixelFormat, actual: MTLPixelFormat)
        case invalidBytesPerPixel(VolumePixelFormat)
        case rowByteCountOverflow(width: Int, bytesPerPixel: Int)
        case totalByteCountOverflow(bytesPerRow: Int, height: Int)
        case valueTypeMismatch(expectedByteCount: Int, actualByteCount: Int, valueType: Any.Type)

        var errorDescription: String? {
            switch self {
            case .textureFormatMismatch(let expected, let actual):
                return "MPRTextureFrame pixel format does not match texture format (expected \(expected), got \(actual))"
            case .invalidBytesPerPixel(let pixelFormat):
                return "MPRTextureFrame pixel format \(pixelFormat) does not define a valid byte width"
            case .rowByteCountOverflow(let width, let bytesPerPixel):
                return "MPRTextureFrame row byte count overflowed for width \(width) and \(bytesPerPixel) bytes per pixel"
            case .totalByteCountOverflow(let bytesPerRow, let height):
                return "MPRTextureFrame total byte count overflowed for \(bytesPerRow) bytes per row and height \(height)"
            case .valueTypeMismatch(let expectedByteCount, let actualByteCount, let valueType):
                return "MPRTextureFrame stores \(expectedByteCount)-byte pixels but \(valueType) uses \(actualByteCount) bytes"
            }
        }
    }

    static func readBytes(from frame: MPRTextureFrame) throws -> [UInt8] {
        guard frame.textureFormatMatchesPixelFormat else {
            throw ReadbackError.textureFormatMismatch(expected: frame.pixelFormat.rawIntensityMetalPixelFormat,
                                                      actual: frame.texture.pixelFormat)
        }

        let texture = frame.texture
        let bytesPerPixel = frame.pixelFormat.bytesPerVoxel
        guard bytesPerPixel > 0 else {
            throw ReadbackError.invalidBytesPerPixel(frame.pixelFormat)
        }

        let rowByteCount = texture.width.multipliedReportingOverflow(by: bytesPerPixel)
        guard !rowByteCount.overflow else {
            throw ReadbackError.rowByteCountOverflow(width: texture.width,
                                                     bytesPerPixel: bytesPerPixel)
        }

        let totalByteCount = rowByteCount.partialValue.multipliedReportingOverflow(by: texture.height)
        guard !totalByteCount.overflow else {
            throw ReadbackError.totalByteCountOverflow(bytesPerRow: rowByteCount.partialValue,
                                                       height: texture.height)
        }

        let bytesPerRow = rowByteCount.partialValue
        return readBytes(from: texture,
                         bytesPerRow: bytesPerRow,
                         byteCount: totalByteCount.partialValue)
    }

    static func readValues<T>(_ type: T.Type, from frame: MPRTextureFrame) throws -> [T] {
        _ = type
        let expectedByteCount = frame.pixelFormat.bytesPerVoxel
        let actualByteCount = MemoryLayout<T>.size
        guard actualByteCount == expectedByteCount else {
            throw ReadbackError.valueTypeMismatch(expectedByteCount: expectedByteCount,
                                                  actualByteCount: actualByteCount,
                                                  valueType: T.self)
        }
        return try readBytes(from: frame).withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: T.self))
        }
    }

    static func readBytes(from texture: any MTLTexture,
                          bytesPerRow: Int,
                          byteCount: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        texture.getBytes(&bytes,
                         bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                         mipmapLevel: 0)
        return bytes
    }
}
