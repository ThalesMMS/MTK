import XCTest
import Metal
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

    @MainActor
    func testAllBuiltinPresetsLoadFromBundleResources() throws {
        let allPresets = VolumeRenderingBuiltinPreset.allCases
        XCTAssertFalse(allPresets.isEmpty)

        let device = MTLCreateSystemDefaultDevice()
        let metalAvailable = device != nil

        for preset in allPresets {
            let filename = preset.filename
            XCTAssertFalse(filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            guard let transfer = TransferFunctionPresetLoader.load(preset) else {
                XCTFail("Failed to load preset \(preset.rawValue) (\(filename).tf) from bundle resources")
                continue
            }

            XCTAssertFalse(transfer.name.isEmpty,
                           "Preset \(preset.rawValue) has empty name")
            XCTAssertFalse(transfer.colourPoints.isEmpty,
                           "Preset \(preset.rawValue) has no colour points")
            XCTAssertFalse(transfer.alphaPoints.isEmpty,
                           "Preset \(preset.rawValue) has no alpha points")
            XCTAssertLessThan(transfer.minimumValue, transfer.maximumValue,
                              "Preset \(preset.rawValue) has invalid range (\(transfer.minimumValue) >= \(transfer.maximumValue))")

            if metalAvailable, let device = device {
                let texture = transfer.makeTexture(device: device)
                XCTAssertNotNil(texture,
                                "Failed to create Metal texture for preset \(preset.rawValue)")
                if let texture = texture {
                    XCTAssertGreaterThan(texture.width, 0,
                                         "Preset \(preset.rawValue) created texture with zero width")
                    XCTAssertGreaterThan(texture.height, 0,
                                         "Preset \(preset.rawValue) created texture with zero height")
                }
            }
        }
    }
}
