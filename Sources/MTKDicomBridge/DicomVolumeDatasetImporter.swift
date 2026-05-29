import DicomCore
import Foundation
import MTKCore
import MTKUI
import simd

public struct DicomVolumeDatasetImportWarning: Sendable, Hashable {
    public enum Code: String, Sendable, Hashable {
        case usedFallbackWindow
    }

    public let code: Code
    public let message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }
}

public enum DicomVolumeDatasetImportProgress: Sendable, Equatable {
    case started(totalSlices: Int)
    case reading(fraction: Double, slicesLoaded: Int)
}

public struct DicomVolumeDatasetImportResult {
    public let dataset: VolumeDataset
    public let sourceURL: URL
    public let seriesDescription: String
    public let quantitativeValueProfile: DicomQuantitativeValueProfile
    public let keyImageNavigationState: KeyImageNavigationState
    public let warnings: [DicomVolumeDatasetImportWarning]

    public init(dataset: VolumeDataset,
                sourceURL: URL,
                seriesDescription: String,
                quantitativeValueProfile: DicomQuantitativeValueProfile = .empty,
                keyImageNavigationState: KeyImageNavigationState = KeyImageNavigationState(),
                warnings: [DicomVolumeDatasetImportWarning] = []) {
        self.dataset = dataset
        self.sourceURL = sourceURL
        self.seriesDescription = seriesDescription
        self.quantitativeValueProfile = quantitativeValueProfile
        self.keyImageNavigationState = keyImageNavigationState
        self.warnings = warnings
    }
}

public protocol VolumeDatasetImporting: AnyObject {
    func loadDataset(from url: URL,
                     progress: @escaping (DicomVolumeDatasetImportProgress) -> Void,
                     completion: @escaping (Result<DicomVolumeDatasetImportResult, Error>) -> Void)
}

public final class DicomVolumeDatasetImporter: VolumeDatasetImporting {
    private let loader: DicomSeriesLoader
    private let callbackQueue: DispatchQueue

    public convenience init(callbackQueue: DispatchQueue = .main) {
        self.init(loader: DicomSeriesLoader(), callbackQueue: callbackQueue)
    }

    init(loader: DicomSeriesLoader,
         callbackQueue: DispatchQueue = .main) {
        self.loader = loader
        self.callbackQueue = callbackQueue
    }

    public func loadDataset(from url: URL,
                            progress: @escaping (DicomVolumeDatasetImportProgress) -> Void,
                            completion: @escaping (Result<DicomVolumeDatasetImportResult, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let decoded = try self.loader.loadDecodedSeries(from: url) { update in
                    self.callbackQueue.async {
                        progress(Self.makeProgress(from: update))
                    }
                }
                let result = DicomVolumeDatasetImportResult(
                    dataset: Self.makeDataset(from: decoded),
                    sourceURL: decoded.sourceURL,
                    seriesDescription: decoded.seriesDescription,
                    quantitativeValueProfile: decoded.quantitativeValueProfile,
                    keyImageNavigationState: DicomKeyObjectSelectionNavigationBridge.makeState(
                        from: decoded.keyObjectSelectionDocuments,
                        loadedInstances: DicomKeyObjectSelectionNavigationBridge.makeLoadedInstances(
                            from: decoded.imageInstances
                        )
                    ),
                    warnings: decoded.warnings.map(Self.makeWarning(from:))
                )
                self.callbackQueue.async {
                    completion(.success(result))
                }
            } catch {
                self.callbackQueue.async {
                    completion(.failure(error))
                }
            }
        }
    }

    private static func makeProgress(from progress: DicomDecodedSeriesProgress) -> DicomVolumeDatasetImportProgress {
        switch progress {
        case .started(let totalSlices):
            return .started(totalSlices: totalSlices)
        case .reading(let fraction, let slicesLoaded):
            return .reading(fraction: fraction, slicesLoaded: slicesLoaded)
        }
    }

    private static func makeWarning(from warning: DicomDecodedSeriesWarning) -> DicomVolumeDatasetImportWarning {
        let code: DicomVolumeDatasetImportWarning.Code
        switch warning.code {
        case .usedFallbackWindow:
            code = .usedFallbackWindow
        }
        return DicomVolumeDatasetImportWarning(code: code, message: warning.message)
    }

    public static func makeDataset(from decoded: DicomDecodedSeries) -> VolumeDataset {
        makeDataset(
            data: decoded.modalityVoxels,
            dimensions: VolumeDimensions(
                width: decoded.dimensions.width,
                height: decoded.dimensions.height,
                depth: decoded.dimensions.depth
            ),
            spacing: VolumeSpacing(
                x: decoded.spacing.x,
                y: decoded.spacing.y,
                z: decoded.spacing.z
            ),
            orientation: decoded.orientation,
            origin: decoded.origin,
            intensityRange: decoded.modalityIntensityRange,
            recommendedWindow: decoded.recommendedWindow,
            clinicalMetadata: ClinicalImageMetadata(
                patientName: nonEmpty(decoded.patientName),
                modality: nonEmpty(decoded.modality),
                studyDescription: nonEmpty(decoded.studyDescription),
                seriesDescription: nonEmpty(decoded.seriesDescription),
                studyInstanceUID: decoded.studyInstanceUID,
                seriesInstanceUID: decoded.seriesInstanceUID,
                frameOfReferenceUID: decoded.frameOfReferenceUID,
                rescaleSlope: decoded.rescaleSlope,
                rescaleIntercept: decoded.rescaleIntercept,
                sourcePixelFormat: decoded.sourcePixelRepresentation.isSigned ? .int16Signed : .int16Unsigned,
                windowCenter: decoded.windowCenter,
                windowWidth: decoded.windowWidth
            )
        )
    }

    public static func makeDataset(from volume: DicomSeriesVolume) throws -> VolumeDataset {
        let conversion = try makeModalityVoxels(
            rawVoxels: volume.voxels,
            voxelCount: volume.width * volume.height * volume.depth,
            isSigned: volume.isSignedPixel,
            slope: volume.rescaleSlope,
            intercept: volume.rescaleIntercept
        )

        return makeDataset(
            data: conversion.data,
            dimensions: VolumeDimensions(width: volume.width, height: volume.height, depth: volume.depth),
            spacing: VolumeSpacing(x: volume.spacing.x, y: volume.spacing.y, z: volume.spacing.z),
            orientation: volume.orientation,
            origin: volume.origin,
            intensityRange: conversion.range,
            recommendedWindow: recommendedWindow(center: volume.windowCenter, width: volume.windowWidth),
            clinicalMetadata: ClinicalImageMetadata(
                patientName: nonEmpty(volume.patientName),
                modality: nonEmpty(volume.modality),
                studyDescription: nonEmpty(volume.studyDescription),
                seriesDescription: nonEmpty(volume.seriesDescription),
                studyInstanceUID: volume.studyInstanceUID,
                seriesInstanceUID: volume.seriesInstanceUID,
                frameOfReferenceUID: volume.frameOfReferenceUID,
                rescaleSlope: volume.rescaleSlope,
                rescaleIntercept: volume.rescaleIntercept,
                sourcePixelFormat: volume.isSignedPixel ? .int16Signed : .int16Unsigned,
                windowCenter: volume.windowCenter,
                windowWidth: volume.windowWidth
            )
        )
    }

    private static func makeDataset(data: Data,
                                    dimensions: VolumeDimensions,
                                    spacing: VolumeSpacing,
                                    orientation: simd_double3x3,
                                    origin: SIMD3<Double>,
                                    intensityRange: ClosedRange<Int32>,
                                    recommendedWindow: ClosedRange<Int32>?,
                                    clinicalMetadata: ClinicalImageMetadata) -> VolumeDataset {
        let row = SIMD3<Float>(
            Float(orientation.columns.0.x),
            Float(orientation.columns.0.y),
            Float(orientation.columns.0.z)
        )
        let column = SIMD3<Float>(
            Float(orientation.columns.1.x),
            Float(orientation.columns.1.y),
            Float(orientation.columns.1.z)
        )
        let normal = SIMD3<Float>(
            Float(orientation.columns.2.x),
            Float(orientation.columns.2.y),
            Float(orientation.columns.2.z)
        )
        let imageOrigin = SIMD3<Float>(
            Float(origin.x),
            Float(origin.y),
            Float(origin.z)
        )

        let imageData = ImageData3D(
            dimensions: dimensions,
            spacing: spacing,
            origin: imageOrigin,
            direction: simd_float3x3(columns: (row, column, normal)),
            pixelFormat: .int16Signed,
            intensityRange: intensityRange,
            recommendedWindow: recommendedWindow,
            clinicalMetadata: clinicalMetadata
        )
        return VolumeDataset(data: data, imageData: imageData)
    }

    private static func makeModalityVoxels(rawVoxels: Data,
                                           voxelCount: Int,
                                           isSigned: Bool,
                                           slope: Double,
                                           intercept: Double) throws -> (data: Data, range: ClosedRange<Int32>) {
        let expectedBytes = voxelCount * MemoryLayout<Int16>.size
        guard rawVoxels.count == expectedBytes else {
            throw DICOMError.invalidPixelData(reason: "DICOM volume voxel buffer has \(rawVoxels.count) bytes; expected \(expectedBytes)")
        }

        var converted = Data(count: expectedBytes)
        var minimum = Int32.max
        var maximum = Int32.min

        rawVoxels.withUnsafeBytes { sourceBuffer in
            converted.withUnsafeMutableBytes { destinationBuffer in
                let destination = destinationBuffer.bindMemory(to: Int16.self)
                if isSigned {
                    let source = sourceBuffer.bindMemory(to: Int16.self)
                    for index in 0..<voxelCount {
                        let value = convertedModalityValue(raw: Double(source[index]), slope: slope, intercept: intercept)
                        minimum = min(minimum, value.int32)
                        maximum = max(maximum, value.int32)
                        destination[index] = value.int16
                    }
                } else {
                    let source = sourceBuffer.bindMemory(to: UInt16.self)
                    for index in 0..<voxelCount {
                        let value = convertedModalityValue(raw: Double(source[index]), slope: slope, intercept: intercept)
                        minimum = min(minimum, value.int32)
                        maximum = max(maximum, value.int32)
                        destination[index] = value.int16
                    }
                }
            }
        }

        if minimum > maximum {
            minimum = Int32(Int16.min)
            maximum = Int32(Int16.max)
        }
        return (converted, minimum...maximum)
    }

    private static func convertedModalityValue(raw: Double,
                                               slope: Double,
                                               intercept: Double) -> (int16: Int16, int32: Int32) {
        let rounded = lround(raw * slope + intercept)
        let clamped = max(Int(Int16.min), min(Int(Int16.max), rounded))
        return (Int16(clamped), Int32(clamped))
    }

    private static func recommendedWindow(center: Double?, width: Double?) -> ClosedRange<Int32>? {
        guard let center, let width else {
            return nil
        }
        let clampedWidth = max(width, 1)
        let halfSpan = (clampedWidth - 1) * 0.5
        let lower = center - 0.5 - halfSpan
        let upper = center - 0.5 + halfSpan
        return Int32(floor(lower))...Int32(ceil(upper))
    }
}

private func nonEmpty(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    return nonEmpty(value)
}
