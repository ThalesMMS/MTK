import CoreGraphics
import Metal
import XCTest

@_spi(Testing) @testable import MTKCore

class MTKRenderingEngineTestCase: XCTestCase {
    var engine: MTKRenderingEngine!
    var testDataset: VolumeDataset!

    override func setUp() async throws {
        try await super.setUp()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        engine = try await MTKRenderingEngine(device: device)
        testDataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 8, height: 8, depth: 8),
            pixelFormat: .int16Signed
        )
    }

    override func tearDown() async throws {
        engine = nil
        testDataset = nil
        try await super.tearDown()
    }
}
