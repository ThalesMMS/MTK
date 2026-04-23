import Metal
import QuartzCore
import XCTest
import simd

@testable import MTKCore

enum MPRTestHelpers {
    static func assertValidFrame(_ frame: MPRTextureFrame,
                                 expectedWidth: Int,
                                 expectedHeight: Int,
                                 expectedPixelFormat: VolumePixelFormat? = nil,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        XCTAssertEqual(frame.texture.width, expectedWidth, file: file, line: line)
        XCTAssertEqual(frame.texture.height, expectedHeight, file: file, line: line)
        XCTAssertTrue(frame.textureFormatMatchesPixelFormat, file: file, line: line)
        XCTAssertNoThrow(try MPRTextureReadbackHelper.readBytes(from: frame), file: file, line: line)
        if let expectedPixelFormat {
            XCTAssertEqual(frame.pixelFormat, expectedPixelFormat, file: file, line: line)
        }
    }

    static func makeTestPlaneGeometry(for dataset: VolumeDataset,
                                      axis: MPRPlaneAxis = .z) -> MPRPlaneGeometry {
        MPRPlaneGeometryFactory.makePlane(for: dataset,
                                          axis: axis,
                                          slicePosition: 0.5)
    }

    static func makeSignedTexture(_ values: [Int16],
                                  width: Int,
                                  height: Int,
                                  device: any MTLDevice) throws -> any MTLTexture {
        try makeInputTexture(values,
                             width: width,
                             height: height,
                             pixelFormat: .r16Sint,
                             device: device)
    }

    static func makeUnsignedTexture(_ values: [UInt16],
                                    width: Int,
                                    height: Int,
                                    device: any MTLDevice) throws -> any MTLTexture {
        try makeInputTexture(values,
                             width: width,
                             height: height,
                             pixelFormat: .r16Uint,
                             device: device)
    }

    static func makeInputTexture<T>(_ values: [T],
                                    width: Int,
                                    height: Int,
                                    pixelFormat: MTLPixelFormat,
                                    device: any MTLDevice) throws -> any MTLTexture {
        precondition(!values.isEmpty, "values must not be empty")
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        values.withUnsafeBytes { buffer in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0,
                            withBytes: buffer.baseAddress!,
                            bytesPerRow: width * MemoryLayout<T>.stride)
        }
        return texture
    }

    static func makeColormapTexture(_ values: [SIMD4<Float>],
                                    device: any MTLDevice) throws -> any MTLTexture {
        precondition(!values.isEmpty, "values must not be empty")
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                                                                  width: values.count,
                                                                  height: 1,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        values.withUnsafeBytes { buffer in
            texture.replace(region: MTLRegionMake2D(0, 0, values.count, 1),
                            mipmapLevel: 0,
                            withBytes: buffer.baseAddress!,
                            bytesPerRow: values.count * MemoryLayout<SIMD4<Float>>.stride)
        }
        return texture
    }

    static func makeFrame(texture: any MTLTexture,
                          pixelFormat: VolumePixelFormat,
                          intensityRange: ClosedRange<Int32>) -> MPRTextureFrame {
        MPRTextureFrame(texture: texture,
                        intensityRange: intensityRange,
                        pixelFormat: pixelFormat,
                        planeGeometry: MPRPlaneGeometry(
                            originVoxel: .zero,
                            axisUVoxel: SIMD3<Float>(Float(texture.width), 0, 0),
                            axisVVoxel: SIMD3<Float>(0, Float(texture.height), 0),
                            originWorld: .zero,
                            axisUWorld: SIMD3<Float>(Float(texture.width), 0, 0),
                            axisVWorld: SIMD3<Float>(0, Float(texture.height), 0),
                            originTexture: .zero,
                            axisUTexture: SIMD3<Float>(1, 0, 0),
                            axisVTexture: SIMD3<Float>(0, 1, 0),
                            normalWorld: SIMD3<Float>(0, 0, 1)
                        ))
    }

    static func readGrayBytes(from texture: any MTLTexture) throws -> [UInt8] {
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(&bytes,
                         bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                         mipmapLevel: 0)
        return stride(from: 0, to: bytes.count, by: 4).map { offset in
            bytes[offset]
        }
    }

    static func readBGRAByteArrays(from texture: any MTLTexture) throws -> [[UInt8]] {
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(&bytes,
                         bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                         mipmapLevel: 0)
        return stride(from: 0, to: bytes.count, by: 4).map { offset in
            Array(bytes[offset..<(offset + 4)])
        }
    }

    static func readBGRAPixels(from texture: any MTLTexture) throws -> [(UInt8, UInt8, UInt8, UInt8)] {
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(&bytes,
                         bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                         mipmapLevel: 0)
        return stride(from: 0, to: bytes.count, by: 4).map { offset in
            (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
        }
    }

    static func readInputValues<T>(_ type: T.Type, from texture: any MTLTexture) throws -> [T] {
        let bytesPerRow = texture.width * MemoryLayout<T>.stride
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(&bytes,
                         bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                         mipmapLevel: 0)
        return bytes.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: T.self))
        }
    }

    static func readInputValues<T>(_ type: T.Type, from frame: MPRTextureFrame) throws -> [T] {
        try MPRTextureReadbackHelper.readValues(type, from: frame)
    }

    static func waitForQueue(_ commandQueue: any MTLCommandQueue) throws {
        let commandBuffer = try XCTUnwrap(commandQueue.makeCommandBuffer())
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw error
        }
    }
}

final class MPRTestMetalDrawable: NSObject, CAMetalDrawable {
    let texture: any MTLTexture
    let layer: CAMetalLayer
    let presentedTime: CFTimeInterval = 0
    let drawableID: Int = 0

    init(device: any MTLDevice, width: Int, height: Int) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .shared
        texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.drawableSize = CGSize(width: width, height: height)
        super.init()
    }

    @objc
    func present() {}

    @objc(presentAtTime:)
    func present(at presentationTime: CFTimeInterval) {
        _ = presentationTime
    }

    @objc
    func present(afterMinimumDuration duration: CFTimeInterval) {
        _ = duration
    }

    @objc
    func addPresentedHandler(_ block: @escaping MTLDrawablePresentedHandler) {
        block(self)
    }

    @objc
    func addPresentScheduledHandler(_ block: @escaping MTLDrawablePresentedHandler) {
        block(self)
    }
}

func XCTAssertEqual(_ actual: [UInt8],
                    _ expected: [UInt8],
                    accuracy: UInt8,
                    file: StaticString = #filePath,
                    line: UInt = #line) {
    XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    for (index, pair) in zip(actual, expected).enumerated() {
        XCTAssertLessThanOrEqual(abs(Int(pair.0) - Int(pair.1)),
                                 Int(accuracy),
                                 "Mismatch at byte \(index): \(actual) != \(expected)",
                                 file: file,
                                 line: line)
    }
}
