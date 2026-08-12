import Metal
import XCTest
@_spi(Testing) @testable import MTKCore

final class MetalCPRAdapterTests: XCTestCase {
    func test_renderStretchedAndPerpendicularFrames_usesBundledMetalKernels() async throws {
        let device = try makeTestMetalDevice()
        guard let commandQueue = device.makeCommandQueue() else {
            return XCTFail("Metal command queue unavailable")
        }
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRPlaneGeometryFactory.makePlane(for: dataset,
                                                      axis: .z,
                                                      slicePosition: 0.5)
        let path = try CPRPathSampler.sample(
            controlPointsWorld: [
                plane.originWorld + 0.1 * plane.axisUWorld + 0.5 * plane.axisVWorld,
                plane.originWorld + 0.5 * plane.axisUWorld + 0.65 * plane.axisVWorld,
                plane.originWorld + 0.9 * plane.axisUWorld + 0.5 * plane.axisVWorld
            ],
            spacingMillimeters: 1
        )
        let adapter = try MetalCPRAdapter(device: device)

        let stretched = try await adapter.makeStretchedTextureFrame(
            dataset: dataset,
            path: path,
            authoringPlane: plane,
            outputWidth: 32,
            outputHeight: 24
        )
        defer { stretched.debugReleaseOutputTextureLease() }
        let crossSection = try await adapter.makePerpendicularTextureFrame(
            dataset: dataset,
            path: path,
            progress: 0.5,
            outputSize: 16
        )
        defer { crossSection.debugReleaseOutputTextureLease() }

        XCTAssertEqual(stretched.texture.width, 32)
        XCTAssertEqual(stretched.texture.height, 24)
        XCTAssertEqual(crossSection.texture.width, 16)
        XCTAssertEqual(crossSection.texture.height, 16)
        let stretchedValues: [UInt16] = try MPRTextureReadbackHelper.readValues(
            UInt16.self,
            from: stretched,
            device: device,
            commandQueue: commandQueue
        )
        let crossSectionValues: [UInt16] = try MPRTextureReadbackHelper.readValues(
            UInt16.self,
            from: crossSection,
            device: device,
            commandQueue: commandQueue
        )
        XCTAssertEqual(stretchedValues.count, 32 * 24)
        XCTAssertEqual(crossSectionValues.count, 16 * 16)
    }
}
