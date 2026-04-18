import XCTest
import Metal
@testable import MTKCore

final class VolumeTextureFactoryPresetLoadingTests: XCTestCase {
    func testNonePresetReportsNoDataAvailable() {
        XCTAssertThrowsError(try VolumeTextureFactory(preset: .none)) { error in
            guard case VolumeTextureFactory.PresetLoadingError.noDataAvailable(let preset) = error else {
                XCTFail("Expected noDataAvailable, got \(error)")
                return
            }
            XCTAssertEqual(preset, "none")
        }
    }

    func testDicomPresetReportsNoDataAvailable() {
        XCTAssertThrowsError(try VolumeTextureFactory(preset: .dicom)) { error in
            guard case VolumeTextureFactory.PresetLoadingError.noDataAvailable(let preset) = error else {
                XCTFail("Expected noDataAvailable, got \(error)")
                return
            }
            XCTAssertEqual(preset, "dicom")
        }
    }

    func testMissingHeadPresetReportsResourceNotBundledOrLoadsRealResource() throws {
        do {
            let factory = try VolumeTextureFactory(preset: .head)
            XCTAssertNotEqual(factory.dataset.dimensions.width, 1)
            XCTAssertNotEqual(factory.dataset.dimensions.height, 1)
            XCTAssertNotEqual(factory.dataset.dimensions.depth, 1)
        } catch VolumeTextureFactory.PresetLoadingError.resourceNotBundled(let preset) {
            XCTAssertEqual(preset, "head")
        } catch {
            XCTFail("Expected resourceNotBundled or a real bundled dataset, got \(error)")
        }
    }

    func testDebugPlaceholderDatasetIsExplicitMinimalStub() {
        let dataset = VolumeTextureFactory.debugPlaceholderDataset()

        XCTAssertEqual(dataset.dimensions.width, 1)
        XCTAssertEqual(dataset.dimensions.height, 1)
        XCTAssertEqual(dataset.dimensions.depth, 1)
        XCTAssertEqual(dataset.data.count, VolumePixelFormat.int16Signed.bytesPerVoxel)
        XCTAssertEqual(dataset.pixelFormat, .int16Signed)
        XCTAssertEqual(dataset.intensityRange, (-1024)...3071)
    }

    func testMetalRaycasterPropagatesPresetLoadingError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        let raycaster: MetalRaycaster
        do {
            raycaster = try MetalRaycaster(device: device)
        } catch {
            throw XCTSkip("Failed to create MetalRaycaster: \(error)")
        }

        XCTAssertThrowsError(try raycaster.loadBuiltinDataset(for: .none, includeAccelerationStructure: true)) { error in
            guard case VolumeTextureFactory.PresetLoadingError.noDataAvailable(let preset) = error else {
                XCTFail("Expected noDataAvailable, got \(error)")
                return
            }
            XCTAssertEqual(preset, "none")
        }
    }
}
