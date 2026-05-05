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

    func test_visibleScalarLayersRejectNonIdentityTransformWithClearError() throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(pixelFormat: .int16Signed)
        let transferFunction = VolumeTransferFunction.defaultGrayscale(for: dataset)
        var transform = matrix_identity_float4x4
        transform.columns.3.x = 4
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
                           "Register or resample the scalar layer into the base texture space before using it for v1 fusion.")
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
}
