import Metal
import XCTest
import simd

@_spi(Testing) @testable import MTKCore

final class VolumeLayerTests: XCTestCase {
    func test_labelmapVolumeRequiresUnsignedScalarLabels() throws {
        let signed = VolumeDatasetTestFactory.makeTestDataset(pixelFormat: .int16Signed)

        XCTAssertThrowsError(
            try LabelmapVolume(dataset: signed,
                               segments: [LabelmapSegment(label: 1, color: SIMD4<Float>(1, 0, 0, 1))])
        ) { error in
            XCTAssertEqual(error as? LabelmapVolumeError, .unsupportedPixelFormat(.int16Signed))
        }
    }

    func test_colorLUTIsDeterministicAndKeepsBackgroundHiddenAndMissingLabelsTransparent() throws {
        let labelmap = try makeLabelmap(segments: [
            LabelmapSegment(label: 3, color: SIMD4<Float>(2, -1, 0.5, 2)),
            LabelmapSegment(label: 1, color: SIMD4<Float>(1, 0, 0, 1), isVisible: false),
            LabelmapSegment(label: 2, color: SIMD4<Float>(0, 1, 0, 0.75))
        ])

        let first = LabelmapColorLUTBuilder.colors(for: labelmap)
        let second = LabelmapColorLUTBuilder.colors(for: labelmap)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first[0], SIMD4<Float>(0, 0, 0, 0))
        XCTAssertEqual(first[1], SIMD4<Float>(0, 0, 0, 0))
        XCTAssertEqual(first[2], SIMD4<Float>(0, 1, 0, 0.75))
        XCTAssertEqual(first[3], SIMD4<Float>(1, 0, 0.5, 1))
    }

    func test_colorLUTTextureAddressesFullUInt16LabelRange() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let labelmap = try makeLabelmap(segments: [
            LabelmapSegment(label: UInt16.max, color: SIMD4<Float>(0.25, 0.5, 0.75, 1))
        ])

        let texture = try LabelmapColorLUTBuilder.texture(for: labelmap, device: device)
        let colors = LabelmapColorLUTBuilder.colors(for: labelmap)

        XCTAssertEqual(texture.width, LabelmapColorLUTBuilder.textureWidth)
        XCTAssertEqual(texture.height, LabelmapColorLUTBuilder.textureHeight)
        XCTAssertEqual(colors.count, Int(UInt16.max) + 1)
        XCTAssertEqual(colors[Int(UInt16.max)], SIMD4<Float>(0.25, 0.5, 0.75, 1))
    }

    func test_volumeLayerResourceCacheBuildsMPROverlaysConcurrently() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable")
        }
        let labelmap = try makeLabelmap(segments: [
            LabelmapSegment(label: 1, color: SIMD4<Float>(0.2, 0.8, 0.4, 0.75))
        ])
        let layer = VolumeLayer(id: "segmentation", labelmap: labelmap)
        let frame = try makeMPRFrame(device: device, dataset: labelmap.dataset)
        let cache = VolumeLayerResourceCache()

        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    let overlays = try await cache.makeMPRLabelmapOverlays(for: [layer],
                                                                           baseFrame: frame,
                                                                           device: device,
                                                                           commandQueue: commandQueue)
                    XCTAssertEqual(overlays.first?.opacity, 1)
                    return overlays.count
                }
            }

            for try await count in group {
                XCTAssertEqual(count, 1)
            }
        }
    }

    func test_layerAffineMapsBasePlaneWorldCoordinatesIntoLabelmapTextureSpace() throws {
        let base = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 5, height: 5, depth: 5),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1)
        )
        let labelmapDataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 5, height: 5, depth: 5),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned,
            orientation: VolumeOrientation(row: SIMD3<Float>(1, 0, 0),
                                           column: SIMD3<Float>(0, 1, 0),
                                           origin: SIMD3<Float>(1, 0, 0))
        )
        let labelmap = try LabelmapVolume(
            dataset: labelmapDataset,
            segments: [LabelmapSegment(label: 1, color: SIMD4<Float>(1, 0, 0, 1))]
        )
        let plane = MPRPlaneGeometryFactory.makePlane(for: base, axis: .z, slicePosition: 0.5)

        let basis = VolumeLayerMPRMapper.textureBasis(for: labelmap,
                                                      baseWorldToLayerWorld: matrix_identity_float4x4,
                                                      plane: plane)

        XCTAssertEqual(basis.origin.x, -0.1, accuracy: 1e-5)
        XCTAssertEqual(basis.origin.y, 0.1, accuracy: 1e-5)
        XCTAssertEqual(basis.origin.z, 0.5, accuracy: 1e-5)
        XCTAssertEqual(basis.axisU.x, 0.8, accuracy: 1e-5)
    }

    func test_scalarLayerAffineMapsBasePlaneWorldCoordinatesIntoMPRTextureSpace() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let base = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 5, height: 5, depth: 5),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1)
        )
        let scalarDataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 5, height: 5, depth: 5),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed
        )
        var transform = matrix_identity_float4x4
        transform.columns.3.x = 1
        let layer = VolumeLayer(id: "registered-pet",
                                dataset: scalarDataset,
                                transferFunction: .defaultGrayscale(for: scalarDataset),
                                baseWorldToLayerWorld: transform)
        let frame = try makeMPRFrame(device: device, dataset: base)
        let expectedBasis = VolumeLayerMPRMapper.textureBasis(for: scalarDataset,
                                                              baseWorldToLayerWorld: transform,
                                                              plane: frame.planeGeometry)

        let overlay = try XCTUnwrap(VolumeLayerMPRMapper.makeScalarOverlay(for: layer,
                                                                           baseFrame: frame,
                                                                           scalarTexture: frame.texture,
                                                                           colorLUTTexture: frame.texture))

        XCTAssertEqual(overlay.originTexture.x, expectedBasis.origin.x, accuracy: 1e-5)
        XCTAssertEqual(overlay.axisUTexture.x, expectedBasis.axisU.x, accuracy: 1e-5)
        XCTAssertEqual(overlay.axisVTexture.y, expectedBasis.axisV.y, accuracy: 1e-5)
    }

    func test_scalarVolumeLayerStoresTransferOpacityAndBlendMode() throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(pixelFormat: .int16Signed)
        let transferFunction = VolumeTransferFunction.defaultGrayscale(for: dataset)

        let layer = VolumeLayer(id: "pet",
                                dataset: dataset,
                                transferFunction: transferFunction,
                                opacity: 1.5,
                                blendMode: .additive)

        XCTAssertEqual(layer.id, "pet")
        XCTAssertEqual(layer.scalarVolume?.dataset, dataset)
        XCTAssertEqual(layer.scalarVolume?.transferFunction, transferFunction)
        XCTAssertEqual(layer.clampedOpacity, 1)
        XCTAssertEqual(layer.blendMode, .additive)
        XCTAssertNil(layer.labelmap)
    }

    func test_labelmapSegmentControlsUpdateVisibilityAndOpacity() throws {
        let labelmap = try makeLabelmap(segments: [
            LabelmapSegment(label: 1, name: "Tumor", color: SIMD4<Float>(1, 0, 0, 1)),
            LabelmapSegment(label: 2, name: "Organ", color: SIMD4<Float>(0, 1, 0, 1))
        ])
        var layer = VolumeLayer(id: "segmentation", labelmap: labelmap)

        layer.setLabelmapSegmentVisibility(label: 1, isVisible: false)
        let opacityAdjusted = layer.settingLabelmapSegmentOpacity(label: 2, opacity: 0.35)
        let colors = LabelmapColorLUTBuilder.colors(for: try XCTUnwrap(opacityAdjusted.labelmap))

        XCTAssertFalse(try XCTUnwrap(opacityAdjusted.labelmap?.segments.first { $0.label == 1 }).isVisible)
        XCTAssertEqual(try XCTUnwrap(opacityAdjusted.labelmap?.segments.first { $0.label == 2 }).color.w,
                       0.35,
                       accuracy: 1e-6)
        XCTAssertEqual(colors[1], SIMD4<Float>(0, 0, 0, 0))
        XCTAssertEqual(colors[2], SIMD4<Float>(0, 1, 0, 0.35))
    }

    func test_labelmapSegmentControlsIgnoreScalarLayersAndMissingLabels() throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(pixelFormat: .int16Signed)
        let transferFunction = VolumeTransferFunction.defaultGrayscale(for: dataset)
        var scalarLayer = VolumeLayer(id: "pet",
                                      dataset: dataset,
                                      transferFunction: transferFunction,
                                      opacity: 0.6)
        let labelmap = try makeLabelmap(segments: [
            LabelmapSegment(label: 1, color: SIMD4<Float>(1, 0, 0, 1))
        ])
        let labelLayer = VolumeLayer(id: "segmentation", labelmap: labelmap)

        scalarLayer.setLabelmapSegmentOpacity(label: 1, opacity: 0.25)
        let unchangedLabelLayer = labelLayer
            .settingLabelmapSegmentVisibility(label: 7, isVisible: false)
            .settingLabelmapSegmentOpacity(label: 7, opacity: 0.25)

        XCTAssertEqual(scalarLayer.scalarVolume?.dataset, dataset)
        XCTAssertNil(scalarLayer.labelmap)
        XCTAssertEqual(unchangedLabelLayer, labelLayer)
    }

    func test_volumeRenderRequestDefaultsToSinglePrimaryScalarLayer() throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(pixelFormat: .int16Signed)
        let transferFunction = VolumeTransferFunction.defaultGrayscale(for: dataset)
        let request = VolumeRenderRequest(
            dataset: dataset,
            transferFunction: transferFunction,
            viewportSize: CGSize(width: 16, height: 16),
            camera: VolumeRenderRegressionFixture.camera(),
            samplingDistance: 1.0 / 64.0,
            compositing: .frontToBack,
            quality: .interactive
        )

        XCTAssertEqual(request.layers.count, 1)
        XCTAssertEqual(request.layers.first?.id, VolumeRenderRequest.primaryVolumeLayerID)
        XCTAssertEqual(request.layers.first?.scalarVolume?.dataset, dataset)
        XCTAssertEqual(request.layers.first?.scalarVolume?.transferFunction, transferFunction)
    }

    func test_visibleScalarLayersAcceptIdentityTransform() throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(pixelFormat: .int16Signed)
        let transferFunction = VolumeTransferFunction.defaultGrayscale(for: dataset)
        let layer = VolumeLayer(id: "registered-pet",
                                dataset: dataset,
                                transferFunction: transferFunction,
                                baseWorldToLayerWorld: matrix_identity_float4x4)
        let request = makeRequest(dataset: dataset,
                                  transferFunction: transferFunction,
                                  layers: [layer])

        let visibleLayers = try request.visibleScalarLayersForRendering()

        XCTAssertEqual(visibleLayers.map(\.id), ["registered-pet"])
    }

    func test_visibleScalarLayersResampleTranslatedTransform() throws {
        let dataset = makeSignedDataset(values: [0, 0, 0],
                                        dimensions: VolumeDimensions(width: 3, height: 1, depth: 1))
        let overlay = makeSignedDataset(values: [10, 20, 30],
                                        dimensions: VolumeDimensions(width: 3, height: 1, depth: 1))
        let transferFunction = VolumeTransferFunction.defaultGrayscale(for: dataset)
        var transform = matrix_identity_float4x4
        transform.columns.3.x = 1
        let layer = VolumeLayer(id: "registered-dose",
                                dataset: overlay,
                                transferFunction: transferFunction,
                                baseWorldToLayerWorld: transform)
        let request = makeRequest(dataset: dataset,
                                  transferFunction: transferFunction,
                                  layers: [layer])

        let visibleLayers = try request.visibleScalarLayersForRendering()
        let resampledDataset = try XCTUnwrap(visibleLayers.first?.scalarVolume?.dataset)

        XCTAssertEqual(visibleLayers.map(\.id), ["registered-dose"])
        XCTAssertEqual(visibleLayers.first?.baseWorldToLayerWorld, matrix_identity_float4x4)
        XCTAssertEqual(signedValues(from: resampledDataset), [20, 30, 0])
    }

    func test_visibleScalarLayerCountDoesNotMaterializeRegisteredLayers() throws {
        let dataset = makeSignedDataset(values: [0, 0, 0],
                                        dimensions: VolumeDimensions(width: 3, height: 1, depth: 1))
        let transferFunction = VolumeTransferFunction.defaultGrayscale(for: dataset)
        var transform = matrix_identity_float4x4
        transform.columns.3.x = 1
        let invalidOverlay = VolumeDataset(
            data: Data(),
            dimensions: VolumeDimensions(width: 3, height: 1, depth: 1),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed
        )
        let layer = VolumeLayer(id: "registered-dose",
                                dataset: invalidOverlay,
                                transferFunction: transferFunction,
                                baseWorldToLayerWorld: transform)
        let request = makeRequest(dataset: dataset,
                                  transferFunction: transferFunction,
                                  layers: [
                                      VolumeLayer(id: VolumeRenderRequest.primaryVolumeLayerID,
                                                  dataset: dataset,
                                                  transferFunction: transferFunction),
                                      layer
                                  ])

        XCTAssertEqual(try request.visibleScalarLayerCountForRendering(), 2)
    }

    func test_visibleScalarLayersReuseCachedRegisteredLayerAcrossFrames() throws {
        let dataset = makeSignedDataset(values: [0, 0, 0],
                                        dimensions: VolumeDimensions(width: 3, height: 1, depth: 1))
        let overlay = makeSignedDataset(values: [10, 20, 30],
                                        dimensions: VolumeDimensions(width: 3, height: 1, depth: 1))
        let transferFunction = VolumeTransferFunction.defaultGrayscale(for: dataset)
        var transform = matrix_identity_float4x4
        transform.columns.3.x = 1
        let layer = VolumeLayer(id: "registered-dose",
                                dataset: overlay,
                                transferFunction: transferFunction,
                                baseWorldToLayerWorld: transform)
        let request = makeRequest(dataset: dataset,
                                  transferFunction: transferFunction,
                                  layers: [
                                      VolumeLayer(id: VolumeRenderRequest.primaryVolumeLayerID,
                                                  dataset: dataset,
                                                  transferFunction: transferFunction),
                                      layer
                                  ])
        let cache = RegisteredVolumeLayerResampleCache()

        let firstLayers = try request.visibleScalarLayersForRendering(resampleCache: cache)
        let secondLayers = try request.visibleScalarLayersForRendering(resampleCache: cache)
        let firstResampledDataset = try XCTUnwrap(firstLayers[1].scalarVolume?.dataset)
        let secondResampledDataset = try XCTUnwrap(secondLayers[1].scalarVolume?.dataset)

        XCTAssertEqual(cache.debugResampleMissCount, 1)
        XCTAssertEqual(signedValues(from: firstResampledDataset), [20, 30, 0])
        XCTAssertEqual(signedValues(from: secondResampledDataset), [20, 30, 0])
    }

    func test_visibleScalarLayersRejectUnsupportedTransformWithClearError() throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(pixelFormat: .int16Signed)
        let transferFunction = VolumeTransferFunction.defaultGrayscale(for: dataset)
        let transform = simd_float4x4(columns: (
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(-1, 0, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
        let layer = VolumeLayer(id: "unregistered-dose",
                                dataset: dataset,
                                transferFunction: transferFunction,
                                baseWorldToLayerWorld: transform)
        let request = makeRequest(dataset: dataset,
                                  transferFunction: transferFunction,
                                  layers: [layer])

        XCTAssertThrowsError(try request.visibleScalarLayersForRendering()) { error in
            let adapterError = error as? MetalVolumeRenderingAdapter.AdapterError
            XCTAssertEqual(adapterError, .unsupportedScalarLayerTransform("unregistered-dose"))
            XCTAssertEqual(adapterError?.failureReason,
                           "Use identity/pre-resampled layers or translated/scaled transforms that MTK can resample into base texture space.")
        }
    }

    private func makeLabelmap(segments: [LabelmapSegment]) throws -> LabelmapVolume {
        let values = [UInt16](repeating: 0, count: 8)
        let dataset = VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: VolumeDimensions(width: 2, height: 2, depth: 2),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned,
            intensityRange: 0...3
        )
        return try LabelmapVolume(dataset: dataset, segments: segments)
    }

    private func makeMPRFrame(device: any MTLDevice,
                              dataset: VolumeDataset) throws -> MPRTextureFrame {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: dataset.pixelFormat.rawIntensityMetalPixelFormat,
            width: 4,
            height: 4,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("Unable to create MPR frame texture")
        }
        let plane = MPRPlaneGeometryFactory
            .makePlane(for: dataset, axis: .z, slicePosition: 0.5)
            .sizedForOutput(CGSize(width: 4, height: 4))
        return MPRTextureFrame(texture: texture,
                               intensityRange: dataset.intensityRange,
                               pixelFormat: dataset.pixelFormat,
                               planeGeometry: plane)
    }

    private func makeRequest(dataset: VolumeDataset,
                             transferFunction: VolumeTransferFunction,
                             layers: [VolumeLayer]) -> VolumeRenderRequest {
        VolumeRenderRequest(
            dataset: dataset,
            transferFunction: transferFunction,
            viewportSize: CGSize(width: 16, height: 16),
            camera: VolumeRenderRegressionFixture.camera(),
            samplingDistance: 1.0 / 64.0,
            compositing: .frontToBack,
            quality: .interactive,
            layers: layers
        )
    }

    private func makeSignedDataset(values: [Int16],
                                   dimensions: VolumeDimensions) -> VolumeDataset {
        VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: Int32(values.min() ?? 0)...Int32(values.max() ?? 0)
        )
    }

    private func signedValues(from dataset: VolumeDataset) -> [Int32] {
        dataset.data.withUnsafeBytes { buffer in
            let pointer = buffer.baseAddress!.assumingMemoryBound(to: Int16.self)
            return UnsafeBufferPointer(start: pointer, count: dataset.voxelCount).map(Int32.init)
        }
    }
}
