import XCTest
@testable import MTKCore

final class MTKCoreTests: XCTestCase {
    func testVolumeDatasetScaleMatchesDimensions() {
        let dataset = VolumeDataset(
            data: Data(count: 4),
            dimensions: VolumeDimensions(width: 2, height: 1, depth: 2),
            spacing: VolumeSpacing(x: 0.5, y: 1.0, z: 2.0),
            pixelFormat: .int16Unsigned
        )

        XCTAssertEqual(dataset.scale.x, dataset.spacing.x * Double(dataset.dimensions.width))
        XCTAssertEqual(dataset.scale.y, dataset.spacing.y * Double(dataset.dimensions.height))
        XCTAssertEqual(dataset.scale.z, dataset.spacing.z * Double(dataset.dimensions.depth))
    }

    func testTransferFunctionPresetAvailability() {
        let transfer = VolumeTransferFunctionLibrary.transferFunction(for: VolumeRenderingBuiltinPreset.ctEntire)
        XCTAssertNotNil(transfer)
    }
}
