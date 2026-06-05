import CoreGraphics
import XCTest
import simd

@testable import MTKCore

final class MPRGeometryDisplayMapperTests: XCTestCase {
    func testContextCentralizesPlaneDisplayLayoutAndCursorProjection() throws {
        let dataset = makeDataset()
        let slicePosition = Float(4.0 / 6.0)
        let viewportSize = CGSize(width: 200, height: 160)
        let context = try MPRGeometryDisplayMapper.makeContext(
            dataset: dataset,
            axis: .y,
            slicePosition: slicePosition,
            viewportSize: viewportSize
        )
        let expectedPlane = MPRPlaneGeometryFactory.makePlane(for: dataset,
                                                             axis: .y,
                                                             slicePosition: slicePosition)
        let cursorVoxel = SIMD3<Float>(1, 4, 6)

        assertVector(context.plane.originWorld, expectedPlane.originWorld)
        assertVector(context.plane.axisUWorld, expectedPlane.axisUWorld)
        XCTAssertEqual(context.displayTransform,
                       MPRDisplayTransformFactory.makeTransform(for: expectedPlane, axis: .y))
        XCTAssertEqual(context.outputAspect, .aspectFit(physicalAspectRatio: expectedPlane.physicalAspectRatio))
        XCTAssertEqual(context.presentationLayout,
                       context.outputAspect.layout(destinationSize: viewportSize))

        let screen = try context.viewportPoint(forVoxel: cursorVoxel)
        let pick = try context.pick(screenPoint: screen.screenPoint)
        assertVector(pick.voxel.continuousIndex, cursorVoxel, accuracy: 1e-4)

        let offset = try context.crosshairOffset(forVoxel: cursorVoxel)
        XCTAssertEqual(offset.x,
                       screen.screenPoint.x - viewportSize.width * 0.5,
                       accuracy: 1e-4)
        XCTAssertEqual(offset.y,
                       screen.screenPoint.y - viewportSize.height * 0.5,
                       accuracy: 1e-4)
    }

    func testRotatedPlaneUsesDatasetGeometryAndRoundTripsCenterVoxel() throws {
        let dataset = makeDataset(origin: SIMD3<Float>(12, 24, 36))
        let rotation = simd_quatf(angle: .pi / 8, axis: SIMD3<Float>(0, 0, 1))
        let context = try MPRGeometryDisplayMapper.makeContext(
            dataset: dataset,
            axis: .z,
            slicePosition: 0.5,
            planeRotation: rotation,
            viewportSize: CGSize(width: 180, height: 220)
        )
        let canonical = MPRPlaneGeometryFactory.makePlane(for: dataset,
                                                         axis: .z,
                                                         slicePosition: 0.5)
        let centerVoxel = context.plane.originVoxel
            + context.plane.axisUVoxel * 0.5
            + context.plane.axisVVoxel * 0.5

        XCTAssertNotEqual(context.plane.axisUVoxel, canonical.axisUVoxel)
        assertVector(context.plane.originWorld,
                     dataset.imageData.indexToWorld.transformPoint(context.plane.originVoxel),
                     accuracy: 1e-4)

        let screen = try context.viewportPoint(forVoxel: centerVoxel)
        let pick = try context.pick(screenPoint: screen.screenPoint)
        assertVector(pick.voxel.continuousIndex, centerVoxel, accuracy: 1e-3)
    }

    func testIndexedPlanePreservesRendererPlaneBasisForIdentityRotation() {
        let dataset = makeDataset()

        let plane = MPRGeometryDisplayMapper.makePlane(for: dataset,
                                                       axis: .y,
                                                       sliceIndex: 3,
                                                       rotation: simd_quatf(angle: 0,
                                                                            axis: SIMD3<Float>(0, 0, 1)))

        assertVector(plane.originVoxel, SIMD3<Float>(0, 3, 0))
        assertVector(plane.axisUVoxel, SIMD3<Float>(4, 0, 0))
        assertVector(plane.axisVVoxel, SIMD3<Float>(0, 0, 8))
    }

    func testNormalizedPositionUpdatesFromViewportPointApplyAspectAndViewportTransform() throws {
        let dataset = makeDataset()
        let viewportTransform = MPRViewportTransform(zoom: 1.2,
                                                     pan: SIMD2<Float>(0.02, -0.02))
        let context = try MPRGeometryDisplayMapper.makeContext(
            dataset: dataset,
            axis: .y,
            slicePosition: 4.0 / 6.0,
            viewportTransform: viewportTransform,
            viewportSize: CGSize(width: 220, height: 160)
        )
        let targetVoxel = SIMD3<Float>(2, 4, 4)
        let screen = try context.viewportPoint(forVoxel: targetVoxel)

        let updates = try context.normalizedPositionUpdates(fromScreenPoint: screen.screenPoint)

        XCTAssertEqual(updates.map(\.axis), [.x, .z])
        XCTAssertEqual(updates[0].position, 2.0 / 4.0, accuracy: 1e-4)
        XCTAssertEqual(updates[1].position, 4.0 / 8.0, accuracy: 1e-4)
    }

    func testNormalizedPositionUpdatesMapVoxelComponentsForAllViewingAxes() {
        let dimensions = VolumeDimensions(width: 5, height: 7, depth: 9)
        let voxel = SIMD3<Float>(1, 2, 6)

        let axial = MPRGeometryDisplayMapper.normalizedPositionUpdates(fromVoxel: voxel,
                                                                       dimensions: dimensions,
                                                                       viewingAxis: .z)
        assertUpdate(axial[0], axis: .x, position: 1.0 / 4.0)
        assertUpdate(axial[1], axis: .y, position: 2.0 / 6.0)

        let coronal = MPRGeometryDisplayMapper.normalizedPositionUpdates(fromVoxel: voxel,
                                                                         dimensions: dimensions,
                                                                         viewingAxis: .y)
        assertUpdate(coronal[0], axis: .x, position: 1.0 / 4.0)
        assertUpdate(coronal[1], axis: .z, position: 6.0 / 8.0)

        let sagittal = MPRGeometryDisplayMapper.normalizedPositionUpdates(fromVoxel: voxel,
                                                                          dimensions: dimensions,
                                                                          viewingAxis: .x)
        assertUpdate(sagittal[0], axis: .y, position: 2.0 / 6.0)
        assertUpdate(sagittal[1], axis: .z, position: 6.0 / 8.0)
    }

    func testContextHonorsExplicitOutputAspectAndRejectsInvalidViewport() throws {
        let dataset = makeDataset()
        let context = try MPRGeometryDisplayMapper.makeContext(
            dataset: dataset,
            axis: .x,
            slicePosition: 0.25,
            outputAspect: .fill,
            viewportSize: CGSize(width: 320, height: 240)
        )

        XCTAssertEqual(context.outputAspect, .fill)
        XCTAssertEqual(context.presentationLayout, .fill)

        XCTAssertThrowsError(
            try MPRGeometryDisplayMapper.makeContext(
                dataset: dataset,
                axis: .x,
                slicePosition: 0.25,
                viewportSize: .zero
            )
        ) { error in
            XCTAssertEqual(error as? VolumePickError, .invalidViewportSize)
        }
    }

    private func makeDataset(origin: SIMD3<Float> = SIMD3<Float>(0, 0, 0)) -> VolumeDataset {
        VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 5, height: 7, depth: 9),
            spacing: VolumeSpacing(x: 0.8, y: 1.2, z: 2.4),
            orientation: VolumeOrientation(row: SIMD3<Float>(1, 0, 0),
                                           column: SIMD3<Float>(0, 1, 0),
                                           origin: origin)
        )
    }

    private func assertVector(_ actual: SIMD3<Float>,
                              _ expected: SIMD3<Float>,
                              accuracy: Float = 1e-5,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
    }

    private func assertUpdate(_ update: MPRGeometryPositionUpdate,
                              axis: MPRPlaneAxis,
                              position: Float,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        XCTAssertEqual(update.axis, axis, file: file, line: line)
        XCTAssertEqual(update.position, position, accuracy: 1e-5, file: file, line: line)
    }
}
