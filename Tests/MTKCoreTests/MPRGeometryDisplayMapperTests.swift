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

    func testObliquePlanePassesThroughOffCenterCrosshair() {
        let dataset = makeDataset(origin: SIMD3<Float>(12, 24, 36))
        let crosshairWorld = dataset.imageData.indexToWorld.transformPoint(SIMD3<Float>(1, 5, 7))
        let rotation = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(1, 0, 0))

        let plane = MPRGeometryDisplayMapper.makePlane(
            for: dataset,
            axis: .z,
            through: crosshairWorld,
            rotation: rotation
        )

        let signedDistance = simd_dot(
            crosshairWorld - plane.originWorld,
            simd_normalize(plane.normalWorld)
        )
        let relative = crosshairWorld - plane.originWorld
        let planeU = simd_dot(relative, plane.axisUWorld) / simd_length_squared(plane.axisUWorld)
        let planeV = simd_dot(relative, plane.axisVWorld) / simd_length_squared(plane.axisVWorld)
        // The rectangle keeps its resting extents and slides to reach the
        // crosshair, so a steep tilt can leave the crosshair on the edge rather
        // than strictly inside — hence the tolerance instead of a bare 0...1.
        let tolerance: Float = 1e-4
        XCTAssertEqual(signedDistance, 0, accuracy: 1e-4)
        XCTAssertGreaterThanOrEqual(planeU, -tolerance)
        XCTAssertLessThanOrEqual(planeU, 1 + tolerance)
        XCTAssertGreaterThanOrEqual(planeV, -tolerance)
        XCTAssertLessThanOrEqual(planeV, 1 + tolerance)
    }

    func testCrosshairAnchoredRotationPreservesPhysicalPlaneExtents() {
        let dataset = anisotropicDataset()
        let crosshairWorld = dataset.imageData.indexToWorld.transformPoint(SIMD3<Float>(37, 14, 5))

        for axis in [MPRPlaneAxis.x, .y, .z] {
            let reference = MPRGeometryDisplayMapper.makePlane(for: dataset,
                                                               axis: axis,
                                                               slicePosition: 0.5)
            for rotationAxis in [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)] {
                for degrees in stride(from: Float(5), through: 85, by: 20) {
                    let plane = MPRGeometryDisplayMapper.makePlane(
                        for: dataset,
                        axis: axis,
                        through: crosshairWorld,
                        rotation: simd_quatf(angle: degrees * .pi / 180, axis: rotationAxis)
                    )
                    let label = "\(axis) tilted \(degrees)° about \(rotationAxis)"

                    XCTAssertEqual(simd_length(plane.axisUWorld),
                                   simd_length(reference.axisUWorld),
                                   accuracy: 1e-3,
                                   "U extent changed for \(label)")
                    XCTAssertEqual(simd_length(plane.axisVWorld),
                                   simd_length(reference.axisVWorld),
                                   accuracy: 1e-3,
                                   "V extent changed for \(label)")
                }
            }
        }
    }

    /// Tilting the crosshair in one panel used to rescale the anatomy in the
    /// other two: the plane rectangle was sized from the volume bounds projected
    /// on the tilted axes, it grew with the tilt, and the panel aspect-fits that
    /// rectangle into a fixed viewport.
    func testCrosshairRotationKeepsAffectedPanelsAtTheSameScale() throws {
        let dataset = anisotropicDataset()
        let crosshairVoxel = SIMD3<Float>(37, 14, 5)
        let crosshairWorld = dataset.imageData.indexToWorld.transformPoint(crosshairVoxel)
        let viewportSize = CGSize(width: 320, height: 240)
        let rotations: [(dragged: String, axis: SIMD3<Float>, affected: [MPRPlaneAxis])] = [
            (dragged: "sagittal", axis: SIMD3<Float>(1, 0, 0), affected: [.y, .z]),
            (dragged: "coronal", axis: SIMD3<Float>(0, 1, 0), affected: [.x, .z]),
            (dragged: "axial", axis: SIMD3<Float>(0, 0, 1), affected: [.x, .y])
        ]

        for rotation in rotations {
            for axis in rotation.affected {
                let restingScale = try screenScale(of: dataset,
                                                   axis: axis,
                                                   crosshairVoxel: crosshairVoxel,
                                                   crosshairWorld: crosshairWorld,
                                                   rotation: simd_quatf(angle: 0, axis: rotation.axis),
                                                   viewportSize: viewportSize)

                for degrees in stride(from: Float(5), through: 85, by: 20) {
                    let tiltedScale = try screenScale(
                        of: dataset,
                        axis: axis,
                        crosshairVoxel: crosshairVoxel,
                        crosshairWorld: crosshairWorld,
                        rotation: simd_quatf(angle: degrees * .pi / 180, axis: rotation.axis),
                        viewportSize: viewportSize
                    )

                    XCTAssertEqual(
                        tiltedScale,
                        restingScale,
                        accuracy: 1e-3,
                        "\(axis) panel rescaled by \(degrees)° of \(rotation.dragged) rotation"
                    )
                }
            }
        }
    }

    func testIndexedPlaneAndDisplayReferenceShareRendererBasisForIdentityRotation() {
        let dataset = makeDataset()

        let plane = MPRGeometryDisplayMapper.makePlane(for: dataset,
                                                       axis: .y,
                                                       sliceIndex: 3,
                                                       rotation: simd_quatf(angle: 0,
                                                                            axis: SIMD3<Float>(0, 0, 1)))
        let referencePlane = MPRGeometryDisplayMapper.makeDisplayReferencePlane(
            for: dataset,
            axis: .y,
            slicePosition: 0.5
        )

        // `axisU` runs in −x for the coronal plane: that is the radiological
        // convention the factory bakes into the geometry, and the rotated path
        // has to start from the same basis (issue #1657).
        assertVector(plane.originVoxel, SIMD3<Float>(4, 3, 0))
        assertVector(plane.axisUVoxel, SIMD3<Float>(-4, 0, 0))
        assertVector(plane.axisVVoxel, SIMD3<Float>(0, 0, 8))
        assertVector(referencePlane.originVoxel, plane.originVoxel)
        assertVector(referencePlane.axisUVoxel, plane.axisUVoxel)
        assertVector(referencePlane.axisVVoxel, plane.axisVVoxel)

        let unrotated = MPRGeometryDisplayMapper.makePlane(for: dataset,
                                                           axis: .y,
                                                           slicePosition: 0.5)
        assertVector(unrotated.originVoxel, plane.originVoxel)
        assertVector(unrotated.axisUVoxel, plane.axisUVoxel)
        assertVector(unrotated.axisVVoxel, plane.axisVVoxel)
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

    func testGSPSRotatedCoronalContextPreservesUnrotatedAspectFitScale() throws {
        let dataset = makeDataset()
        let viewportTransform = MPRViewportTransform(rotationRadians: .pi / 2)
        let viewportSize = CGSize(width: 240, height: 180)
        let unrotatedContext = try MPRGeometryDisplayMapper.makeContext(
            dataset: dataset,
            axis: .y,
            slicePosition: 0.5,
            viewportSize: viewportSize
        )
        let rotatedContext = try MPRGeometryDisplayMapper.makeContext(
            dataset: dataset,
            axis: .y,
            slicePosition: 0.5,
            viewportTransform: viewportTransform,
            viewportSize: viewportSize
        )
        let centerVoxel = unrotatedContext.plane.originVoxel
            + unrotatedContext.plane.axisUVoxel * 0.5
            + unrotatedContext.plane.axisVVoxel * 0.5
        let referenceVoxel = centerVoxel + unrotatedContext.plane.axisUVoxel * 0.25

        func screenDistance(in context: MPRGeometryDisplayContext) throws -> CGFloat {
            let center = try context.viewportPoint(forVoxel: centerVoxel).screenPoint
            let reference = try context.viewportPoint(forVoxel: referenceVoxel).screenPoint
            return hypot(reference.x - center.x, reference.y - center.y)
        }

        XCTAssertEqual(
            try screenDistance(in: rotatedContext),
            try screenDistance(in: unrotatedContext),
            accuracy: 1e-4
        )
    }

    func testQuarterTurnPreservesLinearScaleAtOneHundredPercentZoom() {
        let sourceAspectRatio: Float = 2.4
        let viewportSize = CGSize(width: 240, height: 180)
        let outputAspect = MPROutputAspect.aspectFit(physicalAspectRatio: sourceAspectRatio)
        let center = SIMD2<Float>(0.5, 0.5)
        let horizontalReference = SIMD2<Float>(0.75, 0.5)

        func screenDistance(rotationRadians: Float) -> Float {
            let transform = MPRViewportTransform(rotationRadians: rotationRadians)
            let layout = outputAspect.layout(
                destinationSize: viewportSize,
                viewportTransform: transform
            )
            let centerInViewport = layout.viewportPoint(
                fromImagePoint: transform.screenCoordinates(
                    forImageScreen: center,
                    sourceAspectRatio: sourceAspectRatio
                )
            )
            let referenceInViewport = layout.viewportPoint(
                fromImagePoint: transform.screenCoordinates(
                    forImageScreen: horizontalReference,
                    sourceAspectRatio: sourceAspectRatio
                )
            )
            let destinationSize = SIMD2<Float>(Float(viewportSize.width), Float(viewportSize.height))
            return simd_distance(centerInViewport * destinationSize, referenceInViewport * destinationSize)
        }

        let unrotatedDistance = screenDistance(rotationRadians: 0)

        XCTAssertEqual(screenDistance(rotationRadians: .pi / 2), unrotatedDistance, accuracy: 1e-4)
        XCTAssertEqual(screenDistance(rotationRadians: -.pi / 2), unrotatedDistance, accuracy: 1e-4)
    }

    func testCompoundCrosshairRotationsPreservePhysicalPlaneExtentsInBothOrders() {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 51, height: 51, depth: 24),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1)
        )
        let angle = Float(80) * .pi / 180
        let cases: [(plane: MPRPlaneAxis, first: SIMD3<Float>, second: SIMD3<Float>)] = [
            (.x, SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 1, 0)),
            (.y, SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 0)),
            (.z, SIMD3<Float>(0, 1, 0), SIMD3<Float>(1, 0, 0))
        ]

        for item in cases {
            let reference = MPRGeometryDisplayMapper.makePlane(
                for: dataset,
                axis: item.plane,
                slicePosition: 0.5
            )
            let first = simd_quatf(angle: angle, axis: item.first)
            let second = simd_quatf(angle: angle, axis: item.second)

            for rotation in [simd_normalize(second * first), simd_normalize(first * second)] {
                let rotated = MPRGeometryDisplayMapper.makePlane(
                    for: dataset,
                    axis: item.plane,
                    slicePosition: 0.5,
                    rotation: rotation
                )

                XCTAssertEqual(
                    simd_length(rotated.axisUWorld),
                    simd_length(reference.axisUWorld),
                    accuracy: 1e-3,
                    "U extent changed for \(item.plane)"
                )
                XCTAssertEqual(
                    simd_length(rotated.axisVWorld),
                    simd_length(reference.axisVWorld),
                    accuracy: 1e-3,
                    "V extent changed for \(item.plane)"
                )
            }
        }
    }

    func testAnisotropicNonCentralCompoundRotationKeepsScaleAndAllowsBackgroundCorners() throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 17, height: 23, depth: 31),
            spacing: VolumeSpacing(x: 0.7, y: 1.2, z: 3.4),
            orientation: VolumeOrientation(
                row: simd_normalize(SIMD3<Float>(1, 1, 0)),
                column: SIMD3<Float>(0, 0, 1),
                origin: SIMD3<Float>(7, 11, 13)
            )
        )
        let slicePosition: Float = 0.2
        let angle = Float(80) * .pi / 180
        let rotation = simd_normalize(
            simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
                * simd_quatf(angle: angle, axis: SIMD3<Float>(0, 0, 1))
        )
        let viewportSize = CGSize(width: 360, height: 280)
        let reference = try MPRGeometryDisplayMapper.makeContext(
            dataset: dataset,
            axis: .x,
            slicePosition: slicePosition,
            viewportSize: viewportSize
        )
        let rotated = try MPRGeometryDisplayMapper.makeContext(
            dataset: dataset,
            axis: .x,
            slicePosition: slicePosition,
            planeRotation: rotation,
            viewportSize: viewportSize
        )

        XCTAssertEqual(
            simd_length(rotated.plane.axisUWorld),
            simd_length(reference.plane.axisUWorld),
            accuracy: 1e-3
        )
        XCTAssertEqual(
            simd_length(rotated.plane.axisVWorld),
            simd_length(reference.plane.axisVWorld),
            accuracy: 1e-3
        )

        let referenceCenter = planeCenterWorld(reference.plane)
        let rotatedCenter = planeCenterWorld(rotated.plane)
        assertVector(rotatedCenter, referenceCenter, accuracy: 1e-3)

        let physicalReferenceDistance: Float = 5
        XCTAssertEqual(
            try screenDistance(
                in: rotated,
                from: rotatedCenter,
                toward: rotated.plane.axisUWorld,
                physicalDistance: physicalReferenceDistance
            ),
            try screenDistance(
                in: reference,
                from: referenceCenter,
                toward: reference.plane.axisUWorld,
                physicalDistance: physicalReferenceDistance
            ),
            accuracy: 1e-3
        )

        let corners = [
            rotated.plane.originTexture,
            rotated.plane.originTexture + rotated.plane.axisUTexture,
            rotated.plane.originTexture + rotated.plane.axisVTexture,
            rotated.plane.originTexture + rotated.plane.axisUTexture + rotated.plane.axisVTexture
        ]
        XCTAssertTrue(corners.contains(where: isOutsideTextureVolume))

        let centerOnScreen = try rotated.viewportPoint(forWorldPoint: rotatedCenter).screenPoint
        let pickedCenter = try rotated.pick(screenPoint: centerOnScreen)
        assertVector(pickedCenter.worldPoint, rotatedCenter, accuracy: 1e-3)
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

    /// A volume shaped like a clinical CT stack: square in plane, shorter along
    /// the slice normal, so a tilt mixes a long axis into a short one.
    private func anisotropicDataset() -> VolumeDataset {
        VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 51, height: 51, depth: 24),
            spacing: VolumeSpacing(x: 0.7, y: 0.7, z: 1.5)
        )
    }

    /// Screen points per world millimetre for the panel showing `axis`, measured
    /// the way the panel draws it: crosshair-anchored plane, aspect-fit layout,
    /// untouched viewport transform.
    private func screenScale(of dataset: VolumeDataset,
                             axis: MPRPlaneAxis,
                             crosshairVoxel: SIMD3<Float>,
                             crosshairWorld: SIMD3<Float>,
                             rotation: simd_quatf,
                             viewportSize: CGSize) throws -> CGFloat {
        let plane = MPRGeometryDisplayMapper.makePlane(for: dataset,
                                                       axis: axis,
                                                       through: crosshairWorld,
                                                       rotation: rotation)
        let context = try MPRGeometryDisplayMapper.makeContext(
            dataset: dataset,
            axis: axis,
            slicePosition: slicePosition(of: crosshairVoxel, axis: axis, in: dataset),
            planeRotation: rotation,
            precomputedPlane: plane,
            viewportSize: viewportSize
        )
        return try screenDistance(in: context,
                                  from: crosshairWorld,
                                  toward: plane.axisUWorld,
                                  physicalDistance: 1)
    }

    private func slicePosition(of voxel: SIMD3<Float>,
                               axis: MPRPlaneAxis,
                               in dataset: VolumeDataset) -> Float {
        let dimensions = dataset.dimensions
        switch axis {
        case .x:
            return voxel.x / Float(max(dimensions.width - 1, 1))
        case .y:
            return voxel.y / Float(max(dimensions.height - 1, 1))
        case .z:
            return voxel.z / Float(max(dimensions.depth - 1, 1))
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

    private func planeCenterWorld(_ plane: MPRPlaneGeometry) -> SIMD3<Float> {
        plane.originWorld + plane.axisUWorld * 0.5 + plane.axisVWorld * 0.5
    }

    private func screenDistance(
        in context: MPRGeometryDisplayContext,
        from origin: SIMD3<Float>,
        toward direction: SIMD3<Float>,
        physicalDistance: Float
    ) throws -> CGFloat {
        let unitDirection = simd_normalize(direction)
        let start = try context.viewportPoint(forWorldPoint: origin).screenPoint
        let end = try context.viewportPoint(
            forWorldPoint: origin + unitDirection * physicalDistance
        ).screenPoint
        return hypot(end.x - start.x, end.y - start.y)
    }

    private func isOutsideTextureVolume(_ point: SIMD3<Float>) -> Bool {
        point.x < 0 || point.x > 1 ||
        point.y < 0 || point.y > 1 ||
        point.z < 0 || point.z > 1
    }
}
