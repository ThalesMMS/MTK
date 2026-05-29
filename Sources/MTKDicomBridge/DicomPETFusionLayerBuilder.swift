import DicomCore
import Foundation
import MTKCore

public enum DicomPETFusionLayerBridgeError: Error, Equatable, LocalizedError {
    case unsupportedModality(String?)
    case emptyPETVolume
    case invalidPixelData(expectedBytes: Int, actualBytes: Int)
    case frameOfReferenceMismatch(base: String, pet: String)
    case missingSUVMetadata(DicomSUVType, diagnostics: [DicomQuantitativeDiagnostic])
    case nonFiniteSUVValue(index: Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedModality(let modality):
            return "PET fusion requires PT modality; got \(modality ?? "<missing>")."
        case .emptyPETVolume:
            return "PET fusion volume contains no voxels."
        case let .invalidPixelData(expectedBytes, actualBytes):
            return "PET fusion volume has \(actualBytes) pixel bytes; expected \(expectedBytes)."
        case let .frameOfReferenceMismatch(base, pet):
            return "PET FrameOfReferenceUID \(pet) does not match base volume \(base)."
        case let .missingSUVMetadata(type, diagnostics):
            let detail = diagnostics.map(\.message).joined(separator: " ")
            return "PET SUV \(type.rawValue) values are unavailable from DICOM metadata.\(detail.isEmpty ? "" : " \(detail)")"
        case let .nonFiniteSUVValue(index):
            return "PET SUV value at voxel \(index) is not finite."
        }
    }
}

public struct DicomPETFusionLayerOptions: Equatable, Sendable {
    public var layerID: String?
    public var opacity: Float
    public var isVisible: Bool
    public var blendMode: VolumeLayerBlendMode
    public var transferFunction: VolumeTransferFunction?
    public var suvType: DicomSUVType
    public var seriesDescription: String?
    public var legendTitle: String?

    public init(layerID: String? = nil,
                opacity: Float = 0.5,
                isVisible: Bool = true,
                blendMode: VolumeLayerBlendMode = .additive,
                transferFunction: VolumeTransferFunction? = nil,
                suvType: DicomSUVType = .bw,
                seriesDescription: String? = nil,
                legendTitle: String? = "SUV") {
        self.layerID = layerID
        self.opacity = opacity
        self.isVisible = isVisible
        self.blendMode = blendMode
        self.transferFunction = transferFunction
        self.suvType = suvType
        self.seriesDescription = seriesDescription
        self.legendTitle = legendTitle
    }
}

public enum DicomPETFusionLayerBuilder {
    public static func makeVolumeLayer(
        from petImport: DicomVolumeDatasetImportResult,
        alignedTo baseDataset: VolumeDataset,
        options: DicomPETFusionLayerOptions = DicomPETFusionLayerOptions()
    ) throws -> VolumeLayer {
        try makeVolumeLayer(petDataset: petImport.dataset,
                            quantitativeValueProfile: petImport.quantitativeValueProfile,
                            fallbackID: petImport.sourceURL.lastPathComponent,
                            alignedTo: baseDataset,
                            options: options)
    }

    public static func makeVolumeLayer(
        from petSeries: DicomDecodedSeries,
        alignedTo baseDataset: VolumeDataset,
        options: DicomPETFusionLayerOptions = DicomPETFusionLayerOptions()
    ) throws -> VolumeLayer {
        let dataset = DicomVolumeDatasetImporter.makeDataset(from: petSeries)
        return try makeVolumeLayer(petDataset: dataset,
                                   quantitativeValueProfile: petSeries.quantitativeValueProfile,
                                   fallbackID: petSeries.seriesInstanceUID ?? petSeries.sourceURL.lastPathComponent,
                                   alignedTo: baseDataset,
                                   options: options)
    }

    public static func makeVolumeLayer(
        petDataset: VolumeDataset,
        quantitativeValueProfile: DicomQuantitativeValueProfile,
        fallbackID: String? = nil,
        alignedTo baseDataset: VolumeDataset,
        options: DicomPETFusionLayerOptions = DicomPETFusionLayerOptions()
    ) throws -> VolumeLayer {
        try validateModality(petDataset.imageData.clinicalMetadata?.modality)
        try validateFrameOfReference(petDataset.imageData.clinicalMetadata?.frameOfReferenceUID,
                                     baseFrameOfReferenceUID: baseDataset.imageData.clinicalMetadata?.frameOfReferenceUID)

        let expectedCount = petDataset.dimensions.voxelCount
        guard expectedCount > 0 else {
            throw DicomPETFusionLayerBridgeError.emptyPETVolume
        }
        let expectedBytes = expectedCount * petDataset.pixelFormat.bytesPerVoxel
        guard petDataset.data.count == expectedBytes else {
            throw DicomPETFusionLayerBridgeError.invalidPixelData(expectedBytes: expectedBytes,
                                                                 actualBytes: petDataset.data.count)
        }

        let suvValues = try makeSUVValues(from: petDataset,
                                          profile: quantitativeValueProfile,
                                          suvType: options.suvType)
        let physicalRange = valueRange(for: suvValues)
        let mapping = QuantitativeScalarMapping(
            units: codedConcept(options.suvType.unitConcept),
            physicalRange: physicalRange,
            storedValueRange: petDataset.intensityRange,
            physicalValues: suvValues,
            legendTitle: options.legendTitle
        )
        let scalarVolume = ScalarVolumeLayer(
            dataset: petDataset.settingSeriesDescription(options.seriesDescription),
            transferFunction: options.transferFunction ?? defaultTransferFunction(for: petDataset.intensityRange),
            quantitativeMapping: mapping
        )
        return VolumeLayer(id: options.layerID ??
                               nonEmpty(petDataset.imageData.clinicalMetadata?.seriesInstanceUID) ??
                               nonEmpty(fallbackID) ??
                               "dicom-pet-fusion",
                           scalarVolume: scalarVolume,
                           opacity: options.opacity,
                           blendMode: options.blendMode,
                           isVisible: options.isVisible)
    }

    private static func validateModality(_ modality: String?) throws {
        guard let modality = nonEmpty(modality) else { return }
        guard modality.uppercased() == "PT" else {
            throw DicomPETFusionLayerBridgeError.unsupportedModality(modality)
        }
    }

    private static func validateFrameOfReference(_ petFrameOfReferenceUID: String?,
                                                 baseFrameOfReferenceUID: String?) throws {
        guard let pet = nonEmpty(petFrameOfReferenceUID),
              let base = nonEmpty(baseFrameOfReferenceUID),
              pet != base else {
            return
        }
        throw DicomPETFusionLayerBridgeError.frameOfReferenceMismatch(base: base, pet: pet)
    }

    private static func makeSUVValues(from dataset: VolumeDataset,
                                      profile: DicomQuantitativeValueProfile,
                                      suvType: DicomSUVType) throws -> [Double] {
        guard let metadata = profile.suvMetadata else {
            throw DicomPETFusionLayerBridgeError.missingSUVMetadata(suvType, diagnostics: profile.diagnostics)
        }

        let modalityValues = storedValues(from: dataset).map(Double.init)
        var values: [Double] = []
        values.reserveCapacity(modalityValues.count)
        for (index, modalityValue) in modalityValues.enumerated() {
            guard let value = metadata.suvValue(forActivityConcentrationBqPerMl: modalityValue,
                                                type: suvType) else {
                throw DicomPETFusionLayerBridgeError.missingSUVMetadata(suvType,
                                                                        diagnostics: metadata.diagnostics(for: suvType))
            }
            guard value.isFinite else {
                throw DicomPETFusionLayerBridgeError.nonFiniteSUVValue(index: index)
            }
            values.append(value)
        }
        return values
    }

    private static func storedValues(from dataset: VolumeDataset) -> [Int32] {
        dataset.data.withUnsafeBytes { rawBuffer in
            switch dataset.pixelFormat {
            case .int16Signed:
                return rawBuffer.bindMemory(to: Int16.self).map(Int32.init)
            case .int16Unsigned:
                return rawBuffer.bindMemory(to: UInt16.self).map(Int32.init)
            }
        }
    }

    private static func valueRange(for values: [Double]) -> ClosedRange<Double> {
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? minimum
        return minimum...max(maximum, minimum)
    }

    private static func defaultTransferFunction(for storedRange: ClosedRange<Int32>) -> VolumeTransferFunction {
        let lower = Float(storedRange.lowerBound)
        let upper = Float(storedRange.upperBound)
        guard upper > lower else {
            return VolumeTransferFunction(
                opacityPoints: [
                    VolumeTransferFunction.OpacityControlPoint(intensity: lower, opacity: 1)
                ],
                colourPoints: [
                    VolumeTransferFunction.ColourControlPoint(intensity: lower,
                                                              colour: SIMD4<Float>(1, 0.72, 0.08, 1))
                ]
            )
        }
        let middle = lower + (upper - lower) * 0.5
        return VolumeTransferFunction(
            opacityPoints: [
                VolumeTransferFunction.OpacityControlPoint(intensity: lower, opacity: 0),
                VolumeTransferFunction.OpacityControlPoint(intensity: middle, opacity: 0.45),
                VolumeTransferFunction.OpacityControlPoint(intensity: upper, opacity: 1)
            ],
            colourPoints: [
                VolumeTransferFunction.ColourControlPoint(intensity: lower,
                                                          colour: SIMD4<Float>(0, 0, 0, 0)),
                VolumeTransferFunction.ColourControlPoint(intensity: middle,
                                                          colour: SIMD4<Float>(1, 0.75, 0.08, 1)),
                VolumeTransferFunction.ColourControlPoint(intensity: upper,
                                                          colour: SIMD4<Float>(1, 0.05, 0, 1))
            ]
        )
    }

    private static func codedConcept(_ concept: DicomCodedConcept) -> QuantitativeCodedConcept {
        QuantitativeCodedConcept(codeValue: concept.codeValue,
                                 codingSchemeDesignator: concept.codingSchemeDesignator,
                                 codeMeaning: concept.codeMeaning)
    }

    fileprivate static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension VolumeDataset {
    func settingSeriesDescription(_ seriesDescription: String?) -> VolumeDataset {
        guard let seriesDescription = DicomPETFusionLayerBuilder.nonEmpty(seriesDescription),
              let metadata = imageData.clinicalMetadata else {
            return self
        }
        var imageData = imageData
        imageData.clinicalMetadata = ClinicalImageMetadata(
            patientName: metadata.patientName,
            modality: metadata.modality,
            studyDescription: metadata.studyDescription,
            seriesDescription: seriesDescription,
            studyInstanceUID: metadata.studyInstanceUID,
            seriesInstanceUID: metadata.seriesInstanceUID,
            frameOfReferenceUID: metadata.frameOfReferenceUID,
            rescaleSlope: metadata.rescaleSlope,
            rescaleIntercept: metadata.rescaleIntercept,
            sourcePixelFormat: metadata.sourcePixelFormat,
            windowCenter: metadata.windowCenter,
            windowWidth: metadata.windowWidth
        )
        return VolumeDataset(data: data, imageData: imageData)
    }
}
