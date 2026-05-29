import CoreGraphics
import DicomCore
import Foundation
import MTKCore
import MTKUI
import simd

public enum ViewerROIDicomRoundTripError: Error, Equatable, LocalizedError {
    case missingLabelmapLayer(String)
    case invalidLabelmapData(expectedBytes: Int, actualBytes: Int)
    case noSegmentVoxels

    public var errorDescription: String? {
        switch self {
        case .missingLabelmapLayer(let layerID):
            return "Volume layer \(layerID) does not contain a labelmap ROI mask."
        case let .invalidLabelmapData(expectedBytes, actualBytes):
            return "Labelmap ROI mask expected \(expectedBytes) bytes; got \(actualBytes)."
        case .noSegmentVoxels:
            return "Labelmap ROI mask does not contain any selected segment voxels."
        }
    }
}

public struct ViewerROIDicomRoundTripOptions: Equatable, Sendable {
    public var sopInstanceUID: String?
    public var studyInstanceUID: String?
    public var sourceSeriesInstanceUID: String?
    public var outputSeriesInstanceUID: String?
    public var sourceSOPClassUID: String?
    public var sourceSOPInstanceUID: String?
    public var imageWidth: Int
    public var imageHeight: Int
    public var contentLabel: String
    public var contentDescription: String?
    public var graphicLayerName: String
    public var sourceImageReferencesBySlice: [Int: [DicomSourceImageReference]]

    public init(
        sopInstanceUID: String? = nil,
        studyInstanceUID: String? = nil,
        sourceSeriesInstanceUID: String? = nil,
        outputSeriesInstanceUID: String? = nil,
        sourceSOPClassUID: String? = nil,
        sourceSOPInstanceUID: String? = nil,
        imageWidth: Int,
        imageHeight: Int,
        contentLabel: String = "ROI",
        contentDescription: String? = "Viewer ROI annotations",
        graphicLayerName: String = "ROI",
        sourceImageReferencesBySlice: [Int: [DicomSourceImageReference]] = [:]
    ) {
        self.sopInstanceUID = sopInstanceUID
        self.studyInstanceUID = studyInstanceUID
        self.sourceSeriesInstanceUID = sourceSeriesInstanceUID
        self.outputSeriesInstanceUID = outputSeriesInstanceUID
        self.sourceSOPClassUID = sourceSOPClassUID
        self.sourceSOPInstanceUID = sourceSOPInstanceUID
        self.imageWidth = max(imageWidth, 1)
        self.imageHeight = max(imageHeight, 1)
        self.contentLabel = contentLabel
        self.contentDescription = contentDescription
        self.graphicLayerName = graphicLayerName
        self.sourceImageReferencesBySlice = sourceImageReferencesBySlice
    }
}

public enum ViewerROIDicomRoundTrip {
    public static func makeStructuredReport(
        from annotations: [ViewerROIAnnotation],
        options: ViewerROIDicomRoundTripOptions
    ) -> DicomSRDocument {
        let measurementItems = annotations.compactMap { measurementContentItem(from: $0, options: options) }
        let evidenceReferences = unique(measurementItems.flatMap(\.allSourceImageReferences).map {
            DicomKeyObjectReference(
                studyInstanceUID: options.studyInstanceUID,
                seriesInstanceUID: options.sourceSeriesInstanceUID,
                referencedSOPClassUID: $0.referencedSOPClassUID,
                referencedSOPInstanceUID: $0.referencedSOPInstanceUID,
                referencedFrameNumbers: $0.referencedFrameNumbers
            )
        })

        return DicomSRDocument(
            sopClassUID: DicomSRDocument.comprehensiveSRStorageSOPClassUID,
            sopInstanceUID: options.sopInstanceUID,
            modality: "SR",
            contentLabel: options.contentLabel,
            contentDescription: options.contentDescription,
            completionFlag: "COMPLETE",
            verificationFlag: "UNVERIFIED",
            templateIdentifier: "1500",
            root: DicomSRContentItem(
                valueType: "CONTAINER",
                conceptName: reportConcept,
                continuityOfContent: "SEPARATE",
                children: measurementItems
            ),
            evidenceReferences: evidenceReferences
        )
    }

    public static func makeStructuredReportDataSet(
        from annotations: [ViewerROIAnnotation],
        options: ViewerROIDicomRoundTripOptions
    ) -> DicomDataSet {
        let document = makeStructuredReport(from: annotations, options: options)
        return DicomStructuredReportBuilder.dataSet(
            from: document,
            studyInstanceUID: studyInstanceUID(options: options),
            seriesInstanceUID: outputSeriesInstanceUID(options: options),
            sopInstanceUID: options.sopInstanceUID
        )
    }

    public static func makeStructuredReportPart10Data(
        from annotations: [ViewerROIAnnotation],
        options: ViewerROIDicomRoundTripOptions
    ) throws -> Data {
        let dataSet = makeStructuredReportDataSet(from: annotations, options: options)
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DicomSRDocument.comprehensiveSRStorageSOPClassUID,
                mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)
            )
        )
    }

    public static func makeAnnotations(
        from structuredReport: DicomSRDocument,
        axis: MTKCore.Axis = .axial,
        options: ViewerROIDicomRoundTripOptions
    ) -> [ViewerROIAnnotation] {
        structuredReport.measurements.compactMap { measurement in
            guard let roi = measurement.roi else { return nil }
            let points = normalizedPoints(from: roi.graphicData,
                                          imageWidth: options.imageWidth,
                                          imageHeight: options.imageHeight)
            guard !points.isEmpty else { return nil }
            return ViewerROIAnnotation(
                id: measurement.trackingID.flatMap(UUID.init(uuidString:)) ?? UUID(),
                kind: roiKind(from: measurement, graphicType: roi.graphicType),
                axis: axis,
                sliceIndex: measurement.sourceImageReferences.first?.referencedFrameNumbers.first.map { max($0 - 1, 0) },
                normalizedImagePoints: points,
                measurement: viewerMeasurement(from: measurement)
            )
        }
    }

    public static func makePresentationState(
        from annotations: [ViewerROIAnnotation],
        options: ViewerROIDicomRoundTripOptions
    ) -> DicomGrayscalePresentationState {
        let graphicAnnotations = annotations.compactMap {
            presentationAnnotation(from: $0, options: options)
        }
        let layer = DicomPresentationGraphicLayer(
            name: options.graphicLayerName,
            order: 1,
            recommendedDisplayGrayscaleValue: annotations.first.map { grayscaleValue(for: $0.style) } ?? 65_535,
            description: options.contentDescription
        )

        return DicomGrayscalePresentationState(
            sopInstanceUID: options.sopInstanceUID,
            studyInstanceUID: options.studyInstanceUID,
            seriesInstanceUID: options.outputSeriesInstanceUID,
            contentLabel: options.contentLabel,
            contentDescription: options.contentDescription,
            referencedSeries: presentationReferencedSeries(from: annotations, options: options),
            displayedAreas: [
                DicomPresentationDisplayedArea(
                    bottomRight: SIMD2<Int32>(
                        Int32(clamping: options.imageWidth),
                        Int32(clamping: options.imageHeight)
                    )
                )
            ],
            graphicLayers: [layer],
            graphicAnnotations: graphicAnnotations
        )
    }

    public static func makePresentationStateDataSet(
        from annotations: [ViewerROIAnnotation],
        options: ViewerROIDicomRoundTripOptions
    ) -> DicomDataSet {
        let presentationState = makePresentationState(from: annotations, options: options)
        return DicomGrayscalePresentationStateBuilder.dataSet(
            referencedSeries: presentationState.referencedSeries,
            graphicAnnotations: presentationState.graphicAnnotations,
            graphicLayers: presentationState.graphicLayers,
            options: DicomPresentationStateBuildOptions(
                sopInstanceUID: options.sopInstanceUID,
                studyInstanceUID: studyInstanceUID(options: options),
                seriesInstanceUID: outputSeriesInstanceUID(options: options),
                contentLabel: options.contentLabel,
                contentDescription: options.contentDescription,
                displayedArea: presentationState.displayedAreas.first
            )
        )
    }

    public static func makePresentationStatePart10Data(
        from annotations: [ViewerROIAnnotation],
        options: ViewerROIDicomRoundTripOptions
    ) throws -> Data {
        let dataSet = makePresentationStateDataSet(from: annotations, options: options)
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DicomGrayscalePresentationState.storageSOPClassUID,
                mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)
            )
        )
    }

    public static func makeSegmentation(
        from layer: VolumeLayer,
        labels selectedLabels: Set<UInt16>? = nil,
        options: ViewerROIDicomRoundTripOptions
    ) throws -> DicomSegmentation {
        guard let labelmap = layer.labelmap else {
            throw ViewerROIDicomRoundTripError.missingLabelmapLayer(layer.id)
        }
        let dimensions = labelmap.dataset.dimensions
        let values = try labelmapValues(from: labelmap.dataset)
        let labels = labelsWithVoxels(in: values, labelmap: labelmap, selectedLabels: selectedLabels)
        guard !labels.isEmpty else {
            throw ViewerROIDicomRoundTripError.noSegmentVoxels
        }

        var frames: [DicomSegmentationFrame] = []
        let pixelsPerSlice = dimensions.width * dimensions.height
        for label in labels {
            for slice in 0..<dimensions.depth {
                let pixels = (0..<pixelsPerSlice).map { pixelIndex -> UInt8 in
                    values[slice * pixelsPerSlice + pixelIndex] == label ? 1 : 0
                }
                let references = sourceImageReferences(forSlice: slice, options: options)
                frames.append(DicomSegmentationFrame(
                    index: frames.count,
                    segmentNumber: Int(label),
                    geometry: frameGeometry(forSlice: slice,
                                            frameIndex: frames.count,
                                            dataset: labelmap.dataset,
                                            sourceImageReferences: references),
                    sourceImageReferences: references,
                    pixelData: .binary(pixels)
                ))
            }
        }

        return DicomSegmentation(
            sopInstanceUID: options.sopInstanceUID,
            segmentationType: .binary,
            rows: dimensions.height,
            columns: dimensions.width,
            segments: labels.map { segment(label: $0, labelmap: labelmap) },
            frames: frames
        )
    }

    public static func makeSegmentationDataSet(
        from layer: VolumeLayer,
        labels selectedLabels: Set<UInt16>? = nil,
        options: ViewerROIDicomRoundTripOptions
    ) throws -> DicomDataSet {
        let segmentation = try makeSegmentation(from: layer, labels: selectedLabels, options: options)
        let metadata = layer.labelmap?.dataset.imageData.clinicalMetadata
        return DicomSegmentationBuilder.dataSet(
            from: segmentation,
            studyInstanceUID: studyInstanceUID(options: options, metadata: metadata),
            seriesInstanceUID: outputSeriesInstanceUID(options: options),
            sopInstanceUID: options.sopInstanceUID,
            contentLabel: options.contentLabel
        )
    }

    public static func makeSegmentationPart10Data(
        from layer: VolumeLayer,
        labels selectedLabels: Set<UInt16>? = nil,
        options: ViewerROIDicomRoundTripOptions
    ) throws -> Data {
        let dataSet = try makeSegmentationDataSet(from: layer, labels: selectedLabels, options: options)
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DicomSegmentationBuilder.segmentationStorageSOPClassUID,
                mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)
            )
        )
    }
}

private extension ViewerROIDicomRoundTrip {
    static let codingScheme = "99MTK"
    static let reportConcept = DicomCodedConcept(
        codeValue: "126000",
        codingSchemeDesignator: "DCM",
        codeMeaning: "Imaging Measurement Report"
    )
    static let imageRegionConcept = DicomCodedConcept(
        codeValue: "111030",
        codingSchemeDesignator: "DCM",
        codeMeaning: "Image Region"
    )
    static let sourceImageConcept = DicomCodedConcept(
        codeValue: "121112",
        codingSchemeDesignator: "DCM",
        codeMeaning: "Source image"
    )

    static func measurementContentItem(
        from annotation: ViewerROIAnnotation,
        options: ViewerROIDicomRoundTripOptions
    ) -> DicomSRContentItem? {
        guard let measurement = annotation.measurement else { return nil }
        return DicomSRContentItem(
            relationshipType: "CONTAINS",
            valueType: "NUM",
            conceptName: concept(for: annotation),
            numericValue: measurement.primaryValue,
            measurementUnits: units(for: measurement),
            trackingID: annotation.id.uuidString,
            children: graphicRegionContentItems(from: annotation, options: options)
        )
    }

    static func graphicRegionContentItems(
        from annotation: ViewerROIAnnotation,
        options: ViewerROIDicomRoundTripOptions
    ) -> [DicomSRContentItem] {
        guard annotation.kind != .text else { return [] }
        let graphicData = pixelGraphicData(from: annotation,
                                           imageWidth: options.imageWidth,
                                           imageHeight: options.imageHeight)
        guard !graphicData.isEmpty else { return [] }
        let sourceItems = sourceImageReferences(for: annotation, options: options).map {
            DicomSRContentItem(
                relationshipType: "SELECTED FROM",
                valueType: "IMAGE",
                conceptName: sourceImageConcept,
                referencedSOPs: [$0]
            )
        }
        return [
            DicomSRContentItem(
                relationshipType: "INFERRED FROM",
                valueType: "SCOORD",
                conceptName: imageRegionConcept,
                graphicType: graphicType(for: annotation.kind),
                graphicData: graphicData,
                children: sourceItems
            )
        ]
    }

    static func presentationAnnotation(
        from annotation: ViewerROIAnnotation,
        options: ViewerROIDicomRoundTripOptions
    ) -> DicomPresentationGraphicAnnotation? {
        let graphicObject = presentationGraphicObject(from: annotation, options: options)
        let textObject = presentationTextObject(from: annotation, options: options)
        guard graphicObject != nil || textObject != nil else { return nil }
        return DicomPresentationGraphicAnnotation(
            graphicLayer: options.graphicLayerName,
            referencedImages: sourceImageReferences(for: annotation, options: options).map(presentationReferencedImage),
            graphicObjects: graphicObject.map { [$0] } ?? [],
            textObjects: textObject.map { [$0] } ?? []
        )
    }

    static func presentationGraphicObject(
        from annotation: ViewerROIAnnotation,
        options: ViewerROIDicomRoundTripOptions
    ) -> DicomPresentationGraphicObject? {
        guard annotation.kind != .text else { return nil }
        let graphicData = pixelGraphicData(from: annotation,
                                           imageWidth: options.imageWidth,
                                           imageHeight: options.imageHeight)
        guard !graphicData.isEmpty else { return nil }
        return DicomPresentationGraphicObject(
            graphicType: graphicType(for: annotation.kind),
            graphicData: graphicData,
            graphicFilled: isFilled(annotation.kind),
            trackingID: annotation.id.uuidString
        )
    }

    static func presentationTextObject(
        from annotation: ViewerROIAnnotation,
        options: ViewerROIDicomRoundTripOptions
    ) -> DicomPresentationTextObject? {
        guard annotation.kind == .text || annotation.text != nil,
              let anchor = annotation.normalizedImagePoints.first else {
            return nil
        }
        return DicomPresentationTextObject(
            text: annotation.text ?? "Annotation",
            anchorPoint: pixelPoint(from: anchor,
                                    imageWidth: options.imageWidth,
                                    imageHeight: options.imageHeight)
        )
    }

    static func presentationReferencedSeries(
        from annotations: [ViewerROIAnnotation],
        options: ViewerROIDicomRoundTripOptions
    ) -> [DicomPresentationReferencedSeries] {
        guard let seriesUID = options.sourceSeriesInstanceUID else { return [] }
        let images = unique(annotations.flatMap { sourceImageReferences(for: $0, options: options) })
            .map(presentationReferencedImage)
        return images.isEmpty ? [] : [DicomPresentationReferencedSeries(seriesInstanceUID: seriesUID, images: images)]
    }

    static func presentationReferencedImage(
        from source: DicomSourceImageReference
    ) -> DicomPresentationReferencedImage {
        DicomPresentationReferencedImage(
            referencedSOPClassUID: source.referencedSOPClassUID,
            referencedSOPInstanceUID: source.referencedSOPInstanceUID,
            referencedFrameNumbers: source.referencedFrameNumbers
        )
    }

    static func sourceImageReferences(
        for annotation: ViewerROIAnnotation,
        options: ViewerROIDicomRoundTripOptions
    ) -> [DicomSourceImageReference] {
        if let slice = annotation.sliceIndex,
           let references = options.sourceImageReferencesBySlice[slice] {
            return references
        }
        return defaultSourceImageReferences(
            frameNumbers: annotation.sliceIndex.map { [max($0 + 1, 1)] } ?? [],
            options: options
        )
    }

    static func sourceImageReferences(
        forSlice slice: Int,
        options: ViewerROIDicomRoundTripOptions
    ) -> [DicomSourceImageReference] {
        if let references = options.sourceImageReferencesBySlice[slice] {
            return references
        }
        return defaultSourceImageReferences(frameNumbers: [max(slice + 1, 1)], options: options)
    }

    static func defaultSourceImageReferences(
        frameNumbers: [Int],
        options: ViewerROIDicomRoundTripOptions
    ) -> [DicomSourceImageReference] {
        guard options.sourceSOPClassUID != nil ||
              options.sourceSOPInstanceUID != nil else {
            return []
        }
        return [
            DicomSourceImageReference(
                referencedSOPClassUID: options.sourceSOPClassUID,
                referencedSOPInstanceUID: options.sourceSOPInstanceUID,
                referencedFrameNumbers: frameNumbers
            )
        ]
    }

    static func pixelGraphicData(
        from annotation: ViewerROIAnnotation,
        imageWidth: Int,
        imageHeight: Int
    ) -> [Double] {
        var points = annotation.normalizedImagePoints
        if isClosed(annotation.kind),
           let first = points.first,
           let last = points.last,
           first != last {
            points.append(first)
        }
        return points.flatMap {
            let pixel = pixelPoint(from: $0, imageWidth: imageWidth, imageHeight: imageHeight)
            return [pixel.x, pixel.y]
        }
    }

    static func pixelPoint(
        from point: CGPoint,
        imageWidth: Int,
        imageHeight: Int
    ) -> SIMD2<Double> {
        SIMD2<Double>(
            pixelCoordinate(point.x, extent: imageWidth),
            pixelCoordinate(point.y, extent: imageHeight)
        )
    }

    static func pixelCoordinate(_ value: CGFloat, extent: Int) -> Double {
        Double(clamp01(Double(value))) * Double(max(extent - 1, 0)) + 1
    }

    static func normalizedPoints(
        from graphicData: [Double],
        imageWidth: Int,
        imageHeight: Int
    ) -> [CGPoint] {
        guard graphicData.count >= 2 else { return [] }
        return stride(from: 0, to: graphicData.count - 1, by: 2).map {
            CGPoint(
                x: normalizedCoordinate(graphicData[$0], extent: imageWidth),
                y: normalizedCoordinate(graphicData[$0 + 1], extent: imageHeight)
            )
        }
    }

    static func normalizedCoordinate(_ value: Double, extent: Int) -> CGFloat {
        guard extent > 1 else { return 0 }
        return CGFloat(clamp01((value.rounded() - 1) / Double(extent - 1)))
    }

    static func graphicType(for kind: ViewerROIKind) -> String {
        switch kind {
        case .point:
            return "POINT"
        case .ellipse:
            return "ELLIPSE"
        case .distance, .angle, .cobbAngle, .area, .closedPath,
             .curvedLine, .text, .arrow, .scribble, .volume, .ctr:
            return "POLYLINE"
        }
    }

    static func isFilled(_ kind: ViewerROIKind) -> Bool? {
        switch kind {
        case .area, .ellipse, .closedPath, .volume:
            return true
        case .distance, .angle, .cobbAngle, .point, .curvedLine,
             .text, .arrow, .scribble, .ctr:
            return false
        }
    }

    static func isClosed(_ kind: ViewerROIKind) -> Bool {
        switch kind {
        case .area, .closedPath, .volume:
            return true
        case .distance, .angle, .cobbAngle, .point, .ellipse,
             .curvedLine, .text, .arrow, .scribble, .ctr:
            return false
        }
    }

    static func concept(for annotation: ViewerROIAnnotation) -> DicomCodedConcept {
        switch annotation.kind {
        case .distance:
            return roiConcept("ROI_DISTANCE", "Distance")
        case .angle:
            return roiConcept("ROI_ANGLE", "Angle")
        case .cobbAngle:
            return roiConcept("ROI_COBB_ANGLE", "Cobb angle")
        case .point:
            return roiConcept("ROI_POINT", "Point")
        case .area:
            return roiConcept("ROI_AREA", "Area")
        case .ellipse:
            return roiConcept("ROI_ELLIPSE", "Ellipse")
        case .closedPath:
            return roiConcept("ROI_POLYGON", "Polygon")
        case .curvedLine:
            return roiConcept("ROI_LENGTH", "Curved line length")
        case .text:
            return roiConcept("ROI_TEXT", "Text")
        case .arrow:
            return roiConcept("ROI_ARROW", "Arrow")
        case .scribble:
            return roiConcept("ROI_FREEHAND", "Freehand length")
        case .volume:
            return roiConcept("ROI_VOLUME", "Volume")
        case .ctr:
            return roiConcept("ROI_RATIO", "Ratio")
        }
    }

    static func roiConcept(_ value: String, _ meaning: String) -> DicomCodedConcept {
        DicomCodedConcept(codeValue: value, codingSchemeDesignator: codingScheme, codeMeaning: meaning)
    }

    static func units(for measurement: ViewerROIMeasurement) -> DicomCodedConcept {
        switch measurement {
        case .distanceMillimeters, .lengthMillimeters:
            return DicomCodedConcept(codeValue: "mm", codingSchemeDesignator: "UCUM", codeMeaning: "millimeter")
        case .distancePixels, .lengthPixels:
            return DicomCodedConcept(codeValue: "{pixel}", codingSchemeDesignator: "UCUM", codeMeaning: "pixel")
        case .angleDegrees:
            return DicomCodedConcept(codeValue: "deg", codingSchemeDesignator: "UCUM", codeMeaning: "degree")
        case .areaSquareMillimeters:
            return DicomCodedConcept(codeValue: "mm2", codingSchemeDesignator: "UCUM", codeMeaning: "square millimeter")
        case .areaPixels:
            return DicomCodedConcept(codeValue: "{pixel2}", codingSchemeDesignator: "UCUM", codeMeaning: "square pixel")
        case .volumeCubicMillimeters:
            return DicomCodedConcept(codeValue: "mm3", codingSchemeDesignator: "UCUM", codeMeaning: "cubic millimeter")
        case .ratio:
            return DicomCodedConcept(codeValue: "1", codingSchemeDesignator: "UCUM", codeMeaning: "ratio")
        }
    }

    static func roiKind(from measurement: DicomSRMeasurement, graphicType: String) -> ViewerROIKind {
        if measurement.name?.codingSchemeDesignator == codingScheme {
            switch measurement.name?.codeValue {
            case "ROI_DISTANCE":
                return .distance
            case "ROI_ANGLE":
                return .angle
            case "ROI_COBB_ANGLE":
                return .cobbAngle
            case "ROI_POINT":
                return .point
            case "ROI_AREA":
                return .area
            case "ROI_ELLIPSE":
                return .ellipse
            case "ROI_POLYGON":
                return .closedPath
            case "ROI_LENGTH":
                return .curvedLine
            case "ROI_TEXT":
                return .text
            case "ROI_ARROW":
                return .arrow
            case "ROI_FREEHAND":
                return .scribble
            case "ROI_VOLUME":
                return .volume
            case "ROI_RATIO":
                return .ctr
            default:
                break
            }
        }
        if graphicType.uppercased() == "POINT" {
            return .point
        }
        if measurement.units?.codeValue == "deg" {
            return .angle
        }
        if measurement.units?.codeValue == "mm2" || measurement.units?.codeValue == "{pixel2}" {
            return .area
        }
        if measurement.units?.codeValue == "mm3" {
            return .volume
        }
        return .distance
    }

    static func viewerMeasurement(from measurement: DicomSRMeasurement) -> ViewerROIMeasurement? {
        switch measurement.units?.codeValue {
        case "mm":
            if measurement.name?.codeValue == "ROI_LENGTH" || measurement.name?.codeValue == "ROI_FREEHAND" {
                return .lengthMillimeters(measurement.value)
            }
            return .distanceMillimeters(measurement.value)
        case "{pixel}":
            if measurement.name?.codeValue == "ROI_LENGTH" || measurement.name?.codeValue == "ROI_FREEHAND" {
                return .lengthPixels(measurement.value)
            }
            return .distancePixels(measurement.value)
        case "deg":
            return .angleDegrees(measurement.value)
        case "mm2":
            return .areaSquareMillimeters(measurement.value)
        case "{pixel2}":
            return .areaPixels(measurement.value)
        case "mm3":
            return .volumeCubicMillimeters(measurement.value)
        case "1":
            return .ratio(measurement.value)
        default:
            return nil
        }
    }

    static func labelmapValues(from dataset: VolumeDataset) throws -> [UInt16] {
        let expectedBytes = dataset.dimensions.voxelCount * MemoryLayout<UInt16>.size
        guard dataset.pixelFormat == .int16Unsigned,
              dataset.data.count >= expectedBytes else {
            throw ViewerROIDicomRoundTripError.invalidLabelmapData(
                expectedBytes: expectedBytes,
                actualBytes: dataset.data.count
            )
        }
        let bytes = [UInt8](dataset.data)
        return (0..<dataset.dimensions.voxelCount).map { index in
            let offset = index * 2
            return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
    }

    static func labelsWithVoxels(
        in values: [UInt16],
        labelmap: LabelmapVolume,
        selectedLabels: Set<UInt16>?
    ) -> [UInt16] {
        let presentLabels = Set(values.filter { $0 > 0 })
        return labelmap.segments
            .map(\.label)
            .filter { label in
                label > 0 &&
                    presentLabels.contains(label) &&
                    (selectedLabels?.contains(label) ?? true)
            }
            .sorted()
    }

    static func segment(label: UInt16, labelmap: LabelmapVolume) -> DicomSegment {
        let source = labelmap.segments.first { $0.label == label }
        return DicomSegment(
            number: Int(label),
            label: source?.name ?? "ROI \(label)",
            algorithmType: "MANUAL",
            trackingID: "roi-label-\(label)"
        )
    }

    static func frameGeometry(
        forSlice slice: Int,
        frameIndex: Int,
        dataset: VolumeDataset,
        sourceImageReferences: [DicomSourceImageReference]
    ) -> DicomFrameGeometry? {
        let imageData = dataset.imageData
        let origin = imageData.indexToWorld.transformPoint(SIMD3<Float>(0, 0, Float(slice)))
        return DicomFrameGeometry(frameIndex: frameIndex, functionalGroups: DicomFrameFunctionalGroups(
            frameContent: DicomFrameContent(
                dimensionIndexValues: [slice + 1],
                stackID: "ROI",
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
                imagePositionPatient: SIMD3<Double>(
                    Double(origin.x),
                    Double(origin.y),
                    Double(origin.z)
                )
            ),
            planeOrientation: DicomPlaneOrientation(
                row: SIMD3<Double>(
                    Double(imageData.rowDirection.x),
                    Double(imageData.rowDirection.y),
                    Double(imageData.rowDirection.z)
                ),
                column: SIMD3<Double>(
                    Double(imageData.columnDirection.x),
                    Double(imageData.columnDirection.y),
                    Double(imageData.columnDirection.z)
                )
            ),
            derivationImage: sourceImageReferences.isEmpty ? nil : DicomDerivationImage(sourceImages: sourceImageReferences)
        ))
    }

    static func grayscaleValue(for style: ViewerROIStyle) -> UInt {
        let color = style.strokeColor
        let luminance = clamp01(color.red * 0.299 + color.green * 0.587 + color.blue * 0.114)
        return UInt((luminance * 65_535).rounded())
    }

    static func studyInstanceUID(
        options: ViewerROIDicomRoundTripOptions,
        metadata: ClinicalImageMetadata? = nil
    ) -> String {
        options.studyInstanceUID ?? metadata?.studyInstanceUID ?? DicomDataSetWriter.makeUID()
    }

    static func outputSeriesInstanceUID(options: ViewerROIDicomRoundTripOptions) -> String {
        options.outputSeriesInstanceUID ?? DicomDataSetWriter.makeUID()
    }

    static func unique<T: Equatable>(_ values: [T]) -> [T] {
        var result: [T] = []
        for value in values where !result.contains(value) {
            result.append(value)
        }
        return result
    }

    static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
