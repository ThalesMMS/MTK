import Metal

@testable import MTKCore

enum MPRTextureReadbackHelper {
    enum ReadbackError: LocalizedError {
        case textureFormatMismatch(expected: MTLPixelFormat, actual: MTLPixelFormat)
        case invalidBytesPerPixel(VolumePixelFormat)
        case rowByteCountOverflow(width: Int, bytesPerPixel: Int)
        case totalByteCountOverflow(bytesPerRow: Int, height: Int)
        case valueTypeMismatch(expectedByteCount: Int, actualByteCount: Int, valueType: Any.Type)
        case commandQueueDeviceMismatch
        case textureDeviceMismatch
        case readbackBufferAllocationFailed(byteCount: Int)
        case commandBufferCreationFailed
        case blitEncoderCreationFailed
        case commandBufferFailed(String?)

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
            case .commandQueueDeviceMismatch:
                return "MPR texture readback command queue belongs to a different Metal device."
            case .textureDeviceMismatch:
                return "MPR texture readback source texture belongs to a different Metal device."
            case .readbackBufferAllocationFailed(let byteCount):
                return "MPR texture readback could not allocate a \(byteCount)-byte staging buffer."
            case .commandBufferCreationFailed:
                return "MPR texture readback could not create a command buffer."
            case .blitEncoderCreationFailed:
                return "MPR texture readback could not create a blit encoder."
            case .commandBufferFailed(let description):
                return "MPR texture readback command buffer failed: \(description ?? "unknown Metal error")"
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

    static func readValues<T>(_ type: T.Type,
                              from frame: MPRTextureFrame,
                              device: any MTLDevice,
                              commandQueue: any MTLCommandQueue) throws -> [T] {
        _ = type
        let expectedByteCount = frame.pixelFormat.bytesPerVoxel
        let actualByteCount = MemoryLayout<T>.size
        guard actualByteCount == expectedByteCount else {
            throw ReadbackError.valueTypeMismatch(expectedByteCount: expectedByteCount,
                                                  actualByteCount: actualByteCount,
                                                  valueType: T.self)
        }

        guard frame.textureFormatMatchesPixelFormat else {
            throw ReadbackError.textureFormatMismatch(expected: frame.pixelFormat.rawIntensityMetalPixelFormat,
                                                      actual: frame.texture.pixelFormat)
        }

        let bytes = try readBytes(from: frame.texture,
                                  bytesPerPixel: expectedByteCount,
                                  device: device,
                                  commandQueue: commandQueue)
        return bytes.withUnsafeBytes { buffer in
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

    static func readBytes(from texture: any MTLTexture,
                          bytesPerPixel: Int,
                          device: any MTLDevice,
                          commandQueue: any MTLCommandQueue) throws -> [UInt8] {
        guard (commandQueue.device as AnyObject) === (device as AnyObject) else {
            throw ReadbackError.commandQueueDeviceMismatch
        }
        guard (texture.device as AnyObject) === (device as AnyObject) else {
            throw ReadbackError.textureDeviceMismatch
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
        let byteCount = totalByteCount.partialValue
        guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
            throw ReadbackError.readbackBufferAllocationFailed(byteCount: byteCount)
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw ReadbackError.commandBufferCreationFailed
        }
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw ReadbackError.blitEncoderCreationFailed
        }

        blitEncoder.copy(from: texture,
                         sourceSlice: 0,
                         sourceLevel: 0,
                         sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                         sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                         to: buffer,
                         destinationOffset: 0,
                         destinationBytesPerRow: bytesPerRow,
                         destinationBytesPerImage: byteCount)
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw ReadbackError.commandBufferFailed(error.localizedDescription)
        }

        let pointer = buffer.contents().assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: pointer, count: byteCount))
    }
}
