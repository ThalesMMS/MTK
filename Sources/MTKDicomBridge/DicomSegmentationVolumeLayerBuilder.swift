import DicomCore
import Foundation
import MTKCore
import simd

public enum DicomSegmentationVolumeLayerBridgeError: Error, Equatable, LocalizedError {
    case emptySegmentation
    case invalidDimensions(columns: Int, rows: Int, baseWidth: Int, baseHeight: Int)
    case invalidFramePixelCount(frameIndex: Int, expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .emptySegmentation:
            return "DICOM SEG contains no frames or segments."
        case let .invalidDimensions(columns, rows, baseWidth, baseHeight):
            return "DICOM SEG dimensions \(columns)x\(rows) do not match base volume \(baseWidth)x\(baseHeight)."
        case let .invalidFramePixelCount(frameIndex, expected, actual):
            return "DICOM SEG frame \(frameIndex) has \(actual) pixels; expected \(expected)."
        }
    }
}

public struct DicomSegmentationVolumeLayerOptions: Equatable, Sendable {
    public var layerID: String?
    public var opacity: Float
    public var isVisible: Bool
    public var seriesDescription: String?
    public var includeSurfaceMeshLayers: Bool
    public var surfaceMeshLayerIDPrefix: String?
    public var surfaceMeshCoordinateSpace: SurfaceMeshCoordinateSpace

    public init(
        layerID: String? = nil,
        opacity: Float = 0.65,
        isVisible: Bool = true,
        seriesDescription: String? = "DICOM segmentation",
        includeSurfaceMeshLayers: Bool = true,
        surfaceMeshLayerIDPrefix: String? = nil,
        surfaceMeshCoordinateSpace: SurfaceMeshCoordinateSpace = .worldMillimeters
    ) {
        self.layerID = layerID
        self.opacity = opacity
        self.isVisible = isVisible
        self.seriesDescription = seriesDescription
        self.includeSurfaceMeshLayers = includeSurfaceMeshLayers
        self.surfaceMeshLayerIDPrefix = surfaceMeshLayerIDPrefix
        self.surfaceMeshCoordinateSpace = surfaceMeshCoordinateSpace
    }
}

public struct DicomSegmentationOverlay: Equatable, Sendable {
    public var volumeLayer: VolumeLayer
    public var surfaceMeshLayers: [SurfaceMeshLayer]

    public init(volumeLayer: VolumeLayer,
                surfaceMeshLayers: [SurfaceMeshLayer]) {
        self.volumeLayer = volumeLayer
        self.surfaceMeshLayers = surfaceMeshLayers
    }
}

public enum DicomSegmentationVolumeLayerBuilder {
    public static func makeOverlay(
        from segmentation: DicomSegmentation,
        alignedTo baseDataset: VolumeDataset,
        options: DicomSegmentationVolumeLayerOptions = DicomSegmentationVolumeLayerOptions()
    ) throws -> DicomSegmentationOverlay {
        let labelmap = try makeLabelmapVolume(from: segmentation, alignedTo: baseDataset, options: options)
        let layer = makeVolumeLayer(
            from: labelmap,
            id: options.layerID ?? segmentation.sopInstanceUID ?? "dicom-segmentation",
            options: options
        )
        let surfaceMeshLayers = try makeSurfaceMeshLayers(
            from: labelmap,
            baseLayerID: layer.id,
            options: options
        )
        return DicomSegmentationOverlay(volumeLayer: layer,
                                        surfaceMeshLayers: surfaceMeshLayers)
    }

    public static func makeVolumeLayer(
        from segmentation: DicomSegmentation,
        alignedTo baseDataset: VolumeDataset,
        options: DicomSegmentationVolumeLayerOptions = DicomSegmentationVolumeLayerOptions()
    ) throws -> VolumeLayer {
        let labelmap = try makeLabelmapVolume(from: segmentation, alignedTo: baseDataset, options: options)
        return makeVolumeLayer(
            from: labelmap,
            id: options.layerID ?? segmentation.sopInstanceUID ?? "dicom-segmentation",
            options: options
        )
    }

    public static func makeSurfaceMeshLayers(
        from labelmap: LabelmapVolume,
        options: DicomSegmentationVolumeLayerOptions = DicomSegmentationVolumeLayerOptions()
    ) throws -> [SurfaceMeshLayer] {
        try makeSurfaceMeshLayers(
            from: labelmap,
            baseLayerID: options.layerID ?? "dicom-segmentation",
            options: options
        )
    }

    private static func makeVolumeLayer(
        from labelmap: LabelmapVolume,
        id: String,
        options: DicomSegmentationVolumeLayerOptions
    ) -> VolumeLayer {
        return VolumeLayer(
            id: id,
            labelmap: labelmap,
            opacity: options.opacity,
            isVisible: options.isVisible
        )
    }

    public static func makeLabelmapVolume(
        from segmentation: DicomSegmentation,
        alignedTo baseDataset: VolumeDataset,
        options: DicomSegmentationVolumeLayerOptions = DicomSegmentationVolumeLayerOptions()
    ) throws -> LabelmapVolume {
        guard !segmentation.frames.isEmpty, !segmentation.segments.isEmpty else {
            throw DicomSegmentationVolumeLayerBridgeError.emptySegmentation
        }
        guard segmentation.columns == baseDataset.dimensions.width,
              segmentation.rows == baseDataset.dimensions.height else {
            throw DicomSegmentationVolumeLayerBridgeError.invalidDimensions(
                columns: segmentation.columns,
                rows: segmentation.rows,
                baseWidth: baseDataset.dimensions.width,
                baseHeight: baseDataset.dimensions.height
            )
        }

        let composition = try composeLabelmapVoxels(from: segmentation)
        var imageData = baseDataset.imageData
        imageData.dimensions = VolumeDimensions(
            width: segmentation.columns,
            height: segmentation.rows,
            depth: composition.depth
        )
        imageData.pixelFormat = .int16Unsigned
        imageData.intensityRange = 0...Int32(segmentation.segments.map(\.number).max() ?? 0)
        var metadata = imageData.clinicalMetadata ?? ClinicalImageMetadata()
        metadata.modality = "SEG"
        metadata.seriesDescription = options.seriesDescription
        metadata.sourcePixelFormat = .int16Unsigned
        imageData.clinicalMetadata = metadata

        return try LabelmapVolume(
            dataset: VolumeDataset(data: littleEndianData(from: composition.voxels), imageData: imageData),
            segments: segmentation.segments.enumerated().map { index, segment in
                LabelmapSegment(
                    label: UInt16(clamping: segment.number),
                    name: segment.label,
                    color: color(for: segment, fallbackIndex: index)
                )
            }
        )
    }

    private static func makeSurfaceMeshLayers(
        from labelmap: LabelmapVolume,
        baseLayerID: String,
        options: DicomSegmentationVolumeLayerOptions
    ) throws -> [SurfaceMeshLayer] {
        guard options.includeSurfaceMeshLayers,
              canExtractSurface(from: labelmap.dataset.dimensions) else {
            return []
        }
        let idPrefix = options.surfaceMeshLayerIDPrefix ?? "\(baseLayerID)-surface-"
        let extractor = MarchingCubesExtractor()
        return try labelmap.segments.compactMap { segment in
            let mesh = try extractor.extractSurface(from: labelmap,
                                                    label: segment.label,
                                                    coordinateSpace: options.surfaceMeshCoordinateSpace)
            guard mesh.isRenderable else { return nil }
            return SurfaceMeshLayer(id: "\(idPrefix)\(segment.label)",
                                    mesh: mesh,
                                    material: SurfaceMeshMaterial(color: segment.color),
                                    opacity: options.opacity,
                                    isVisible: options.isVisible && segment.isVisible)
        }
    }

    private static func composeLabelmapVoxels(
        from segmentation: DicomSegmentation
    ) throws -> (voxels: [UInt16], depth: Int) {
        let pixelCount = segmentation.rows * segmentation.columns
        let orderedKeys = orderedFrameKeys(for: segmentation.frames)
        let keyToSlice: [String: Int] = Dictionary(uniqueKeysWithValues: orderedKeys.enumerated().map { ($0.element, $0.offset) })
        var voxels = [UInt16](repeating: 0, count: pixelCount * orderedKeys.count)

        for frame in segmentation.frames {
            let values = frame.pixelData.storedValues
            guard values.count == pixelCount else {
                throw DicomSegmentationVolumeLayerBridgeError.invalidFramePixelCount(
                    frameIndex: frame.index,
                    expected: pixelCount,
                    actual: values.count
                )
            }
            guard let slice = keyToSlice[frameKey(frame)] else { continue }
            let segmentValue = UInt16(clamping: frame.segmentNumber)
            let offset = slice * pixelCount
            for pixelIndex in 0..<pixelCount where values[pixelIndex] != 0 {
                voxels[offset + pixelIndex] = segmentValue
            }
        }
        return (voxels, max(1, orderedKeys.count))
    }

    private static func orderedFrameKeys(for frames: [DicomSegmentationFrame]) -> [String] {
        var keys: [String] = []
        for frame in frames {
            let key = frameKey(frame)
            if !keys.contains(key) {
                keys.append(key)
            }
        }
        return keys
    }

    private static func frameKey(_ frame: DicomSegmentationFrame) -> String {
        if let stackPosition = frame.geometry?.frameContent?.inStackPositionNumber {
            return "stack:\(stackPosition)"
        }
        return "index:\(frame.index)"
    }

    private static func littleEndianData(from voxels: [UInt16]) -> Data {
        var data = Data()
        data.reserveCapacity(voxels.count * MemoryLayout<UInt16>.size)
        for value in voxels {
            data.append(UInt8(value & 0x00FF))
            data.append(UInt8((value >> 8) & 0x00FF))
        }
        return data
    }

    private static func color(for segment: DicomSegment, fallbackIndex: Int) -> SIMD4<Float> {
        let palette: [SIMD4<Float>] = [
            SIMD4<Float>(1.0, 0.18, 0.12, 1),
            SIMD4<Float>(0.1, 0.55, 1.0, 1),
            SIMD4<Float>(0.1, 0.85, 0.45, 1),
            SIMD4<Float>(1.0, 0.78, 0.1, 1),
            SIMD4<Float>(0.85, 0.35, 1.0, 1)
        ]
        guard segment.recommendedDisplayCIELabValue.count == 3 else {
            return palette[fallbackIndex % palette.count]
        }
        let lightness = Float(segment.recommendedDisplayCIELabValue[0]) / 65535.0
        let a = (Float(segment.recommendedDisplayCIELabValue[1]) - 32768.0) / 32768.0
        let b = (Float(segment.recommendedDisplayCIELabValue[2]) - 32768.0) / 32768.0
        return SIMD4<Float>(
            clamp01(lightness + max(Float(0), a) * 0.35),
            clamp01(lightness - abs(a) * 0.2 + max(Float(0), b) * 0.1),
            clamp01(lightness + max(Float(0), -b) * 0.35),
            1
        )
    }

    private static func clamp01(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    private static func canExtractSurface(from dimensions: VolumeDimensions) -> Bool {
        dimensions.width >= 2 &&
            dimensions.height >= 2 &&
            dimensions.depth >= 2
    }
}
