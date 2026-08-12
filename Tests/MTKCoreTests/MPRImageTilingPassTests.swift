import Metal
import XCTest
@testable import MTKCore

final class MPRImageTilingPassTests: XCTestCase {
    func test_destinationRegions_partitionUnevenAtlasRowMajorWithoutGaps() {
        let regions = MPRImageTilingPass.destinationRegions(width: 5,
                                                            height: 3,
                                                            rows: 2,
                                                            columns: 2)

        XCTAssertEqual(regions.count, 4)
        assertRegion(regions[0], x: 0, y: 0, width: 2, height: 1)
        assertRegion(regions[1], x: 2, y: 0, width: 3, height: 1)
        assertRegion(regions[2], x: 0, y: 1, width: 2, height: 2)
        assertRegion(regions[3], x: 2, y: 1, width: 3, height: 2)
    }

    func test_makeAtlas_blitsCellsRowMajorAndClearsMissingCellsBlack() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        let pass = try MPRImageTilingPass(device: device,
                                         commandQueue: commandQueue)
        let textures: [(any MTLTexture)?] = [
            try makeUniformTexture(value: 10, device: device),
            try makeUniformTexture(value: 20, device: device),
            try makeUniformTexture(value: 30, device: device),
            nil
        ]

        let atlas = try await pass.makeAtlas(textures: textures,
                                             width: 4,
                                             height: 4,
                                             rows: 2,
                                             columns: 2)
        let bytes = try MPRTextureReadbackHelper.readBytes(from: atlas,
                                                          bytesPerPixel: 4,
                                                          device: device,
                                                          commandQueue: commandQueue)
        let blueValues = stride(from: 0, to: bytes.count, by: 4).map { bytes[$0] }

        XCTAssertEqual(blueValues, [
            10, 10, 20, 20,
            10, 10, 20, 20,
            30, 30, 0, 0,
            30, 30, 0, 0
        ])
    }

    private func assertRegion(_ region: MTLRegion,
                              x: Int,
                              y: Int,
                              width: Int,
                              height: Int,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        XCTAssertEqual(region.origin.x, x, file: file, line: line)
        XCTAssertEqual(region.origin.y, y, file: file, line: line)
        XCTAssertEqual(region.origin.z, 0, file: file, line: line)
        XCTAssertEqual(region.size.width, width, file: file, line: line)
        XCTAssertEqual(region.size.height, height, file: file, line: line)
        XCTAssertEqual(region.size.depth, 1, file: file, line: line)
    }

    private func makeUniformTexture(value: UInt8,
                                    device: any MTLDevice) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: 2,
                                                                  height: 2,
                                                                  mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pixel = [value, value, value, UInt8.max]
        let bytes = Array(repeating: pixel, count: 4).flatMap { $0 }
        texture.replace(region: MTLRegionMake2D(0, 0, 2, 2),
                        mipmapLevel: 0,
                        withBytes: bytes,
                        bytesPerRow: 8)
        return texture
    }
}
