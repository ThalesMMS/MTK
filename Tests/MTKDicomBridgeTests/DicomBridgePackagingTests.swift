import DicomCore
import Foundation
import Metal
import MTKCore
@testable import MTKDicomBridge
import XCTest
import simd

final class DicomBridgePackagingTests: XCTestCase {
    func testBridgeProvidesDatasetImporter() {
        let importer = DicomVolumeDatasetImporter()
        let typedImporter: VolumeDatasetImporting = importer

        XCTAssertTrue(typedImporter === importer)
    }

    func testDecodedSeriesMapsToVolumeDataset() {
        let modalityVoxels = [Int16]([-1024, 0, 128, 512]).withUnsafeBytes { Data($0) }
        let rawVoxels = [UInt16]([0, 1024, 1152, 1536]).withUnsafeBytes { Data($0) }
        let decoded = DicomDecodedSeries(
            rawVoxels: rawVoxels,
            modalityVoxels: modalityVoxels,
            sourcePixelRepresentation: .unsignedInt16,
            bitsAllocated: 16,
            dimensions: DicomSeriesDimensions(width: 2, height: 2, depth: 1),
            spacing: SIMD3<Double>(0.5, 0.5, 1.25),
            orientation: matrix_identity_double3x3,
            origin: SIMD3<Double>(10, 20, 30),
            modalityIntensityRange: -1024...512,
            recommendedWindow: -160...239,
            patientName: "Sample^Subject",
            modality: "CT",
            seriesDescription: "Bridge fixture",
            studyDescription: "Bridge study",
            studyInstanceUID: "1.2.3",
            seriesInstanceUID: "1.2.3.4",
            frameOfReferenceUID: "1.2.3.4.5",
            rescaleSlope: 1,
            rescaleIntercept: -1024,
            windowCenter: 40,
            windowWidth: 400,
            sourceURL: URL(fileURLWithPath: "/tmp/fixture"),
            warnings: []
        )

        let dataset = DicomVolumeDatasetImporter.makeDataset(from: decoded)

        XCTAssertEqual(dataset.data, modalityVoxels)
        XCTAssertEqual(dataset.dimensions, VolumeDimensions(width: 2, height: 2, depth: 1))
        XCTAssertEqual(dataset.spacing, VolumeSpacing(x: 0.5, y: 0.5, z: 1.25))
        XCTAssertEqual(dataset.imageData.origin, SIMD3<Float>(10, 20, 30))
        XCTAssertEqual(dataset.pixelFormat, .int16Signed)
        XCTAssertEqual(dataset.intensityRange, -1024...512)
        XCTAssertEqual(dataset.recommendedWindow, -160...239)
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.modality, "CT")
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.patientName, "Sample^Subject")
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.studyDescription, "Bridge study")
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.seriesDescription, "Bridge fixture")
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.studyInstanceUID, "1.2.3")
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.seriesInstanceUID, "1.2.3.4")
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.frameOfReferenceUID, "1.2.3.4.5")
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.sourcePixelFormat, .int16Unsigned)
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.windowCenter, 40)
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.windowWidth, 400)
    }

    func testDecoderOwnedVolumeMapsToDatasetAndUploadsTexture() throws {
        let rawVoxels = [UInt16]([
            10, 20, 30, 40,
            110, 120, 130, 140,
            210, 220, 230, 240
        ]).withUnsafeBytes { Data($0) }
        let volume = DicomSeriesVolume(
            voxels: rawVoxels,
            width: 2,
            height: 2,
            depth: 3,
            spacing: SIMD3<Double>(0.5, 0.75, 1.25),
            orientation: matrix_identity_double3x3,
            origin: SIMD3<Double>(10, 20, 30),
            rescaleSlope: 1,
            rescaleIntercept: -100,
            bitsAllocated: 16,
            isSignedPixel: false,
            patientName: "JP3D^Fixture",
            seriesDescription: "Decoder-owned volume",
            studyDescription: "Decoder-owned study",
            modality: "CT",
            windowCenter: 40,
            windowWidth: 400,
            studyInstanceUID: "1.2.3",
            seriesInstanceUID: "1.2.3.4",
            frameOfReferenceUID: "1.2.3.4.5"
        )

        let dataset = try DicomVolumeDatasetImporter.makeDataset(from: volume)

        XCTAssertEqual(dataset.dimensions, VolumeDimensions(width: 2, height: 2, depth: 3))
        XCTAssertEqual(dataset.spacing, VolumeSpacing(x: 0.5, y: 0.75, z: 1.25))
        XCTAssertEqual(dataset.imageData.origin, SIMD3<Float>(10, 20, 30))
        XCTAssertEqual(dataset.pixelFormat, .int16Signed)
        XCTAssertEqual(dataset.intensityRange, -90...140)
        XCTAssertEqual(dataset.recommendedWindow, -160...239)
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.sourcePixelFormat, .int16Unsigned)
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.studyDescription, "Decoder-owned study")
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.seriesDescription, "Decoder-owned volume")
        XCTAssertEqual(littleEndianInt16Values(dataset.data), [-90, -80, -70, -60, 10, 20, 30, 40, 110, 120, 130, 140])

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available - skipping texture upload smoke")
        }
        let texture = try XCTUnwrap(VolumeTextureFactory(dataset: dataset).generate(device: device))
        XCTAssertEqual(texture.width, 2)
        XCTAssertEqual(texture.height, 2)
        XCTAssertEqual(texture.depth, 3)
    }

    func testDecoderOwnedVolumeAppliesPerSliceRescaleParameters() throws {
        let rawVoxels = [UInt16]([
            3000, 3000,
            2600, 2600
        ]).withUnsafeBytes { Data($0) }
        let volume = DicomSeriesVolume(
            voxels: rawVoxels,
            width: 2,
            height: 1,
            depth: 2,
            spacing: SIMD3<Double>(1, 1, 1),
            orientation: matrix_identity_double3x3,
            origin: .zero,
            rescaleSlope: 1,
            rescaleIntercept: -3000,
            bitsAllocated: 16,
            isSignedPixel: false,
            patientName: "Window^Fixture",
            seriesDescription: "Per-slice rescale",
            modality: "CT",
            sliceRescaleParameters: [
                DicomSliceRescaleParameters(slope: 1, intercept: -3000),
                DicomSliceRescaleParameters(slope: 1, intercept: -2600)
            ]
        )

        let dataset = try DicomVolumeDatasetImporter.makeDataset(from: volume)

        XCTAssertEqual(littleEndianInt16Values(dataset.data), [0, 0, 0, 0])
        XCTAssertEqual(dataset.intensityRange, 0...0)
        XCTAssertEqual(dataset.pixelFormat, .int16Signed)
    }

    func testProgressiveDicomVolumeUpdatesMapToDatasetUpdates() async throws {
        let volumeUpdates = AsyncThrowingStream<DicomProgressiveVolumeBridgeUpdate, Error> { continuation in
            continuation.yield(makeProgressiveUpdate(index: 0, quality: .preview, fraction: 0.5, final: false, voxelValue: 10))
            continuation.yield(makeProgressiveUpdate(index: 1, quality: .final, fraction: 1.0, final: true, voxelValue: 30))
            continuation.finish()
        }

        var datasetUpdates: [ProgressiveVolumeDatasetUpdate] = []
        for try await update in DicomProgressiveVolumeDatasetStream().datasetUpdates(from: volumeUpdates) {
            datasetUpdates.append(update)
        }

        XCTAssertEqual(datasetUpdates.map(\.layer.index), [0, 1])
        XCTAssertEqual(datasetUpdates.map(\.layer.quality), [.preview, .final])
        XCTAssertEqual(datasetUpdates.last?.layer.isFinal, true)
        XCTAssertEqual(datasetUpdates.last?.dataset.intensityRange, 30...30)
        XCTAssertEqual(littleEndianInt16Values(try XCTUnwrap(datasetUpdates.last?.dataset.data)), [30, 30, 30, 30])
    }

    func testJPIPProgressiveVolumeUpdatesMapToDatasetUpdates() async throws {
        let volumeUpdates = AsyncThrowingStream<DicomProgressiveVolumeUpdate, Error> { continuation in
            continuation.yield(makeDicomProgressiveUpdate(index: 0,
                                                          quality: .preview,
                                                          fraction: 0.25,
                                                          final: false,
                                                          voxelValue: 10))
            continuation.yield(makeDicomProgressiveUpdate(index: 1,
                                                          quality: .refinement,
                                                          fraction: 0.75,
                                                          final: false,
                                                          voxelValue: 20))
            continuation.yield(makeDicomProgressiveUpdate(index: 2,
                                                          quality: .final,
                                                          fraction: 1.0,
                                                          final: true,
                                                          voxelValue: 30))
            continuation.finish()
        }

        var datasetUpdates: [ProgressiveVolumeDatasetUpdate] = []
        for try await update in DicomProgressiveVolumeDatasetStream(bufferingPolicy: .unbounded)
            .datasetUpdates(from: volumeUpdates) {
            datasetUpdates.append(update)
        }

        XCTAssertEqual(datasetUpdates.map(\.layer.index), [0, 1, 2])
        XCTAssertEqual(datasetUpdates.map(\.layer.quality), [.preview, .refinement, .final])
        XCTAssertEqual(datasetUpdates.map(\.layer.fractionComplete), [0.25, 0.75, 1.0])
        XCTAssertEqual(datasetUpdates.map(\.layer.byteRange), [0..<1, 1..<2, 2..<3])
        XCTAssertEqual(datasetUpdates.last?.layer.isFinal, true)
        XCTAssertEqual(littleEndianInt16Values(try XCTUnwrap(datasetUpdates.last?.dataset.data)), [30, 30, 30, 30])
    }

    func testDicomSegmentationMapsToMTKLabelmapLayer() throws {
        let baseDataset = VolumeDataset(
            data: [Int16](repeating: 0, count: 4).withUnsafeBytes { Data($0) },
            dimensions: VolumeDimensions(width: 2, height: 2, depth: 1),
            spacing: VolumeSpacing(x: 0.7, y: 0.8, z: 1.5),
            pixelFormat: .int16Signed,
            clinicalMetadata: ClinicalImageMetadata(
                patientName: "AI^Fixture",
                modality: "CT",
                seriesDescription: "Base"
            )
        )
        let segmentation = DicomSegmentation(
            sopInstanceUID: "2.25.9301",
            segmentationType: .binary,
            rows: 2,
            columns: 2,
            segments: [
                DicomSegment(
                    number: 1,
                    label: "Lesion",
                    algorithmType: "AUTOMATIC",
                    algorithmName: "SyntheticInference",
                    trackingID: "mask-bridge",
                    trackingUID: "2.25.9302"
                )
            ],
            frames: [
                DicomSegmentationFrame(
                    index: 0,
                    segmentNumber: 1,
                    pixelData: .binary([1, 0, 0, 1])
                )
            ]
        )

        let layer = try DicomSegmentationVolumeLayerBuilder.makeVolumeLayer(
            from: segmentation,
            alignedTo: baseDataset,
            options: DicomSegmentationVolumeLayerOptions(layerID: "ai-seg", opacity: 0.5)
        )
        let labelmap = try XCTUnwrap(layer.labelmap)

        XCTAssertEqual(layer.id, "ai-seg")
        XCTAssertEqual(layer.opacity, 0.5)
        XCTAssertEqual(labelmap.dataset.dimensions, VolumeDimensions(width: 2, height: 2, depth: 1))
        XCTAssertEqual(labelmap.dataset.pixelFormat, .int16Unsigned)
        XCTAssertEqual(labelmap.dataset.spacing, baseDataset.spacing)
        XCTAssertEqual(labelmap.dataset.imageData.clinicalMetadata?.modality, "SEG")
        XCTAssertEqual(labelmap.segments.first?.label, 1)
        XCTAssertEqual(labelmap.segments.first?.name, "Lesion")
        XCTAssertEqual(littleEndianUInt16Values(labelmap.dataset.data), [1, 0, 0, 1])
    }

    func testDicomSegmentationOverlayIncludesMPRLabelmapAndSurfaceMeshLayers() throws {
        let baseDataset = VolumeDataset(
            data: [Int16](repeating: 0, count: 27).withUnsafeBytes { Data($0) },
            dimensions: VolumeDimensions(width: 3, height: 3, depth: 3),
            spacing: VolumeSpacing(x: 0.7, y: 0.8, z: 1.5),
            pixelFormat: .int16Signed,
            clinicalMetadata: ClinicalImageMetadata(
                patientName: "SEG^Fixture",
                modality: "CT",
                seriesDescription: "Base"
            )
        )
        let segmentation = DicomSegmentation(
            sopInstanceUID: "2.25.9303",
            segmentationType: .binary,
            rows: 3,
            columns: 3,
            segments: [
                DicomSegment(
                    number: 2,
                    label: "Target",
                    algorithmType: "AUTOMATIC",
                    algorithmName: "SyntheticInference",
                    recommendedDisplayCIELabValue: [45_000, 40_000, 30_000]
                )
            ],
            frames: [
                DicomSegmentationFrame(
                    index: 0,
                    segmentNumber: 2,
                    pixelData: .binary([0, 0, 0, 0, 0, 0, 0, 0, 0])
                ),
                DicomSegmentationFrame(
                    index: 1,
                    segmentNumber: 2,
                    pixelData: .binary([0, 0, 0, 0, 1, 0, 0, 0, 0])
                ),
                DicomSegmentationFrame(
                    index: 2,
                    segmentNumber: 2,
                    pixelData: .binary([0, 0, 0, 0, 0, 0, 0, 0, 0])
                )
            ]
        )
        let parsedSegmentation = try parseSegmentationPart10(segmentation)

        let overlay = try DicomSegmentationVolumeLayerBuilder.makeOverlay(
            from: parsedSegmentation,
            alignedTo: baseDataset,
            options: DicomSegmentationVolumeLayerOptions(layerID: "real-seg", opacity: 0.4)
        )
        let labelmap = try XCTUnwrap(overlay.volumeLayer.labelmap)
        let surfaceLayer = try XCTUnwrap(overlay.surfaceMeshLayers.first)

        XCTAssertEqual(overlay.volumeLayer.id, "real-seg")
        XCTAssertEqual(overlay.volumeLayer.opacity, 0.4)
        XCTAssertEqual(labelmap.dataset.dimensions, VolumeDimensions(width: 3, height: 3, depth: 3))
        XCTAssertEqual(labelmap.dataset.spacing, baseDataset.spacing)
        XCTAssertEqual(labelmap.segments.first?.label, 2)
        XCTAssertEqual(labelmap.segments.first?.name, "Target")
        XCTAssertEqual(littleEndianUInt16Values(labelmap.dataset.data),
                       [
                           0, 0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 2, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 0, 0, 0
                       ])
        XCTAssertEqual(overlay.surfaceMeshLayers.count, 1)
        XCTAssertEqual(surfaceLayer.id, "real-seg-surface-2")
        XCTAssertEqual(surfaceLayer.labelmapLabel, 2)
        XCTAssertEqual(surfaceLayer.segmentName, "Target")
        XCTAssertEqual(surfaceLayer.opacity, 0.4)
        XCTAssertTrue(surfaceLayer.isVisible)
        XCTAssertTrue(surfaceLayer.mesh.isRenderable)
        XCTAssertEqual(surfaceLayer.mesh.coordinateSpace, .worldMillimeters)
        XCTAssertNotNil(surfaceLayer.mesh.bounds)
    }

    func testDicomRTStructureSetMapsToContourOverlay() {
        let structureSet = DicomRTStructureSet(
            sopInstanceUID: "2.25.9801",
            label: "RT contours",
            rois: [
                DicomRTROI(number: 4,
                           name: "PTV",
                           observationLabel: "Target")
            ],
            roiContours: [
                DicomRTROIContour(
                    referencedROINumber: 4,
                    displayColor: [12, 128, 240],
                    contours: [
                        DicomRTContour(
                            number: 2,
                            geometricType: "CLOSED_PLANAR",
                            points: [
                                SIMD3<Double>(1, 2, 3),
                                SIMD3<Double>(4, 2, 3),
                                SIMD3<Double>(4, 5, 3)
                            ]
                        )
                    ]
                )
            ]
        )

        let overlay = DicomRTStructureContourOverlayBuilder.makeOverlay(
            from: structureSet,
            options: DicomRTStructureContourOverlayOptions(overlayID: "rt-overlay")
        )

        XCTAssertEqual(overlay.id, "rt-overlay")
        XCTAssertEqual(overlay.label, "RT contours")
        XCTAssertEqual(overlay.contours.count, 1)
        XCTAssertEqual(overlay.contours[0].id, "2.25.9801.roi-4.contour-2")
        XCTAssertEqual(overlay.contours[0].roiNumber, 4)
        XCTAssertEqual(overlay.contours[0].label, "Target")
        XCTAssertEqual(overlay.contours[0].geometricType, "CLOSED_PLANAR")
        XCTAssertEqual(overlay.contours[0].patientPoints[1], SIMD3<Double>(4, 2, 3))
        XCTAssertEqual(overlay.contours[0].displayColor.x, Float(12) / 255, accuracy: 0.0001)
        XCTAssertEqual(overlay.contours[0].displayColor.y, Float(128) / 255, accuracy: 0.0001)
        XCTAssertEqual(overlay.contours[0].displayColor.z, Float(240) / 255, accuracy: 0.0001)
    }

    func testDicomRTStructureSetMapsToSurfaceMeshLayers() throws {
        let structureSet = DicomRTStructureSet(
            sopInstanceUID: "2.25.9801",
            label: "RT contours",
            rois: [
                DicomRTROI(number: 4,
                           name: "PTV",
                           observationLabel: "Target")
            ],
            roiContours: [
                DicomRTROIContour(
                    referencedROINumber: 4,
                    displayColor: [12, 128, 240],
                    contours: [
                        DicomRTContour(
                            number: 1,
                            geometricType: "CLOSED_PLANAR",
                            points: [
                                SIMD3<Double>(1, 2, 3),
                                SIMD3<Double>(4, 2, 3),
                                SIMD3<Double>(4, 5, 3),
                                SIMD3<Double>(1, 5, 3)
                            ]
                        ),
                        DicomRTContour(
                            number: 2,
                            geometricType: "CLOSED_PLANAR",
                            points: [
                                SIMD3<Double>(1, 2, 7),
                                SIMD3<Double>(4, 2, 7),
                                SIMD3<Double>(4, 5, 7),
                                SIMD3<Double>(1, 5, 7)
                            ]
                        )
                    ]
                )
            ]
        )

        let layers = DicomRTStructureContourOverlayBuilder.makeSurfaceMeshLayers(
            from: structureSet,
            contourOptions: DicomRTStructureContourOverlayOptions(overlayID: "rt-overlay"),
            surfaceOptions: DicomRTStructureSurfaceMeshLayerOptions(layerIDPrefix: "rt-surface-",
                                                                    opacity: 0.4)
        )

        XCTAssertEqual(layers.count, 1)
        let layer = layers[0]
        XCTAssertEqual(layer.id, "rt-surface-roi-4")
        XCTAssertEqual(layer.opacity, 0.4)
        XCTAssertTrue(layer.isVisible)
        XCTAssertEqual(layer.mesh.metadata[SurfaceMeshMetadataKey.source], SurfaceMeshMetadataSource.rtStructure)
        XCTAssertEqual(layer.mesh.metadata[SurfaceMeshMetadataKey.roiNumber], "4")
        XCTAssertEqual(layer.segmentName, "Target")
        XCTAssertTrue(layer.mesh.isRenderable)
        XCTAssertEqual(layer.mesh.coordinateSpace, .worldMillimeters)
        XCTAssertEqual(layer.mesh.triangleCount, 12)
        let bounds = try XCTUnwrap(layer.mesh.bounds)
        XCTAssertEqual(bounds.min.z, 3, accuracy: 1e-5)
        XCTAssertEqual(bounds.max.z, 7, accuracy: 1e-5)
    }

    func testDicomRTDoseMapsToDoseVolumeOverlay() throws {
        let baseDataset = VolumeDataset(
            data: [Int16](repeating: 0, count: 8).withUnsafeBytes { Data($0) },
            dimensions: VolumeDimensions(width: 2, height: 2, depth: 2),
            spacing: VolumeSpacing(x: 1, y: 1, z: 5),
            pixelFormat: .int16Signed,
            orientation: VolumeOrientation(row: SIMD3<Float>(1, 0, 0),
                                           column: SIMD3<Float>(0, 1, 0),
                                           origin: SIMD3<Float>(10, 20, 30)),
            clinicalMetadata: ClinicalImageMetadata(
                modality: "CT",
                frameOfReferenceUID: "2.25.frame"
            )
        )
        let dose = DicomRTDoseVolume(
            sopInstanceUID: "2.25.dose",
            doseUnits: "GY",
            doseType: "PHYSICAL",
            doseSummationType: "PLAN",
            doseGridScaling: 0.01,
            frameOfReferenceUID: "2.25.frame",
            rows: 2,
            columns: 2,
            frames: 2,
            pixelSpacing: SIMD2<Double>(2, 3),
            imagePositionPatient: SIMD3<Double>(10, 20, 30),
            imageOrientationPatient: DicomPlaneOrientation(row: SIMD3<Double>(1, 0, 0),
                                                           column: SIMD3<Double>(0, 1, 0)),
            gridFrameOffsetVector: [0, 5],
            storedValues: [10, 20, 30, 40, 50, 60, 70, 80]
        )

        let overlay = try DicomRTDoseVolumeOverlayBuilder.makeOverlay(
            from: dose,
            alignedTo: baseDataset,
            options: DicomRTDoseVolumeOverlayOptions(layerID: "plan-dose", opacity: 0.35)
        )
        let dataset = try XCTUnwrap(overlay.doseDataset)
        let scalar = try XCTUnwrap(overlay.volumeLayer.scalarVolume)

        XCTAssertEqual(overlay.id, "plan-dose")
        XCTAssertEqual(overlay.doseUnits, "GY")
        XCTAssertEqual(overlay.doseGridScaling, 0.01)
        XCTAssertEqual(overlay.frameOfReferenceUID, "2.25.frame")
        XCTAssertEqual(overlay.volumeLayer.opacity, 0.35)
        XCTAssertEqual(dataset.dimensions, VolumeDimensions(width: 2, height: 2, depth: 2))
        XCTAssertEqual(dataset.spacing, VolumeSpacing(x: 3, y: 2, z: 5))
        XCTAssertEqual(dataset.imageData.origin, SIMD3<Float>(10, 20, 30))
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.modality, "RTDOSE")
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.frameOfReferenceUID, "2.25.frame")
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.rescaleSlope, 0.01)
        XCTAssertEqual(littleEndianUInt16Values(dataset.data), [10, 20, 30, 40, 50, 60, 70, 80])
        XCTAssertEqual(scalar.transferFunction.opacityPoints.first?.intensity, 0)

        let sample = try overlay.sampleDose(atBaseWorldPoint: SIMD3<Float>(10, 20, 30))
        XCTAssertEqual(sample.doseValue, 0.1, accuracy: 1e-6)
    }

    func testDicomRTDoseRejectsFrameOfReferenceMismatch() throws {
        let baseDataset = VolumeDataset(
            data: [Int16](repeating: 0, count: 1).withUnsafeBytes { Data($0) },
            dimensions: VolumeDimensions(width: 1, height: 1, depth: 1),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            clinicalMetadata: ClinicalImageMetadata(frameOfReferenceUID: "base-frame")
        )
        let dose = DicomRTDoseVolume(doseGridScaling: 1,
                                     frameOfReferenceUID: "dose-frame",
                                     rows: 1,
                                     columns: 1,
                                     frames: 1,
                                     storedValues: [1])

        XCTAssertThrowsError(
            try DicomRTDoseVolumeOverlayBuilder.makeOverlay(from: dose,
                                                            alignedTo: baseDataset)
        ) { error in
            XCTAssertEqual(error as? DicomRTDoseVolumeOverlayBridgeError,
                           .frameOfReferenceMismatch(base: "base-frame", dose: "dose-frame"))
        }
    }

    func testDicomParametricMapMapsToQuantitativeScalarVolumeLayer() throws {
        let baseDataset = VolumeDataset(
            data: [Int16](repeating: 0, count: 4).withUnsafeBytes { Data($0) },
            dimensions: VolumeDimensions(width: 2, height: 2, depth: 1),
            spacing: VolumeSpacing(x: 0.8, y: 0.9, z: 2),
            pixelFormat: .int16Signed,
            clinicalMetadata: ClinicalImageMetadata(frameOfReferenceUID: "2.25.frame")
        )
        let units = DicomCodedConcept(codeValue: "ml/min/100g",
                                      codingSchemeDesignator: "UCUM",
                                      codeMeaning: "mL/min/100 g")
        let quantity = DicomQuantityDefinition(
            conceptCode: DicomCodedConcept(codeValue: "113054",
                                           codingSchemeDesignator: "DCM",
                                           codeMeaning: "Perfusion")
        )
        let scalarVolume = DicomParametricMapScalarVolume(
            rows: 2,
            columns: 2,
            frameCount: 1,
            scalarValues: [1, 2, 3, 4],
            physicalValues: [0.5, 2.5, 5, 10],
            units: units,
            quantityDefinitions: [quantity]
        )
        let map = DicomParametricMap(
            sopInstanceUID: "2.25.pm",
            rows: 2,
            columns: 2,
            frameCount: 1,
            frames: [],
            realWorldValueMaps: [
                DicomParametricMapRealWorldValueMap(label: "Perfusion map",
                                                    units: units,
                                                    intercept: 0,
                                                    slope: 1)
            ],
            scalarVolume: scalarVolume
        )

        let layer = try DicomParametricMapScalarLayerBuilder.makeVolumeLayer(
            from: map,
            alignedTo: baseDataset,
            options: DicomParametricMapScalarLayerOptions(layerID: "perfusion",
                                                          opacity: 0.4)
        )

        let quantitative = try XCTUnwrap(layer.scalarVolume?.quantitativeMapping)
        XCTAssertEqual(layer.id, "perfusion")
        XCTAssertEqual(layer.opacity, 0.4)
        XCTAssertEqual(layer.scalarVolume?.dataset.imageData.clinicalMetadata?.modality, "PM")
        XCTAssertEqual(layer.scalarVolume?.dataset.spacing, baseDataset.spacing)
        XCTAssertEqual(quantitative.unitsLabel, "mL/min/100 g")
        XCTAssertEqual(quantitative.quantityLabel, "Perfusion")
        XCTAssertEqual(quantitative.physicalRange.lowerBound, 0.5)
        XCTAssertEqual(quantitative.physicalRange.upperBound, 10)
        XCTAssertEqual(try XCTUnwrap(layer.quantitativeLegend).title, "Perfusion map")

        let dataset = try XCTUnwrap(layer.scalarVolume?.dataset)
        let point = VolumePicking.worldPoint(forVoxelIndex: SIMD3<Float>(1, 0, 0),
                                             in: baseDataset)
        let samples = try VolumePicking.sampleScalarVolumes(in: [layer],
                                                            atBaseWorldPoint: point)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(try XCTUnwrap(samples[0].quantitativeValue).value, 2.5)
        XCTAssertEqual(dataset.data.count, 8)
    }

    func testDicomPETFusionMapsDecodedSeriesToSUVScalarVolumeLayer() throws {
        let baseDataset = VolumeDataset(
            data: [Int16](repeating: 0, count: 4).withUnsafeBytes { Data($0) },
            dimensions: VolumeDimensions(width: 2, height: 2, depth: 1),
            spacing: VolumeSpacing(x: 0.8, y: 0.9, z: 2),
            pixelFormat: .int16Signed,
            clinicalMetadata: ClinicalImageMetadata(modality: "CT",
                                                    frameOfReferenceUID: "2.25.frame")
        )
        let petValues: [Int16] = [1, 2, 3, 4]
        let decodedPET = DicomDecodedSeries(
            rawVoxels: petValues.withUnsafeBytes { Data($0) },
            modalityVoxels: petValues.withUnsafeBytes { Data($0) },
            sourcePixelRepresentation: .signedInt16,
            bitsAllocated: 16,
            dimensions: DicomSeriesDimensions(width: 2, height: 2, depth: 1),
            spacing: SIMD3<Double>(0.8, 0.9, 2),
            orientation: matrix_identity_double3x3,
            origin: SIMD3<Double>(0, 0, 0),
            modalityIntensityRange: 1...4,
            recommendedWindow: 1...4,
            modality: "PT",
            seriesDescription: "PET SUV fixture",
            studyInstanceUID: "2.25.study",
            seriesInstanceUID: "2.25.pet",
            frameOfReferenceUID: "2.25.frame",
            rescaleSlope: 1,
            rescaleIntercept: 0,
            windowCenter: nil,
            windowWidth: nil,
            quantitativeValueProfile: DicomQuantitativeValueProfile(
                suvMetadata: DicomSUVMetadata(
                    units: "GML",
                    suvType: "BW",
                    correctedImage: [],
                    decayCorrection: nil,
                    decayFactor: nil,
                    patientWeightKg: nil,
                    patientSizeMeters: nil,
                    patientSex: nil,
                    injectedDoseBq: nil,
                    radionuclideHalfLifeSeconds: nil,
                    radiopharmaceuticalStartTime: nil,
                    radiopharmaceuticalStartDateTime: nil,
                    acquisitionTime: nil
                )
            ),
            sourceURL: URL(fileURLWithPath: "/tmp/pet"),
            warnings: []
        )

        let layer = try DicomPETFusionLayerBuilder.makeVolumeLayer(
            from: decodedPET,
            alignedTo: baseDataset,
            options: DicomPETFusionLayerOptions(layerID: "pet-suv", opacity: 0.35)
        )

        XCTAssertEqual(layer.id, "pet-suv")
        XCTAssertEqual(layer.opacity, 0.35)
        XCTAssertEqual(layer.blendMode, .additive)
        XCTAssertEqual(layer.scalarVolume?.dataset.imageData.clinicalMetadata?.modality, "PT")
        XCTAssertEqual(layer.scalarVolume?.dataset.imageData.clinicalMetadata?.frameOfReferenceUID, "2.25.frame")
        XCTAssertEqual(layer.scalarVolume?.dataset.spacing, baseDataset.spacing)
        let mapping = try XCTUnwrap(layer.scalarVolume?.quantitativeMapping)
        XCTAssertEqual(mapping.unitsLabel, "Standardized Uptake Value body weight")
        XCTAssertEqual(mapping.physicalRange.lowerBound, 1)
        XCTAssertEqual(mapping.physicalRange.upperBound, 4)
        XCTAssertEqual(try XCTUnwrap(layer.quantitativeLegend).title, "SUV")

        let point = VolumePicking.worldPoint(forVoxelIndex: SIMD3<Float>(1, 0, 0),
                                             in: baseDataset)
        let samples = try VolumePicking.sampleScalarVolumes(in: [layer],
                                                            atBaseWorldPoint: point)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].intensity.storedScalar, 2)
        XCTAssertEqual(try XCTUnwrap(samples[0].quantitativeValue).value, 2, accuracy: 1e-6)
    }

    func testDicomPETFusionRejectsFrameOfReferenceMismatch() throws {
        let baseDataset = VolumeDataset(
            data: [Int16](repeating: 0, count: 1).withUnsafeBytes { Data($0) },
            dimensions: VolumeDimensions(width: 1, height: 1, depth: 1),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            clinicalMetadata: ClinicalImageMetadata(frameOfReferenceUID: "base-frame")
        )
        let petDataset = VolumeDataset(
            data: [Int16](repeating: 1, count: 1).withUnsafeBytes { Data($0) },
            dimensions: VolumeDimensions(width: 1, height: 1, depth: 1),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            clinicalMetadata: ClinicalImageMetadata(modality: "PT",
                                                    frameOfReferenceUID: "pet-frame")
        )

        XCTAssertThrowsError(
            try DicomPETFusionLayerBuilder.makeVolumeLayer(
                petDataset: petDataset,
                quantitativeValueProfile: DicomQuantitativeValueProfile(),
                alignedTo: baseDataset
            )
        ) { error in
            XCTAssertEqual(error as? DicomPETFusionLayerBridgeError,
                           .frameOfReferenceMismatch(base: "base-frame", pet: "pet-frame"))
        }
    }

    func testDicomPresentationStateMapsWindowShutterAndAnnotationsToMPRState() throws {
        let source = DicomPresentationReferencedImage(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.9401",
            referencedFrameNumbers: [2]
        )
        let profile = DicomDisplayTransformProfile(
            windows: [
                DicomDisplayWindow(
                    settings: WindowSettings(center: 50, width: 100),
                    explanation: "Soft tissue",
                    source: .dicom(index: 0)
                )
            ],
            presentationLUTShape: .inverse
        )
        let presentation = DicomGrayscalePresentationState(
            sopInstanceUID: "2.25.9402",
            referencedSeries: [
                DicomPresentationReferencedSeries(seriesInstanceUID: "2.25.9403", images: [source])
            ],
            displayedAreas: [
                DicomPresentationDisplayedArea(
                    topLeft: SIMD2<Int32>(2, 2),
                    bottomRight: SIMD2<Int32>(4, 4)
                )
            ],
            spatialTransform: DicomPresentationSpatialTransform(isHorizontallyFlipped: true,
                                                                rotationDegrees: 90),
            shutters: [.rectangular(left: 2, right: 4, upper: 2, lower: 4)],
            displayTransformProfile: profile,
            graphicLayers: [
                DicomPresentationGraphicLayer(name: "AI", recommendedDisplayGrayscaleValue: 65_535)
            ],
            graphicAnnotations: [
                DicomPresentationGraphicAnnotation(
                    graphicLayer: "AI",
                    referencedImages: [source],
                    graphicObjects: [
                        DicomPresentationGraphicObject(
                            graphicType: "POLYLINE",
                            graphicData: [1, 1, 5, 5],
                            trackingID: "finding"
                        )
                    ],
                    textObjects: [
                        DicomPresentationTextObject(text: "Finding", anchorPoint: SIMD2<Double>(3, 3))
                    ]
                )
            ],
            iccProfile: Data([1, 2, 3])
        )

        let state = DicomPresentationStateMPRBridge.makePresentationState(
            from: presentation,
            options: DicomPresentationStateMPRBridgeOptions(axis: .axial,
                                                            imageWidth: 5,
                                                            imageHeight: 5)
        )

        XCTAssertEqual(state.id, "2.25.9402")
        XCTAssertEqual(state.window, 0...100)
        XCTAssertEqual(state.invert, true)
        XCTAssertTrue(state.flipHorizontal)
        XCTAssertEqual(state.viewportTransform.rotationRadians, .pi / 2, accuracy: 0.0001)
        XCTAssertEqual(state.shutter, .rectangular(min: SIMD2<Float>(0.25, 0.25),
                                                   max: SIMD2<Float>(0.75, 0.75)))
        XCTAssertEqual(state.graphicAnnotations.count, 2)
        XCTAssertEqual(state.graphicAnnotations.first?.normalizedImagePoints,
                       [SIMD2<Float>(0, 0), SIMD2<Float>(1, 1)])
        XCTAssertEqual(state.graphicAnnotations.first?.sliceIndex, 1)
        XCTAssertEqual(state.graphicAnnotations.last?.kind, .text)
        XCTAssertEqual(state.graphicAnnotations.last?.text, "Finding")
        XCTAssertEqual(state.iccProfile, Data([1, 2, 3]))
    }

    func testImporterPassesDicomCoreErrorsWithoutSemanticRemapping() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let importer = DicomVolumeDatasetImporter()
        let expectation = expectation(description: "DICOM import fails")
        var captured: Error?

        importer.loadDataset(from: directory, progress: { _ in }) { result in
            if case .failure(let error) = result {
                captured = error
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)

        guard case DicomSeriesLoaderError.noDicomFiles = try XCTUnwrap(captured) else {
            XCTFail("Expected DicomSeriesLoaderError.noDicomFiles, got \(String(describing: captured))")
            return
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DicomBridgePackagingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func parseSegmentationPart10(_ segmentation: DicomSegmentation) throws -> DicomSegmentation {
        let dataSet = DicomSegmentationBuilder.dataSet(
            from: segmentation,
            studyInstanceUID: "2.25.9401",
            seriesInstanceUID: "2.25.9402"
        )
        let data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DicomSegmentationBuilder.segmentationStorageSOPClassUID,
                mediaStorageSOPInstanceUID: segmentation.sopInstanceUID
            )
        )
        let url = try makeTemporaryDirectory()
            .appendingPathComponent("segmentation.dcm")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try data.write(to: url)
        let decoder = try DCMDecoder(contentsOf: url)
        return try XCTUnwrap(decoder.segmentation)
    }

    private func makeProgressiveUpdate(index: Int,
                                       quality: ProgressiveVolumeQuality,
                                       fraction: Double,
                                       final: Bool,
                                       voxelValue: UInt16) -> DicomProgressiveVolumeBridgeUpdate {
        let voxels = [voxelValue, voxelValue, voxelValue, voxelValue].withUnsafeBytes { Data($0) }
        let volume = DicomSeriesVolume(
            voxels: voxels,
            width: 2,
            height: 2,
            depth: 1,
            spacing: SIMD3<Double>(1, 1, 1),
            orientation: matrix_identity_double3x3,
            origin: SIMD3<Double>(0, 0, 0),
            rescaleSlope: 1,
            rescaleIntercept: 0,
            bitsAllocated: 16,
            isSignedPixel: false,
            seriesDescription: "Progressive bridge fixture",
            modality: "CT"
        )
        let layer = ProgressiveVolumeLayer(
            index: index,
            totalLayerCount: 2,
            quality: quality,
            fractionComplete: fraction,
            isFinal: final
        )
        return DicomProgressiveVolumeBridgeUpdate(layer: layer, volume: volume)
    }

    private func makeDicomProgressiveUpdate(index: Int,
                                            quality: DicomProgressiveUpdateQuality,
                                            fraction: Double,
                                            final: Bool,
                                            voxelValue: UInt16) -> DicomProgressiveVolumeUpdate {
        let voxels = [voxelValue, voxelValue, voxelValue, voxelValue].withUnsafeBytes { Data($0) }
        let volume = DicomSeriesVolume(
            voxels: voxels,
            width: 2,
            height: 2,
            depth: 1,
            spacing: SIMD3<Double>(1, 1, 1),
            orientation: matrix_identity_double3x3,
            origin: SIMD3<Double>(0, 0, 0),
            rescaleSlope: 1,
            rescaleIntercept: 0,
            bitsAllocated: 16,
            isSignedPixel: false,
            seriesDescription: "JPIP bridge fixture",
            modality: "CT"
        )
        let layer = DicomProgressiveLayer(
            index: index,
            totalLayerCount: 3,
            quality: quality,
            byteRange: index..<(index + 1),
            fractionComplete: fraction,
            isFinal: final
        )
        return DicomProgressiveVolumeUpdate(layer: layer, volume: volume)
    }

    private func littleEndianInt16Values(_ data: Data) -> [Int16] {
        stride(from: 0, to: data.count, by: 2).map { offset in
            let value = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            return Int16(bitPattern: value)
        }
    }

    private func littleEndianUInt16Values(_ data: Data) -> [UInt16] {
        stride(from: 0, to: data.count, by: 2).map { offset in
            UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }
    }
}
