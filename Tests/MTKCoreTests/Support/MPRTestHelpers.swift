import XCTest
import simd

@testable import MTKCore

enum MPRTestHelpers {
    static func assertValidSlice(_ slice: MPRSlice,
                                 expectedWidth: Int,
                                 expectedHeight: Int,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        XCTAssertEqual(slice.width, expectedWidth, file: file, line: line)
        XCTAssertEqual(slice.height, expectedHeight, file: file, line: line)
        XCTAssertFalse(slice.pixels.isEmpty, file: file, line: line)
        XCTAssertGreaterThan(slice.bytesPerRow, 0, file: file, line: line)
    }

    static func makeTestPlaneGeometry(for dataset: VolumeDataset,
                                      axis: MPRPlaneAxis = .z) -> MPRPlaneGeometry {
        let dims = dataset.dimensions
        let centerVoxel = SIMD3<Float>(
            Float(dims.width) / 2.0,
            Float(dims.height) / 2.0,
            Float(dims.depth) / 2.0
        )

        let (axisU, axisV, normal): (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
        switch axis {
        case .x:
            axisU = SIMD3<Float>(0, Float(dims.height), 0)
            axisV = SIMD3<Float>(0, 0, Float(dims.depth))
            normal = SIMD3<Float>(1, 0, 0)
        case .y:
            axisU = SIMD3<Float>(Float(dims.width), 0, 0)
            axisV = SIMD3<Float>(0, 0, Float(dims.depth))
            normal = SIMD3<Float>(0, 1, 0)
        case .z:
            axisU = SIMD3<Float>(Float(dims.width), 0, 0)
            axisV = SIMD3<Float>(0, Float(dims.height), 0)
            normal = SIMD3<Float>(0, 0, 1)
        }

        let dimsFloat = SIMD3<Float>(Float(dims.width), Float(dims.height), Float(dims.depth))
        let originVoxel = centerVoxel - axisU / 2 - axisV / 2
        let originTexture = originVoxel / dimsFloat
        let axisUTexture = axisU / dimsFloat
        let axisVTexture = axisV / dimsFloat

        return MPRPlaneGeometry(
            originVoxel: originVoxel,
            axisUVoxel: axisU,
            axisVVoxel: axisV,
            originWorld: originVoxel,
            axisUWorld: axisU,
            axisVWorld: axisV,
            originTexture: originTexture,
            axisUTexture: axisUTexture,
            axisVTexture: axisVTexture,
            normalWorld: normal
        )
    }
}
