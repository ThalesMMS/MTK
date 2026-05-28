import CoreGraphics
import MTKCore
@testable import MTKUI
import XCTest

final class Volume3DBrushToolTests: XCTestCase {
    func testBrushStateClampsSizeAndPreservesMode() {
        let small = VolumeBrushState(isEnabled: true,
                                     brushSizeMM: -10,
                                     mode: .restore)
        let large = VolumeBrushState(brushSizeMM: 500)

        XCTAssertTrue(small.isEnabled)
        XCTAssertEqual(small.brushSizeMM, VolumeBrushState.minimumBrushSizeMM)
        XCTAssertEqual(small.mode, .restore)
        XCTAssertEqual(large.brushSizeMM, VolumeBrushState.maximumBrushSizeMM)
    }

    func testBrushMaskEraseAndRestoreSignedVoxelData() throws {
        let dataset = makeBrushDataset()

        let erased = try VolumeBrushMask.applyingStroke(to: dataset,
                                                        centerVoxel: SIMD3<Float>(2, 2, 2),
                                                        brushSizeMM: 3,
                                                        mode: .erase)
        XCTAssertGreaterThan(erased.affectedVoxelCount, 1)
        XCTAssertEqual(voxelValue(erased.dataset, x: 2, y: 2, z: 2), 0)
        XCTAssertEqual(voxelValue(erased.dataset, x: 0, y: 0, z: 0), 100)

        let restored = try VolumeBrushMask.applyingStroke(to: dataset,
                                                          existingMaskedData: erased.dataset.data,
                                                          centerVoxel: SIMD3<Float>(2, 2, 2),
                                                          brushSizeMM: 3,
                                                          mode: .restore)
        XCTAssertEqual(voxelValue(restored.dataset, x: 2, y: 2, z: 2), 100)
    }

    func testBrushCursorRadiusScalesWithBrushSize() {
        let size = CGSize(width: 300, height: 600)
        let small = Volume3DBrushCursorLayout.screenRadius(brushSizeMM: 20,
                                                           viewportSize: size)
        let large = Volume3DBrushCursorLayout.screenRadius(brushSizeMM: 80,
                                                           viewportSize: size)

        XCTAssertGreaterThan(large, small)
        XCTAssertGreaterThanOrEqual(small, 8)
    }
}

private func makeBrushDataset() -> VolumeDataset {
    let values = [Int16](repeating: 100, count: 125)
    return VolumeDataset(
        data: values.withUnsafeBytes { Data($0) },
        dimensions: VolumeDimensions(width: 5, height: 5, depth: 5),
        spacing: VolumeSpacing(x: 1, y: 1, z: 1),
        pixelFormat: .int16Signed,
        intensityRange: 0...100
    )
}

private func voxelValue(_ dataset: VolumeDataset,
                        x: Int,
                        y: Int,
                        z: Int) -> Int16 {
    let linear = (z * dataset.dimensions.height + y) * dataset.dimensions.width + x
    return dataset.data.withUnsafeBytes { rawBuffer in
        rawBuffer.bindMemory(to: Int16.self)[linear]
    }
}
