//
//  DicomVolumeTypes.swift
//  MTK
//
//  Public DICOM volume loading types.
//

import Foundation
import simd

/// Protocol abstraction for DICOM series volume metadata and pixel data.
///
/// Bridges DICOM-specific volume representations from DICOM-Decoder or injected test/integration loaders
/// into a unified interface consumed by ``DicomVolumeLoader``. Implementations provide spatial
/// metadata (dimensions, spacing, orientation), rescale parameters for Hounsfield Unit conversion,
/// and pixel format information.
///
/// ## Topics
///
/// ### Dimensions and Spacing
/// - ``width``
/// - ``height``
/// - ``depth``
/// - ``spacingX``
/// - ``spacingY``
/// - ``spacingZ``
///
/// ### Spatial Orientation
/// - ``orientation``
/// - ``origin``
///
/// ### Pixel Format and Rescale
/// - ``bitsAllocated``
/// - ``isSignedPixel``
/// - ``rescaleSlope``
/// - ``rescaleIntercept``
///
/// ### Metadata
/// - ``seriesDescription``
public protocol DICOMSeriesVolumeProtocol {
    /// Bits allocated per pixel sample (typically 8 or 16 for medical imaging).
    var bitsAllocated: Int { get }

    /// Width of each slice in pixels (DICOM Columns).
    var width: Int { get }

    /// Height of each slice in pixels (DICOM Rows).
    var height: Int { get }

    /// Number of slices in the series (volume depth).
    var depth: Int { get }

    /// Physical spacing between pixel centers along the row direction (millimeters).
    var spacingX: Double { get }

    /// Physical spacing between pixel centers along the column direction (millimeters).
    var spacingY: Double { get }

    /// Physical spacing between slice centers (millimeters).
    var spacingZ: Double { get }

    /// 3×3 orientation matrix mapping voxel indices to patient coordinate system.
    ///
    /// Columns correspond to row direction, column direction, and slice normal direction in patient space.
    /// Follows DICOM Image Orientation Patient (0020,0037) conventions.
    var orientation: simd_float3x3 { get }

    /// Origin position of the first voxel in patient coordinate system (millimeters).
    ///
    /// Corresponds to DICOM Image Position Patient (0020,0032).
    var origin: SIMD3<Float> { get }

    /// Rescale slope for converting stored pixel values to modality units (Hounsfield Units for CT).
    ///
    /// `HU = slope * pixelValue + intercept`
    var rescaleSlope: Double { get }

    /// Rescale intercept for converting stored pixel values to modality units.
    ///
    /// `HU = slope * pixelValue + intercept`
    var rescaleIntercept: Double { get }

    /// Whether pixel data is stored as signed integers (true) or unsigned integers (false).
    var isSignedPixel: Bool { get }

    /// Human-readable series description from DICOM metadata (0008,103E).
    var seriesDescription: String { get }
}

/// Protocol abstraction for DICOM series loading implementations.
///
/// ``DicomVolumeLoader`` uses ``DicomDecoderSeriesLoader`` by default. This protocol keeps the loader
/// injectable for unit tests and package-level adapters without implying demo runtime backend switching.
/// Implementations parse DICOM files in a directory, sort slices by Image Position Patient, and stream
/// slice data incrementally via progress callbacks.
///
/// ## Example Implementation
///
/// ```swift
/// final class CustomDicomLoader: DicomSeriesLoading {
///     func loadSeries(at url: URL,
///                     progress: ((Double, UInt, Data?, Any) -> Void)?) throws -> Any {
///         // Parse DICOM files in directory
///         let slices = try parseDicomDirectory(url)
///         var voxelBuffer = Data(count: totalVoxelCount * 2)
///
///         for (index, slice) in slices.enumerated() {
///             let sliceData = try slice.pixelData()
///             // Copy slice into voxelBuffer
///             let fraction = Double(index + 1) / Double(slices.count)
///             let volume = makePartialVolume(...)
///             progress?(fraction, UInt(index + 1), sliceData, volume)
///         }
///
///         return makeFinalVolume(...)
///     }
/// }
/// ```
///
/// ## Topics
///
/// ### Loading Series
/// - ``loadSeries(at:progress:)``
public protocol DicomSeriesLoading: AnyObject {
    /// Load a DICOM series from a directory, providing incremental progress updates.
    ///
    /// - Parameters:
    ///   - url: Directory containing DICOM files (*.dcm, or any recognized DICOM format)
    ///   - progress: Optional callback receiving (completion fraction, slices loaded, latest slice data, partial volume)
    ///
    /// - Returns: Final volume object conforming to ``DICOMSeriesVolumeProtocol``
    ///
    /// - Throws: Parser-specific errors for I/O failures, invalid DICOM data, or unsupported formats
    ///
    /// - Note: Progress callback receives the partial volume after each slice is loaded. The `Any` return type
    ///   allows implementations to return library-specific volume types that are then cast to ``DICOMSeriesVolumeProtocol``.
    func loadSeries(at url: URL,
                    progress: ((Double, UInt, Data?, Any) -> Void)?) throws -> Any
}

/// Errors that can occur during DICOM volume loading.
///
/// Covers validation failures, security checks, unsupported formats, and bridge-layer exceptions.
///
/// ## Topics
///
/// ### Error Cases
/// - ``securityScopeUnavailable``
/// - ``unsupportedBitDepth``
/// - ``missingResult``
/// - ``pathTraversal``
/// - ``bridgeError(_:)``
public enum DicomVolumeLoaderError: Error {
    private static let diagnosticLogger = Logger(subsystem: "com.mtk.dicom", category: "Loader")

    /// Unable to access the security-scoped resource (App Sandbox).
    ///
    /// Occurs when accessing files selected via `NSOpenPanel` or drag-and-drop without
    /// valid security-scoped bookmark data.
    case securityScopeUnavailable

    /// DICOM series uses unsupported pixel bit depth.
    ///
    /// Only 16-bit scalar volumes (signed or unsigned) are currently supported. 8-bit, 12-bit,
    /// or multi-component (RGB) volumes will trigger this error.
    case unsupportedBitDepth

    /// DICOM parser returned nil or empty volume data.
    ///
    /// Indicates the series loader completed without producing voxel data, possibly due to
    /// empty directory or all-invalid DICOM files.
    case missingResult

    /// ZIP archive contains malicious path traversal entries.
    ///
    /// Detected when archive entries contain ".." components or absolute paths attempting
    /// to escape extraction directory.
    case pathTraversal

    /// Error from underlying DICOM parsing library.
    ///
    /// Wraps errors from DICOM-Decoder or injected loaders. Original error preserved
    /// in associated `NSError` for debugging.
    case bridgeError(NSError)
}

extension DicomVolumeLoaderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .securityScopeUnavailable:
            return "Could not access the selected files."
        case .unsupportedBitDepth:
            return "Only 16-bit scalar DICOM series are supported at this time."
        case .missingResult:
            return "The DICOM series conversion returned no data."
        case .pathTraversal:
            return "The file contains invalid paths that attempt to access external directories."
        case .bridgeError(let nsError):
            Self.diagnosticLogger.debug(
                "DICOM bridge error domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)"
            )
            return "Failed to process the DICOM series."
        }
    }
}

/// Result of a successful DICOM import operation.
///
/// Encapsulates the loaded ``VolumeDataset`` along with source metadata for UI display and persistence.
/// Returned by ``DicomVolumeLoader/loadVolume(from:progress:completion:)`` after successful parsing
/// and Hounsfield Unit conversion.
///
/// ## Topics
///
/// ### Properties
/// - ``dataset``
/// - ``sourceURL``
/// - ``seriesDescription``
///
/// ### Initialization
/// - ``init(dataset:sourceURL:seriesDescription:)``
public struct DicomImportResult {
    /// Loaded volume dataset ready for rendering.
    ///
    /// Voxel data is stored as `Int16` in Hounsfield Units, with spacing and orientation
    /// derived from DICOM spatial metadata.
    public let dataset: VolumeDataset

    /// Original source URL (directory, ZIP, or single file).
    ///
    /// Used for UI display ("Loaded from...") and relative path resolution when saving projects.
    public let sourceURL: URL

    /// Human-readable series description from DICOM metadata (0008,103E).
    ///
    /// Typical values: "CT Head", "MR T2 FLAIR", "Chest CTA". Empty string if tag is missing.
    public let seriesDescription: String

    /// Create a DICOM import result.
    ///
    /// - Parameters:
    ///   - dataset: Loaded volume dataset
    ///   - sourceURL: Original source URL
    ///   - seriesDescription: Series description from DICOM metadata
    public init(dataset: VolumeDataset, sourceURL: URL, seriesDescription: String) {
        self.dataset = dataset
        self.sourceURL = sourceURL
        self.seriesDescription = seriesDescription
    }
}

public struct DicomStreamingImportResult {
    public let metadata: VolumeUploadDescriptor
    public let sourceURL: URL
    public let seriesDescription: String

    public init(metadata: VolumeUploadDescriptor,
                sourceURL: URL,
                seriesDescription: String) {
        self.metadata = metadata
        self.sourceURL = sourceURL
        self.seriesDescription = seriesDescription
    }
}

/// Progress updates during DICOM volume loading.
///
/// Emitted by ``DicomVolumeLoader/loadVolume(from:progress:completion:)`` to track parsing and
/// Hounsfield Unit conversion progress.
///
/// ## Example
///
/// ```swift
/// loader.loadVolume(from: url, progress: { update in
///     switch update {
///     case .started(let totalSlices):
///         print("Loading \(totalSlices) slices")
///     case .reading(let fraction):
///         progressView.progress = fraction
///     }
/// }, completion: { result in
///     // Handle result
/// })
/// ```
///
/// ## Topics
///
/// ### Cases
/// - ``started(totalSlices:)``
/// - ``reading(_:)``
public enum DicomVolumeProgress {
    /// Loading started with known total slice count.
    ///
    /// Emitted after parsing first slice and determining volume dimensions.
    case started(totalSlices: Int)

    /// Incremental progress during slice reading and HU conversion.
    ///
    /// Associated value is completion fraction in range 0.0...1.0.
    case reading(Double)
}

/// UI-friendly progress updates for DICOM loading.
///
/// Transformed from ``DicomVolumeProgress`` via ``DicomVolumeLoader/uiUpdate(from:)`` for
/// SwiftUI `ProgressView` bindings or AppKit progress indicators.
///
/// ## Topics
///
/// ### Cases
/// - ``started(totalSlices:)``
/// - ``reading(_:)``
public enum DicomVolumeUIProgress {
    /// UI notification that loading started with total slice count.
    case started(totalSlices: Int)

    /// UI progress fraction update (0.0...1.0).
    case reading(Double)
}
