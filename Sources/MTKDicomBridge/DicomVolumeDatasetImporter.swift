import DicomCore
import Foundation
import MTKCore
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
    public let warnings: [DicomVolumeDatasetImportWarning]

    public init(dataset: VolumeDataset,
                sourceURL: URL,
                seriesDescription: String,
                warnings: [DicomVolumeDatasetImportWarning] = []) {
        self.dataset = dataset
        self.sourceURL = sourceURL
        self.seriesDescription = seriesDescription
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
        let row = SIMD3<Float>(
            Float(decoded.orientation.columns.0.x),
            Float(decoded.orientation.columns.0.y),
            Float(decoded.orientation.columns.0.z)
        )
        let column = SIMD3<Float>(
            Float(decoded.orientation.columns.1.x),
            Float(decoded.orientation.columns.1.y),
            Float(decoded.orientation.columns.1.z)
        )
        let normal = SIMD3<Float>(
            Float(decoded.orientation.columns.2.x),
            Float(decoded.orientation.columns.2.y),
            Float(decoded.orientation.columns.2.z)
        )
        let origin = SIMD3<Float>(
            Float(decoded.origin.x),
            Float(decoded.origin.y),
            Float(decoded.origin.z)
        )

        let imageData = ImageData3D(
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
            origin: origin,
            direction: simd_float3x3(columns: (row, column, normal)),
            pixelFormat: .int16Signed,
            intensityRange: decoded.modalityIntensityRange,
            recommendedWindow: decoded.recommendedWindow,
            clinicalMetadata: ClinicalImageMetadata(
                modality: nonEmpty(decoded.modality),
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
        return VolumeDataset(data: decoded.modalityVoxels, imageData: imageData)
    }
}

private func nonEmpty(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
