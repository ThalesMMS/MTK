import DicomCore
import Foundation
import MTKCore
import simd

public enum VolumeMaskDicomSegmentationExportError: Error, Equatable, LocalizedError {
    case mismatchedDimensions(base: VolumeDimensions, edited: VolumeDimensions)
    case mismatchedPixelFormat(base: VolumePixelFormat, edited: VolumePixelFormat)
    case invalidDataSize(expected: Int, baseActual: Int, editedActual: Int)
    case noEditedVoxels

    public var errorDescription: String? {
        switch self {
        case .mismatchedDimensions(let base, let edited):
            return "Volume mask export requires matching dimensions; got base \(base) and edited \(edited)."
        case .mismatchedPixelFormat(let base, let edited):
            return "Volume mask export requires matching pixel formats; got base \(base.scalarTypeDescription) and edited \(edited.scalarTypeDescription)."
        case .invalidDataSize(let expected, let baseActual, let editedActual):
            return "Volume mask export expected \(expected) bytes; got base \(baseActual) and edited \(editedActual)."
        case .noEditedVoxels:
            return "Volume mask export requires at least one edited voxel."
        }
    }
}

public struct VolumeMaskDicomSegmentationExportOptions: Equatable, Sendable {
    public var sopInstanceUID: String?
    public var studyInstanceUID: String?
    public var seriesInstanceUID: String?
    public var contentLabel: String
    public var segment: DicomSegment
    public var sourceImageReferencesBySlice: [Int: [DicomSourceImageReference]]

    public init(
        sopInstanceUID: String? = nil,
        studyInstanceUID: String? = nil,
        seriesInstanceUID: String? = nil,
        contentLabel: String = "BRUSH_MASK",
        segment: DicomSegment = DicomSegment(
            number: 1,
            label: "Brush mask",
            description: "Edited volume brush mask",
            algorithmType: "MANUAL"
        ),
        sourceImageReferencesBySlice: [Int: [DicomSourceImageReference]] = [:]
    ) {
        self.sopInstanceUID = sopInstanceUID
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.contentLabel = contentLabel
        self.segment = segment
        self.sourceImageReferencesBySlice = sourceImageReferencesBySlice
    }
}

public enum VolumeMaskDicomSegmentationExporter {
    public static func makeSegmentation(
        baseDataset: VolumeDataset,
        editedDataset: VolumeDataset,
        options: VolumeMaskDicomSegmentationExportOptions = VolumeMaskDicomSegmentationExportOptions()
    ) throws -> DicomSegmentation {
        try validate(baseDataset: baseDataset, editedDataset: editedDataset)
        let frames = try makeFrames(baseDataset: baseDataset,
                                    editedDataset: editedDataset,
                                    options: options)
        guard frames.contains(where: { $0.pixelData.storedValues.contains { $0 != 0 } }) else {
            throw VolumeMaskDicomSegmentationExportError.noEditedVoxels
        }
        return DicomSegmentation(
            sopInstanceUID: options.sopInstanceUID,
            segmentationType: .binary,
            rows: baseDataset.dimensions.height,
            columns: baseDataset.dimensions.width,
            segments: [options.segment],
            frames: frames
        )
    }

    public static func makeDataSet(
        baseDataset: VolumeDataset,
        editedDataset: VolumeDataset,
        options: VolumeMaskDicomSegmentationExportOptions = VolumeMaskDicomSegmentationExportOptions()
    ) throws -> DicomDataSet {
        let segmentation = try makeSegmentation(baseDataset: baseDataset,
                                                editedDataset: editedDataset,
                                                options: options)
        let metadata = baseDataset.imageData.clinicalMetadata
        return DicomSegmentationBuilder.dataSet(
            from: segmentation,
            studyInstanceUID: options.studyInstanceUID ?? metadata?.studyInstanceUID ?? DicomDataSetWriter.makeUID(),
            seriesInstanceUID: options.seriesInstanceUID ?? DicomDataSetWriter.makeUID(),
            sopInstanceUID: options.sopInstanceUID,
            contentLabel: options.contentLabel
        )
    }

    public static func makePart10Data(
        baseDataset: VolumeDataset,
        editedDataset: VolumeDataset,
        options: VolumeMaskDicomSegmentationExportOptions = VolumeMaskDicomSegmentationExportOptions()
    ) throws -> Data {
        let dataSet = try makeDataSet(baseDataset: baseDataset,
                                      editedDataset: editedDataset,
                                      options: options)
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DicomSegmentationBuilder.segmentationStorageSOPClassUID,
                mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)
            )
        )
    }

    private static func validate(baseDataset: VolumeDataset,
                                 editedDataset: VolumeDataset) throws {
        guard baseDataset.dimensions == editedDataset.dimensions else {
            throw VolumeMaskDicomSegmentationExportError.mismatchedDimensions(
                base: baseDataset.dimensions,
                edited: editedDataset.dimensions
            )
        }
        guard baseDataset.pixelFormat == editedDataset.pixelFormat else {
            throw VolumeMaskDicomSegmentationExportError.mismatchedPixelFormat(
                base: baseDataset.pixelFormat,
                edited: editedDataset.pixelFormat
            )
        }
        let expected = baseDataset.dimensions.voxelCount * baseDataset.pixelFormat.bytesPerVoxel
        guard baseDataset.data.count == expected,
              editedDataset.data.count == expected else {
            throw VolumeMaskDicomSegmentationExportError.invalidDataSize(
                expected: expected,
                baseActual: baseDataset.data.count,
                editedActual: editedDataset.data.count
            )
        }
    }

    private static func makeFrames(
        baseDataset: VolumeDataset,
        editedDataset: VolumeDataset,
        options: VolumeMaskDicomSegmentationExportOptions
    ) throws -> [DicomSegmentationFrame] {
        let dimensions = baseDataset.dimensions
        let bytesPerVoxel = baseDataset.pixelFormat.bytesPerVoxel
        let pixelsPerSlice = dimensions.width * dimensions.height
        return (0..<dimensions.depth).map { slice in
            let pixels = makeFramePixels(baseData: baseDataset.data,
                                         editedData: editedDataset.data,
                                         slice: slice,
                                         pixelsPerSlice: pixelsPerSlice,
                                         bytesPerVoxel: bytesPerVoxel)
            let sourceReferences = options.sourceImageReferencesBySlice[slice] ?? []
            return DicomSegmentationFrame(
                index: slice,
                segmentNumber: options.segment.number,
                geometry: makeGeometry(forSlice: slice,
                                       dataset: baseDataset,
                                       sourceImageReferences: sourceReferences),
                sourceImageReferences: sourceReferences,
                pixelData: .binary(pixels)
            )
        }
    }

    private static func makeFramePixels(baseData: Data,
                                        editedData: Data,
                                        slice: Int,
                                        pixelsPerSlice: Int,
                                        bytesPerVoxel: Int) -> [UInt8] {
        let sliceByteOffset = slice * pixelsPerSlice * bytesPerVoxel
        return (0..<pixelsPerSlice).map { pixel in
            let start = sliceByteOffset + pixel * bytesPerVoxel
            let end = start + bytesPerVoxel
            return baseData[start..<end].elementsEqual(editedData[start..<end]) ? 0 : 1
        }
    }

    private static func makeGeometry(
        forSlice slice: Int,
        dataset: VolumeDataset,
        sourceImageReferences: [DicomSourceImageReference]
    ) -> DicomFrameGeometry? {
        let imageData = dataset.imageData
        let origin = imageData.indexToWorld.transformPoint(SIMD3<Float>(0, 0, Float(slice)))
        let groups = DicomFrameFunctionalGroups(
            frameContent: DicomFrameContent(
                dimensionIndexValues: [slice + 1],
                stackID: "SEG",
                inStackPositionNumber: slice + 1,
                temporalPositionIndex: nil,
                frameAcquisitionNumber: nil
            ),
            pixelMeasures: DicomPixelMeasures(
                pixelSpacing: SIMD2<Double>(dataset.spacing.x, dataset.spacing.y),
                sliceThickness: dataset.spacing.z,
                spacingBetweenSlices: dataset.spacing.z
            ),
            planePosition: DicomPlanePosition(
                imagePositionPatient: SIMD3<Double>(Double(origin.x), Double(origin.y), Double(origin.z))
            ),
            planeOrientation: DicomPlaneOrientation(
                row: SIMD3<Double>(Double(imageData.rowDirection.x),
                                   Double(imageData.rowDirection.y),
                                   Double(imageData.rowDirection.z)),
                column: SIMD3<Double>(Double(imageData.columnDirection.x),
                                      Double(imageData.columnDirection.y),
                                      Double(imageData.columnDirection.z))
            ),
            derivationImage: sourceImageReferences.isEmpty ? nil : DicomDerivationImage(sourceImages: sourceImageReferences)
        )
        return DicomFrameGeometry(frameIndex: slice, functionalGroups: groups)
    }
}
