import CoreGraphics
import XCTest
import simd

@testable import MTKCore

final class VolumePickingTests: XCTestCase {
    func testMPRPickSamplesKnownVoxelWithAnisotropicNonIdentityAffine() throws {
        let direction = simd_float3x3(columns: (
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0, 0, 1),
            SIMD3<Float>(1, 0, 0)
        ))
        let dataset = makeSignedPhantom(
            dimensions: VolumeDimensions(width: 4, height: 5, depth: 6),
            spacing: VolumeSpacing(x: 2, y: 3, z: 4),
            origin: SIMD3<Float>(10, 20, 30),
            direction: direction
        )
        let plane = MPRPlaneGeometryFactory.makePlane(for: dataset,
                                                      axis: .z,
                                                      slicePosition: 3.0 / 5.0)

        let pick = try VolumePicking.pickMPR(
            screenPoint: CGPoint(x: 1.0 / 3.0 * 120, y: 0.5 * 120),
            viewportSize: CGSize(width: 120, height: 120),
            dataset: dataset,
            plane: plane,
            displayTransform: .identity,
            outputAspect: .fill,
            axis: .z
        )

        XCTAssertEqual(pick.voxel.index, SIMD3<Int32>(1, 2, 3))
        XCTAssertEqual(pick.intensity.storedScalar, 321)
        assertVector(pick.worldPoint, SIMD3<Float>(22, 22, 36))
        assertVector(pick.textureCoordinate,
                     SIMD3<Float>(1.5 / 4.0, 2.5 / 5.0, 3.5 / 6.0))
    }

    func testMPRPickCoversAxialCoronalAndSagittalPlanes() throws {
        let dataset = makeSignedPhantom(
            dimensions: VolumeDimensions(width: 5, height: 7, depth: 9)
        )
        let target = SIMD3<Int32>(1, 3, 4)
        let cases: [(axis: MPRPlaneAxis, slice: Float, screen: SIMD2<Float>)] = [
            (.z, 4.0 / 8.0, SIMD2<Float>(1.0 / 4.0, 3.0 / 6.0)),
            (.y, 3.0 / 6.0, SIMD2<Float>((4.0 - 1.0) / 4.0, 4.0 / 8.0)),
            (.x, 1.0 / 4.0, SIMD2<Float>(3.0 / 6.0, 4.0 / 8.0))
        ]

        for testCase in cases {
            let plane = MPRPlaneGeometryFactory.makePlane(for: dataset,
                                                          axis: testCase.axis,
                                                          slicePosition: testCase.slice)
            let pick = try VolumePicking.pickMPR(
                screenPoint: CGPoint(x: CGFloat(testCase.screen.x) * 100,
                                     y: CGFloat(testCase.screen.y) * 100),
                viewportSize: CGSize(width: 100, height: 100),
                dataset: dataset,
                plane: plane,
                displayTransform: .identity,
                outputAspect: .fill,
                axis: testCase.axis
            )

            XCTAssertEqual(pick.voxel.index, target, "axis \(testCase.axis)")
            XCTAssertEqual(pick.intensity.storedScalar, 431, "axis \(testCase.axis)")
        }
    }

    func testWorldVoxelTextureAndMPRScreenRoundTrip() throws {
        let dataset = makeSignedPhantom(
            dimensions: VolumeDimensions(width: 6, height: 5, depth: 4),
            spacing: VolumeSpacing(x: 0.8, y: 1.4, z: 2.2),
            origin: SIMD3<Float>(12, 24, 36),
            direction: simd_float3x3(columns: (
                simd_normalize(SIMD3<Float>(1, 1, 0)),
                SIMD3<Float>(0, 0, 1),
                simd_normalize(SIMD3<Float>(1, -1, 0))
            ))
        )
        let index = SIMD3<Float>(2, 3, 1)
        let world = VolumePicking.worldPoint(forVoxelIndex: index, in: dataset)
        let voxel = try VolumePicking.voxelIndex(forWorldPoint: world, in: dataset)
        let texture = VolumePicking.textureCoordinate(forWorldPoint: world, in: dataset)

        XCTAssertEqual(voxel.index, SIMD3<Int32>(2, 3, 1))
        assertVector(texture, VolumePicking.textureCoordinate(forVoxelIndex: index, in: dataset))

        let plane = MPRPlaneGeometryFactory.makePlane(for: dataset,
                                                      axis: .z,
                                                      slicePosition: 1.0 / 3.0)
        let screen = try VolumePicking.screenPoint(forWorldPoint: world,
                                                   dataset: dataset,
                                                   plane: plane,
                                                   displayTransform: .identity,
                                                   outputAspect: .fill,
                                                   viewportSize: CGSize(width: 200, height: 100))
        let pick = try VolumePicking.pickMPR(screenPoint: screen.screenPoint,
                                             viewportSize: screen.viewportSize,
                                             dataset: dataset,
                                             plane: plane,
                                             displayTransform: .identity,
                                             outputAspect: .fill,
                                             axis: .z)
        XCTAssertEqual(pick.voxel.index, SIMD3<Int32>(2, 3, 1))
    }

    func testMPRPickingRoundTripsThroughDisplayAndViewportTransforms() throws {
        let dataset = makeSignedPhantom(
            dimensions: VolumeDimensions(width: 5, height: 7, depth: 9)
        )
        let target = SIMD3<Int32>(1, 2, 4)
        let world = VolumePicking.worldPoint(forVoxelIndex: SIMD3<Float>(Float(target.x),
                                                                         Float(target.y),
                                                                         Float(target.z)),
                                             in: dataset)
        let plane = MPRPlaneGeometryFactory.makePlane(for: dataset,
                                                      axis: .z,
                                                      slicePosition: Float(target.z) / 8.0)
        let display = MPRDisplayTransform(
            orientation: .rotated90CW,
            flipHorizontal: true,
            flipVertical: false,
            leadingLabel: .right,
            trailingLabel: .left,
            topLabel: .anterior,
            bottomLabel: .posterior
        )
        let viewport = MPRViewportTransform(zoom: 1.5, pan: SIMD2<Float>(0.1, -0.05))

        let screen = try VolumePicking.screenPoint(forWorldPoint: world,
                                                   dataset: dataset,
                                                   plane: plane,
                                                   displayTransform: display,
                                                   viewportTransform: viewport,
                                                   outputAspect: .fill,
                                                   viewportSize: CGSize(width: 200, height: 200))
        let pick = try VolumePicking.pickMPR(screenPoint: screen.screenPoint,
                                             viewportSize: screen.viewportSize,
                                             dataset: dataset,
                                             plane: plane,
                                             displayTransform: display,
                                             viewportTransform: viewport,
                                             outputAspect: .fill,
                                             axis: .z)

        XCTAssertEqual(pick.voxel.index, target)
        XCTAssertEqual(pick.intensity.storedScalar, 421)
    }

    func testScreenPointAppliesAspectFitLetterbox() throws {
        // Coronal plane on a phantom with anisotropic Z spacing has
        // physicalAspectRatio = (spacingX * (width-1)) / (spacingZ * (depth-1)) = 1/3.
        // In a square 200x200 viewport this produces a pillarbox: image rect
        // is centered horizontally with size.x = 1/3, origin.x = 1/3.
        let dataset = makeSignedPhantom(
            dimensions: VolumeDimensions(width: 4, height: 4, depth: 4),
            spacing: VolumeSpacing(x: 1, y: 1, z: 3)
        )
        let plane = MPRPlaneGeometryFactory.makePlane(for: dataset,
                                                      axis: .y,
                                                      slicePosition: 2.0 / 3.0)
        XCTAssertEqual(plane.physicalAspectRatio, 1.0 / 3.0, accuracy: 1e-5)
        let world = VolumePicking.worldPoint(forVoxelIndex: SIMD3<Float>(1, 2, 1),
                                             in: dataset)
        let viewportSize = CGSize(width: 200, height: 200)

        let screenFill = try VolumePicking.screenPoint(
            forWorldPoint: world,
            dataset: dataset,
            plane: plane,
            displayTransform: .identity,
            outputAspect: .fill,
            viewportSize: viewportSize
        )
        let screenFit = try VolumePicking.screenPoint(
            forWorldPoint: world,
            dataset: dataset,
            plane: plane,
            displayTransform: .identity,
            outputAspect: .aspectFit(physicalAspectRatio: plane.physicalAspectRatio),
            viewportSize: viewportSize
        )

        // Layout origin.x = 1/3, size.x = 1/3 → x_aspectFit = (1/3 + x_fill_normalized * 1/3) * width.
        let expectedX = (1.0 / 3.0 + (screenFill.normalizedPoint.x) * (1.0 / 3.0)) * Float(viewportSize.width)
        XCTAssertEqual(Float(screenFit.screenPoint.x), expectedX, accuracy: 1e-3)
        // Y axis is not letterboxed (size.y = 1) so it must match exactly.
        XCTAssertEqual(screenFit.screenPoint.y, screenFill.screenPoint.y, accuracy: 1e-3)
    }

    func testPickMPRRejectsClickInAspectFitLetterboxBand() throws {
        let dataset = makeSignedPhantom(
            dimensions: VolumeDimensions(width: 4, height: 4, depth: 4),
            spacing: VolumeSpacing(x: 1, y: 1, z: 3)
        )
        let plane = MPRPlaneGeometryFactory.makePlane(for: dataset,
                                                      axis: .y,
                                                      slicePosition: 2.0 / 3.0)
        // Pillarbox band runs x ∈ [0, 200/3) ∪ (400/3, 200] for a 200×200 viewport.
        XCTAssertThrowsError(
            try VolumePicking.pickMPR(
                screenPoint: CGPoint(x: 20, y: 100),
                viewportSize: CGSize(width: 200, height: 200),
                dataset: dataset,
                plane: plane,
                displayTransform: .identity,
                outputAspect: .aspectFit(physicalAspectRatio: plane.physicalAspectRatio),
                axis: .y
            )
        ) { error in
            XCTAssertEqual(error as? VolumePickError, .outsideImagedArea)
        }

        // A click at the geometric center is always inside the imaged area
        // regardless of letterboxing.
        XCTAssertNoThrow(
            try VolumePicking.pickMPR(
                screenPoint: CGPoint(x: 100, y: 100),
                viewportSize: CGSize(width: 200, height: 200),
                dataset: dataset,
                plane: plane,
                displayTransform: .identity,
                outputAspect: .aspectFit(physicalAspectRatio: plane.physicalAspectRatio),
                axis: .y
            )
        )
    }

    func testScreenPointAndPickMPRAreInversesUnderAspectFit() throws {
        let dataset = makeSignedPhantom(
            dimensions: VolumeDimensions(width: 4, height: 4, depth: 4),
            spacing: VolumeSpacing(x: 1, y: 1, z: 3)
        )
        let plane = MPRPlaneGeometryFactory.makePlane(for: dataset,
                                                      axis: .y,
                                                      slicePosition: 2.0 / 3.0)
        let aspect = MPROutputAspect.aspectFit(physicalAspectRatio: plane.physicalAspectRatio)
        let viewportSize = CGSize(width: 200, height: 200)

        for target in [SIMD3<Int32>(1, 2, 1),
                        SIMD3<Int32>(0, 2, 3),
                        SIMD3<Int32>(3, 2, 0),
                        SIMD3<Int32>(2, 2, 2)] {
            let world = VolumePicking.worldPoint(
                forVoxelIndex: SIMD3<Float>(Float(target.x), Float(target.y), Float(target.z)),
                in: dataset
            )
            let screen = try VolumePicking.screenPoint(forWorldPoint: world,
                                                       dataset: dataset,
                                                       plane: plane,
                                                       displayTransform: .identity,
                                                       outputAspect: aspect,
                                                       viewportSize: viewportSize)
            let pick = try VolumePicking.pickMPR(screenPoint: screen.screenPoint,
                                                 viewportSize: viewportSize,
                                                 dataset: dataset,
                                                 plane: plane,
                                                 displayTransform: .identity,
                                                 outputAspect: aspect,
                                                 axis: .y)
            XCTAssertEqual(pick.voxel.index, target, "round-trip failed for \(target)")
        }
    }

    func testSamplingReturnsExplicitErrorsForOutsideViewportAndVolume() throws {
        let dataset = makeSignedPhantom()
        XCTAssertThrowsError(
            try VolumePicking.viewportPoint(screenPoint: CGPoint(x: -1, y: 5),
                                            viewportSize: CGSize(width: 10, height: 10))
        ) { error in
            XCTAssertEqual(error as? VolumePickError, .screenPointOutsideViewport)
        }

        XCTAssertThrowsError(
            try VolumePicking.sampleIntensity(in: dataset,
                                              atWorldPoint: SIMD3<Float>(100, 100, 100))
        ) { error in
            XCTAssertEqual(error as? VolumePickError, .outsideVolume)
        }
    }

    func testSignedAndUnsignedIntensitySamplingUseNearestVoxelWithoutClamping() throws {
        let signed = makeSignedDataset(values: [-10, 20],
                                       dimensions: VolumeDimensions(width: 2, height: 1, depth: 1))
        let unsigned = makeUnsignedDataset(values: [4, 65_000],
                                           dimensions: VolumeDimensions(width: 2, height: 1, depth: 1))

        XCTAssertEqual(try VolumePicking.sampleIntensity(in: signed,
                                                         atVoxelIndex: SIMD3<Int32>(0, 0, 0)).storedScalar,
                       -10)
        XCTAssertEqual(try VolumePicking.sampleIntensity(in: unsigned,
                                                         atVoxelIndex: SIMD3<Int32>(1, 0, 0)).storedScalar,
                       65_000)
    }

    func testLabelSamplingAppliesLayerAffineAndVisibility() throws {
        let base = makeSignedPhantom(dimensions: VolumeDimensions(width: 4, height: 4, depth: 4))
        let labelValues = makeUInt16Values(dimensions: base.dimensions) { x, y, z in
            (x, y, z) == (2, 1, 1) ? 7 : 0
        }
        let labelDataset = makeUnsignedDataset(values: labelValues,
                                               dimensions: base.dimensions)
        let labelmap = try LabelmapVolume(
            dataset: labelDataset,
            segments: [LabelmapSegment(label: 7,
                                       name: "Target",
                                       color: SIMD4<Float>(1, 0, 0, 1))]
        )
        let layer = VolumeLayer(
            id: "translated-label",
            labelmap: labelmap,
            baseWorldToLayerWorld: simd_float4x4(columns: (
                SIMD4<Float>(1, 0, 0, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(0, 0, 1, 0),
                SIMD4<Float>(1, 0, 0, 1)
            ))
        )

        let sample = try VolumePicking.sampleLabel(
            in: [layer],
            atBaseWorldPoint: VolumePicking.worldPoint(forVoxelIndex: SIMD3<Float>(1, 1, 1),
                                                       in: base)
        )

        XCTAssertEqual(sample?.layerID, "translated-label")
        XCTAssertEqual(sample?.label, 7)
        XCTAssertEqual(sample?.segment?.name, "Target")

        let hiddenLayer = VolumeLayer(id: "hidden",
                                      labelmap: labelmap,
                                      opacity: 0)
        XCTAssertNil(try VolumePicking.sampleLabel(in: [hiddenLayer],
                                                   atBaseWorldPoint: SIMD3<Float>(2, 1, 1)))
    }

    func testLabelSamplingSkipsLayersOutsideTheirBounds() throws {
        let base = makeSignedPhantom(dimensions: VolumeDimensions(width: 4, height: 4, depth: 4))
        let labelDataset = makeUnsignedDataset(values: [5],
                                               dimensions: VolumeDimensions(width: 1, height: 1, depth: 1))
        let labelmap = try LabelmapVolume(
            dataset: labelDataset,
            segments: [LabelmapSegment(label: 5,
                                       name: "Tiny",
                                       color: SIMD4<Float>(0, 1, 0, 1))]
        )
        let layer = VolumeLayer(id: "tiny-label",
                                labelmap: labelmap)

        let sample = try VolumePicking.sampleLabel(
            in: [layer],
            atBaseWorldPoint: VolumePicking.worldPoint(forVoxelIndex: SIMD3<Float>(3, 3, 3),
                                                       in: base)
        )

        XCTAssertNil(sample)
    }

    func testMPRPickingReturnsVisibleScalarLayerSamples() throws {
        let base = makeSignedPhantom(dimensions: VolumeDimensions(width: 2, height: 2, depth: 1))
        let scalarDataset = makeUnsignedDataset(values: [5, 9, 0, 0],
                                                dimensions: base.dimensions)
        let scalarLayer = VolumeLayer(
            id: "dose",
            dataset: scalarDataset,
            transferFunction: .defaultGrayscale(for: scalarDataset),
            opacity: 0.5
        )
        let targetWorld = VolumePicking.worldPoint(forVoxelIndex: SIMD3<Float>(1, 0, 0),
                                                   in: base)
        let plane = MPRPlaneGeometryFactory.makePlane(for: base,
                                                      axis: .z,
                                                      slicePosition: 0)
        let screen = try VolumePicking.screenPoint(forWorldPoint: targetWorld,
                                                   dataset: base,
                                                   plane: plane,
                                                   displayTransform: .identity,
                                                   outputAspect: .fill,
                                                   viewportSize: CGSize(width: 100, height: 100))

        let pick = try VolumePicking.pickMPR(screenPoint: screen.screenPoint,
                                             viewportSize: screen.viewportSize,
                                             dataset: base,
                                             plane: plane,
                                             displayTransform: .identity,
                                             outputAspect: .fill,
                                             axis: .z,
                                             layers: [scalarLayer])

        XCTAssertEqual(pick.scalarSamples.count, 1)
        XCTAssertEqual(pick.scalarSamples.first?.layerID, "dose")
        XCTAssertEqual(pick.scalarSamples.first?.voxel.index, SIMD3<Int32>(1, 0, 0))
        XCTAssertEqual(pick.scalarSamples.first?.intensity.storedScalar, 9)
    }

    func testVolume3DPickReturnsFirstVisibleRenderedSample() throws {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        let dataset = makeSignedDataset(
            values: makeInt16Values(dimensions: dimensions) { x, y, z in
                (x, y, z) == (2, 2, 3) ? 1000 : -1000
            },
            dimensions: dimensions,
            intensityRange: -1000...1000
        )
        let pick = try VolumePicking.pickVolume3D(
            screenPoint: CGPoint(x: 50, y: 50),
            dataset: dataset,
            configuration: centeredVolumeConfiguration(for: dataset)
        )

        XCTAssertEqual(pick.hitKind, .volumeVisibleSample)
        XCTAssertEqual(pick.voxel.index, SIMD3<Int32>(2, 2, 3))
        XCTAssertEqual(pick.intensity.storedScalar, 1000)
        XCTAssertNotNil(pick.worldRay)
    }

    func testVolume3DPickUsesPhysicalGeometryForAnisotropicSideView() throws {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        let dataset = makeSignedDataset(
            values: makeInt16Values(dimensions: dimensions) { x, y, z in
                (x, y, z) == (2, 2, 2) ? 1000 : -1000
            },
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 3),
            intensityRange: -1000...1000
        )
        let configuration = Volume3DPickConfiguration(
            camera: VolumeRenderRequest.Camera(position: SIMD3<Float>(5, 0.5, 0.5),
                                               target: SIMD3<Float>(repeating: 0.5),
                                               up: SIMD3<Float>(0, 0, 1),
                                               fieldOfView: 50),
            viewportSize: CGSize(width: 100, height: 100),
            transferFunction: visibleTargetTransferFunction(),
            window: dataset.intensityRange,
            samplingDistance: 1.0 / 512.0
        )

        let pick = try VolumePicking.pickVolume3D(
            screenPoint: CGPoint(x: 50, y: 50),
            dataset: dataset,
            configuration: configuration
        )

        XCTAssertEqual(pick.voxel.index, SIMD3<Int32>(2, 2, 2))
        XCTAssertEqual(pick.intensity.storedScalar, 1000)
        XCTAssertNotNil(pick.worldRay)
    }

    func testVolume3DPickDistinguishesRayMissAndNoVisibleSample() throws {
        let dataset = makeSignedDataset(
            values: [Int16](repeating: -1000, count: 4 * 4 * 4),
            dimensions: VolumeDimensions(width: 4, height: 4, depth: 4),
            intensityRange: -1000...1000
        )

        XCTAssertThrowsError(
            try VolumePicking.pickVolume3D(screenPoint: CGPoint(x: 50, y: 50),
                                           dataset: dataset,
                                           configuration: centeredVolumeConfiguration(for: dataset))
        ) { error in
            XCTAssertEqual(error as? VolumePickError, .noVisibleSample)
        }

        let missConfiguration = Volume3DPickConfiguration(
            camera: VolumeRenderRequest.Camera(position: SIMD3<Float>(2, 2, 2),
                                               target: SIMD3<Float>(2, 2, 1),
                                               up: SIMD3<Float>(0, 1, 0),
                                               fieldOfView: 45),
            viewportSize: CGSize(width: 100, height: 100),
            transferFunction: visibleTargetTransferFunction(),
            window: -1000...1000
        )
        XCTAssertThrowsError(
            try VolumePicking.pickVolume3D(screenPoint: CGPoint(x: 50, y: 50),
                                           dataset: dataset,
                                           configuration: missConfiguration)
        ) { error in
            XCTAssertEqual(error as? VolumePickError, .rayMissedVolume)
        }
    }

    func testVolume3DPickSkipsSamplesHiddenByCrop() throws {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        let dataset = makeSignedDataset(
            values: makeInt16Values(dimensions: dimensions) { x, y, z in
                (x, y, z) == (2, 2, 3) || (x, y, z) == (2, 2, 2) ? 1000 : -1000
            },
            dimensions: dimensions,
            intensityRange: -1000...1000
        )
        let crop = try VolumeCropBox(textureMin: SIMD3<Float>(0, 0, 0),
                                     textureMax: SIMD3<Float>(1, 1, 0.70))
        var configuration = centeredVolumeConfiguration(for: dataset)
        configuration.clipping = try VolumeClippingState(cropBox: crop)

        let pick = try VolumePicking.pickVolume3D(screenPoint: CGPoint(x: 50, y: 50),
                                                  dataset: dataset,
                                                  configuration: configuration)

        XCTAssertEqual(pick.voxel.index, SIMD3<Int32>(2, 2, 2))
        XCTAssertEqual(pick.intensity.storedScalar, 1000)
    }

    func testVolume3DPickReportsNoVisibleSampleWhenCropRemovesRay() throws {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        let dataset = makeSignedDataset(
            values: makeInt16Values(dimensions: dimensions) { x, y, z in
                (x, y, z) == (2, 2, 3) ? 1000 : -1000
            },
            dimensions: dimensions,
            intensityRange: -1000...1000
        )
        let crop = try VolumeCropBox(textureMin: SIMD3<Float>(0, 0, 0),
                                     textureMax: SIMD3<Float>(0.1, 1, 1))
        var configuration = centeredVolumeConfiguration(for: dataset)
        configuration.clipping = try VolumeClippingState(cropBox: crop)

        XCTAssertThrowsError(
            try VolumePicking.pickVolume3D(screenPoint: CGPoint(x: 50, y: 50),
                                           dataset: dataset,
                                           configuration: configuration)
        ) { error in
            XCTAssertEqual(error as? VolumePickError, .noVisibleSample)
        }
    }

    private func centeredVolumeConfiguration(for dataset: VolumeDataset) -> Volume3DPickConfiguration {
        Volume3DPickConfiguration(
            camera: VolumeRenderRequest.Camera(position: SIMD3<Float>(0.5, 0.5, 2),
                                               target: SIMD3<Float>(0.5, 0.5, 0.5),
                                               up: SIMD3<Float>(0, 1, 0),
                                               fieldOfView: 45),
            viewportSize: CGSize(width: 100, height: 100),
            transferFunction: visibleTargetTransferFunction(),
            window: dataset.intensityRange,
            samplingDistance: 1.0 / 512.0
        )
    }

    private func visibleTargetTransferFunction() -> VolumeTransferFunction {
        VolumeTransferFunction(
            opacityPoints: [
                VolumeTransferFunction.OpacityControlPoint(intensity: -1000, opacity: 0),
                VolumeTransferFunction.OpacityControlPoint(intensity: 999, opacity: 0),
                VolumeTransferFunction.OpacityControlPoint(intensity: 1000, opacity: 1)
            ],
            colourPoints: [
                VolumeTransferFunction.ColourControlPoint(intensity: -1000,
                                                          colour: SIMD4<Float>(0, 0, 0, 1)),
                VolumeTransferFunction.ColourControlPoint(intensity: 1000,
                                                          colour: SIMD4<Float>(1, 1, 1, 1))
            ]
        )
    }

    private func makeSignedPhantom(dimensions: VolumeDimensions = VolumeDimensions(width: 4, height: 4, depth: 4),
                                   spacing: VolumeSpacing = VolumeSpacing(x: 1, y: 1, z: 1),
                                   origin: SIMD3<Float> = .zero,
                                   direction: simd_float3x3 = matrix_identity_float3x3) -> VolumeDataset {
        makeSignedDataset(
            values: makeInt16Values(dimensions: dimensions) { x, y, z in
                Int16(x + y * 10 + z * 100)
            },
            dimensions: dimensions,
            spacing: spacing,
            origin: origin,
            direction: direction
        )
    }

    private func makeSignedDataset(values: [Int16],
                                   dimensions: VolumeDimensions,
                                   spacing: VolumeSpacing = VolumeSpacing(x: 1, y: 1, z: 1),
                                   origin: SIMD3<Float> = .zero,
                                   direction: simd_float3x3 = matrix_identity_float3x3,
                                   intensityRange: ClosedRange<Int32>? = nil) -> VolumeDataset {
        let imageData = ImageData3D(dimensions: dimensions,
                                    spacing: spacing,
                                    origin: origin,
                                    direction: direction,
                                    pixelFormat: .int16Signed,
                                    intensityRange: intensityRange ?? -32768...32767)
        return VolumeDataset(data: values.withUnsafeBytes { Data($0) },
                             imageData: imageData)
    }

    private func makeUnsignedDataset(values: [UInt16],
                                     dimensions: VolumeDimensions,
                                     spacing: VolumeSpacing = VolumeSpacing(x: 1, y: 1, z: 1),
                                     origin: SIMD3<Float> = .zero,
                                     direction: simd_float3x3 = matrix_identity_float3x3) -> VolumeDataset {
        let imageData = ImageData3D(dimensions: dimensions,
                                    spacing: spacing,
                                    origin: origin,
                                    direction: direction,
                                    pixelFormat: .int16Unsigned,
                                    intensityRange: 0...65535)
        return VolumeDataset(data: values.withUnsafeBytes { Data($0) },
                             imageData: imageData)
    }

    private func makeInt16Values(dimensions: VolumeDimensions,
                                 value: (Int, Int, Int) -> Int16) -> [Int16] {
        var values: [Int16] = []
        values.reserveCapacity(dimensions.voxelCount)
        for z in 0..<dimensions.depth {
            for y in 0..<dimensions.height {
                for x in 0..<dimensions.width {
                    values.append(value(x, y, z))
                }
            }
        }
        return values
    }

    private func makeUInt16Values(dimensions: VolumeDimensions,
                                  value: (Int, Int, Int) -> UInt16) -> [UInt16] {
        var values: [UInt16] = []
        values.reserveCapacity(dimensions.voxelCount)
        for z in 0..<dimensions.depth {
            for y in 0..<dimensions.height {
                for x in 0..<dimensions.width {
                    values.append(value(x, y, z))
                }
            }
        }
        return values
    }

    private func assertVector(_ actual: SIMD3<Float>,
                              _ expected: SIMD3<Float>,
                              accuracy: Float = 1e-4,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
    }
}
