import CoreGraphics
import Foundation
import Metal
import simd
import XCTest
@_spi(Testing) import MTKCore
@testable import MTKUI

@MainActor
final class Volume3DOrientationTests: XCTestCase {
    func testAnatomicalOrientationCameraAxesUseDICOMLPSForCanonicalDataset() {
        let dataset = VolumeRenderRegressionFixture.dataset()

        assertCameraAxes(for: .anterior,
                         dataset: dataset,
                         expectedNormal: SIMD3<Float>(0, -1, 0),
                         expectedUp: SIMD3<Float>(0, 0, 1))
        assertCameraAxes(for: .posterior,
                         dataset: dataset,
                         expectedNormal: SIMD3<Float>(0, 1, 0),
                         expectedUp: SIMD3<Float>(0, 0, 1))
        assertCameraAxes(for: .superior,
                         dataset: dataset,
                         expectedNormal: SIMD3<Float>(0, 0, 1),
                         expectedUp: SIMD3<Float>(0, -1, 0))
        assertCameraAxes(for: .inferior,
                         dataset: dataset,
                         expectedNormal: SIMD3<Float>(0, 0, -1),
                         expectedUp: SIMD3<Float>(0, -1, 0))
        assertCameraAxes(for: .left,
                         dataset: dataset,
                         expectedNormal: SIMD3<Float>(1, 0, 0),
                         expectedUp: SIMD3<Float>(0, 0, 1))
        assertCameraAxes(for: .right,
                         dataset: dataset,
                         expectedNormal: SIMD3<Float>(-1, 0, 0),
                         expectedUp: SIMD3<Float>(0, 0, 1))
    }

    func testSetCameraOrientationPreservesVolumeState() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable for VolumeViewport3D camera orientation test.")
        }
        let dataset = VolumeRenderRegressionFixture.dataset()
        let viewport = try VolumeViewport3D(device: device,
                                            surface: try makeSurface(device: device))
        await viewport.applyDataset(dataset)
        await viewport.setWindowLevel(window: 400, level: 40)
        let clipping = try VolumeClippingState(
            cropBox: VolumeCropBox(textureMin: SIMD3<Float>(0.1, 0.1, 0.1),
                                   textureMax: SIMD3<Float>(0.9, 0.9, 0.9))
        )
        try await viewport.setVolumeClipping(clipping)
        await viewport.setVolumeLayers([try makeLabelmapLayer(for: dataset)])

        let stateBefore = viewport.state
        let layerIDsBefore = viewport.volumeLayers.map(\.id)

        await viewport.setCameraOrientation(.left)

        XCTAssertNotEqual(viewport.state.camera.position, stateBefore.camera.position)
        XCTAssertEqual(viewport.state.windowLevel, stateBefore.windowLevel)
        XCTAssertEqual(viewport.state.clipping, clipping)
        XCTAssertEqual(viewport.volumeLayers.map(\.id), layerIDsBefore)
        XCTAssertEqual(viewport.state.dataset, stateBefore.dataset)
    }

    private func assertCameraAxes(for orientation: Volume3DAnatomicalOrientation,
                                  dataset: VolumeDataset,
                                  expectedNormal: SIMD3<Float>,
                                  expectedUp: SIMD3<Float>,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        let axes = orientation.cameraAxes(for: dataset)

        assertVector(axes.normal, expectedNormal, file: file, line: line)
        assertVector(axes.up, expectedUp, file: file, line: line)
        XCTAssertEqual(simd_dot(axes.normal, axes.up), 0, accuracy: 0.0001, file: file, line: line)
    }

    private func assertVector(_ actual: SIMD3<Float>,
                              _ expected: SIMD3<Float>,
                              accuracy: Float = 0.0001,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
    }

    private func makeSurface(device: any MTLDevice) throws -> MetalViewportSurface {
        let surface = try MetalViewportSurface(device: device)
        surface.view.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        surface.setContentScale(1)
        return surface
    }

    private func makeLabelmapLayer(for base: VolumeDataset) throws -> VolumeLayer {
        let values = [UInt16](repeating: 1, count: base.dimensions.voxelCount)
        let dataset = VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: base.dimensions,
            spacing: base.spacing,
            pixelFormat: .int16Unsigned,
            intensityRange: 0...1,
            orientation: base.orientation
        )
        let labelmap = try LabelmapVolume(
            dataset: dataset,
            segments: [LabelmapSegment(label: 1, color: SIMD4<Float>(1, 0, 0, 1))]
        )
        return VolumeLayer(id: "orientation-layer",
                           labelmap: labelmap,
                           opacity: 0.5)
    }
}
