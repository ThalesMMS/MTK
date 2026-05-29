import DicomCore
import Foundation
import MTKCore
import simd

public enum DicomParametricMapScalarLayerBridgeError: Error, Equatable, LocalizedError {
    case emptyParametricMap
    case invalidValueCount(expected: Int, actual: Int)
    case nonFiniteValue(index: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyParametricMap:
            return "DICOM Parametric Map contains no scalar samples."
        case let .invalidValueCount(expected, actual):
            return "DICOM Parametric Map contains \(actual) scalar samples; expected \(expected)."
        case let .nonFiniteValue(index):
            return "DICOM Parametric Map scalar sample \(index) is not finite."
        }
    }
}

public struct DicomParametricMapScalarLayerOptions: Equatable, Sendable {
    public var layerID: String?
    public var opacity: Float
    public var isVisible: Bool
    public var blendMode: VolumeLayerBlendMode
    public var transferFunction: VolumeTransferFunction?
    public var seriesDescription: String?
    public var legendTitle: String?

    public init(layerID: String? = nil,
                opacity: Float = 0.55,
                isVisible: Bool = true,
                blendMode: VolumeLayerBlendMode = .sourceOver,
                transferFunction: VolumeTransferFunction? = nil,
                seriesDescription: String? = "DICOM parametric map",
                legendTitle: String? = nil) {
        self.layerID = layerID
        self.opacity = opacity
        self.isVisible = isVisible
        self.blendMode = blendMode
        self.transferFunction = transferFunction
        self.seriesDescription = seriesDescription
        self.legendTitle = legendTitle
    }
}

public enum DicomParametricMapScalarLayerBuilder {
    public static func makeVolumeLayer(
        from parametricMap: DicomParametricMap,
        alignedTo baseDataset: VolumeDataset,
        options: DicomParametricMapScalarLayerOptions = DicomParametricMapScalarLayerOptions()
    ) throws -> VolumeLayer {
        let result = try makeDatasetAndMapping(from: parametricMap,
                                               alignedTo: baseDataset,
                                               options: options)
        let transferFunction = options.transferFunction ??
            defaultTransferFunction(for: result.dataset.intensityRange)
        let scalarVolume = ScalarVolumeLayer(dataset: result.dataset,
                                             transferFunction: transferFunction,
                                             quantitativeMapping: result.mapping)
        return VolumeLayer(id: options.layerID ?? parametricMap.sopInstanceUID ?? "dicom-parametric-map",
                           scalarVolume: scalarVolume,
                           opacity: options.opacity,
                           blendMode: options.blendMode,
                           isVisible: options.isVisible)
    }

    public static func makeDataset(
        from parametricMap: DicomParametricMap,
        alignedTo baseDataset: VolumeDataset,
        options: DicomParametricMapScalarLayerOptions = DicomParametricMapScalarLayerOptions()
    ) throws -> VolumeDataset {
        try makeDatasetAndMapping(from: parametricMap,
                                  alignedTo: baseDataset,
                                  options: options).dataset
    }

    private static func makeDatasetAndMapping(
        from parametricMap: DicomParametricMap,
        alignedTo baseDataset: VolumeDataset,
        options: DicomParametricMapScalarLayerOptions
    ) throws -> (dataset: VolumeDataset, mapping: QuantitativeScalarMapping) {
        let scalarVolume = parametricMap.scalarVolume
        let expectedCount = scalarVolume.rows * scalarVolume.columns * scalarVolume.frameCount
        guard expectedCount > 0 else {
            throw DicomParametricMapScalarLayerBridgeError.emptyParametricMap
        }
        let physicalValues = scalarVolume.physicalValues ?? scalarVolume.scalarValues
        guard physicalValues.count == expectedCount else {
            throw DicomParametricMapScalarLayerBridgeError.invalidValueCount(expected: expectedCount,
                                                                            actual: physicalValues.count)
        }
        for (index, value) in physicalValues.enumerated() where !value.isFinite {
            throw DicomParametricMapScalarLayerBridgeError.nonFiniteValue(index: index)
        }

        let physicalRange = valueRange(for: physicalValues)
        let voxels = quantizedVoxels(for: physicalValues,
                                     physicalRange: physicalRange)
        let storedRange = storedRange(for: voxels)
        let mapping = QuantitativeScalarMapping(
            units: codedConcept(scalarVolume.units),
            quantityDefinitions: scalarVolume.quantityDefinitions.map(quantityDefinition),
            physicalRange: physicalRange,
            storedValueRange: storedRange,
            physicalValues: physicalValues,
            legendTitle: options.legendTitle ??
                legendTitle(from: parametricMap.realWorldValueMaps)
        )
        let imageData = makeImageData(
            from: scalarVolume,
            alignedTo: baseDataset,
            storedRange: storedRange,
            physicalRange: physicalRange,
            seriesDescription: options.seriesDescription
        )
        return (VolumeDataset(data: littleEndianData(from: voxels),
                              imageData: imageData),
                mapping)
    }

    private static func makeImageData(from scalarVolume: DicomParametricMapScalarVolume,
                                      alignedTo baseDataset: VolumeDataset,
                                      storedRange: ClosedRange<Int32>,
                                      physicalRange: ClosedRange<Double>,
                                      seriesDescription: String?) -> ImageData3D {
        let dimensions = VolumeDimensions(width: scalarVolume.columns,
                                          height: scalarVolume.rows,
                                          depth: scalarVolume.frameCount)
        let spacing = spacing(from: scalarVolume.frameGeometry,
                              fallback: baseDataset.spacing)
        let direction = direction(from: scalarVolume.frameGeometry,
                                  fallback: baseDataset.imageData.direction)
        let origin = origin(from: scalarVolume.frameGeometry,
                            fallback: baseDataset.imageData.origin)
        let slope: Double?
        let intercept: Double?
        if storedRange.upperBound > storedRange.lowerBound {
            slope = (physicalRange.upperBound - physicalRange.lowerBound) /
                Double(storedRange.upperBound - storedRange.lowerBound)
            intercept = physicalRange.lowerBound - (slope ?? 0) * Double(storedRange.lowerBound)
        } else {
            slope = nil
            intercept = physicalRange.lowerBound
        }
        return ImageData3D(
            dimensions: dimensions,
            spacing: spacing,
            origin: origin,
            direction: direction,
            pixelFormat: .int16Unsigned,
            intensityRange: storedRange,
            recommendedWindow: storedRange,
            clinicalMetadata: ClinicalImageMetadata(
                modality: "PM",
                seriesDescription: seriesDescription,
                frameOfReferenceUID: baseDataset.imageData.clinicalMetadata?.frameOfReferenceUID,
                rescaleSlope: slope,
                rescaleIntercept: intercept,
                sourcePixelFormat: .int16Unsigned
            )
        )
    }

    private static func spacing(from geometry: [DicomFrameGeometry?],
                                fallback: VolumeSpacing) -> VolumeSpacing {
        let firstMeasures = geometry.compactMap { $0?.pixelMeasures }.first
        let x = firstMeasures?.pixelSpacing?.y ?? fallback.x
        let y = firstMeasures?.pixelSpacing?.x ?? fallback.y
        let positions = geometry.compactMap { $0?.positionAlongNormal }.sorted()
        let z: Double
        if positions.count >= 2 {
            z = max(abs(positions[1] - positions[0]), Double.ulpOfOne)
        } else {
            z = firstMeasures?.spacingBetweenSlices ??
                firstMeasures?.sliceThickness ??
                fallback.z
        }
        return VolumeSpacing(x: x, y: y, z: z)
    }

    private static func direction(from geometry: [DicomFrameGeometry?],
                                  fallback: simd_float3x3) -> simd_float3x3 {
        guard let orientation = geometry.compactMap({ $0?.imageOrientationPatient }).first else {
            return fallback
        }
        let row = SIMD3<Float>(Float(orientation.row.x),
                               Float(orientation.row.y),
                               Float(orientation.row.z))
        let column = SIMD3<Float>(Float(orientation.column.x),
                                  Float(orientation.column.y),
                                  Float(orientation.column.z))
        let slice = normalizedCross(row,
                                    column,
                                    fallback: fallback.columns.2)
        return simd_float3x3(columns: (row, column, slice))
    }

    private static func origin(from geometry: [DicomFrameGeometry?],
                               fallback: SIMD3<Float>) -> SIMD3<Float> {
        guard let position = geometry.compactMap({ $0?.imagePositionPatient }).first else {
            return fallback
        }
        return SIMD3<Float>(Float(position.x),
                            Float(position.y),
                            Float(position.z))
    }

    private static func valueRange(for values: [Double]) -> ClosedRange<Double> {
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? minimum
        return minimum...max(maximum, minimum)
    }

    private static func quantizedVoxels(for values: [Double],
                                        physicalRange: ClosedRange<Double>) -> [UInt16] {
        let lower = physicalRange.lowerBound
        let upper = physicalRange.upperBound
        guard upper > lower else {
            return [UInt16](repeating: 0, count: values.count)
        }
        return values.map { value in
            let t = min(max((value - lower) / (upper - lower), 0), 1)
            return UInt16(clamping: Int((t * Double(UInt16.max)).rounded()))
        }
    }

    private static func storedRange(for voxels: [UInt16]) -> ClosedRange<Int32> {
        let minimum = Int32(voxels.min() ?? 0)
        let maximum = Int32(voxels.max() ?? 0)
        return minimum...max(maximum, minimum)
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

    private static func defaultTransferFunction(for storedRange: ClosedRange<Int32>) -> VolumeTransferFunction {
        let lower = Float(storedRange.lowerBound)
        let upper = Float(storedRange.upperBound)
        if lower == upper {
            return VolumeTransferFunction(
                opacityPoints: [
                    VolumeTransferFunction.OpacityControlPoint(intensity: lower, opacity: 1)
                ],
                colourPoints: [
                    VolumeTransferFunction.ColourControlPoint(intensity: lower,
                                                              colour: SIMD4<Float>(1, 0.78, 0.1, 1))
                ]
            )
        }
        let middle = lower + (upper - lower) * 0.5
        return VolumeTransferFunction(
            opacityPoints: [
                VolumeTransferFunction.OpacityControlPoint(intensity: lower, opacity: 0),
                VolumeTransferFunction.OpacityControlPoint(intensity: upper, opacity: 1)
            ],
            colourPoints: [
                VolumeTransferFunction.ColourControlPoint(intensity: lower,
                                                          colour: SIMD4<Float>(0.05, 0.2, 1, 1)),
                VolumeTransferFunction.ColourControlPoint(intensity: middle,
                                                          colour: SIMD4<Float>(0.1, 0.85, 0.55, 1)),
                VolumeTransferFunction.ColourControlPoint(intensity: upper,
                                                          colour: SIMD4<Float>(1, 0.25, 0.08, 1))
            ]
        )
    }

    private static func codedConcept(_ concept: DicomCodedConcept?) -> QuantitativeCodedConcept? {
        guard let concept else { return nil }
        return QuantitativeCodedConcept(codeValue: concept.codeValue,
                                        codingSchemeDesignator: concept.codingSchemeDesignator,
                                        codeMeaning: concept.codeMeaning)
    }

    private static func quantityDefinition(_ definition: DicomQuantityDefinition) -> QuantitativeQuantityDefinition {
        let rationalValue: Double?
        if let numerator = definition.rationalNumeratorValue,
           let denominator = definition.rationalDenominatorValue,
           denominator > 0 {
            rationalValue = Double(numerator) / Double(denominator)
        } else {
            rationalValue = nil
        }
        return QuantitativeQuantityDefinition(
            conceptName: codedConcept(definition.conceptName),
            conceptCode: codedConcept(definition.conceptCode),
            numericValue: definition.numericValue ??
                definition.floatingPointValue ??
                rationalValue,
            textValue: definition.textValue
        )
    }

    private static func legendTitle(from maps: [DicomParametricMapRealWorldValueMap]) -> String? {
        for map in maps {
            if let label = nonEmpty(map.label) {
                return label
            }
            if let explanation = nonEmpty(map.explanation) {
                return explanation
            }
        }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedCross(_ lhs: SIMD3<Float>,
                                        _ rhs: SIMD3<Float>,
                                        fallback: SIMD3<Float>) -> SIMD3<Float> {
        let cross = simd_cross(lhs, rhs)
        let length = simd_length(cross)
        if length > Float.ulpOfOne {
            return cross / length
        }
        let fallbackLength = simd_length(fallback)
        if fallbackLength > Float.ulpOfOne {
            return fallback / fallbackLength
        }
        return SIMD3<Float>(0, 0, 1)
    }
}
