//
//  DicomVolumeLoader.swift
//  MTK
//
//  DICOM volume loading with progress tracking
//  Handles ZIP extraction, series loading, and VolumeDataset creation
//  Thales Matheus Mendonça Santos — November 2025
//

import Foundation
import Metal
import OSLog
import simd
import ZIPFoundation

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
            return "Não foi possível acessar os arquivos selecionados."
        case .unsupportedBitDepth:
            return "Apenas séries DICOM escalares de 16 bits são suportadas no momento."
        case .missingResult:
            return "A conversão da série DICOM não retornou dados."
        case .pathTraversal:
            return "O arquivo contém caminhos inválidos que tentam acessar diretórios externos."
        case .bridgeError(let nsError):
            let description = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return description.isEmpty ? "Falha ao processar a série DICOM." : description
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

/// Orchestrates DICOM volume loading from directories, ZIP archives, or individual files.
///
/// Handles ZIP extraction, delegates DICOM parsing to a ``DicomSeriesLoading`` implementation,
/// converts pixel values to Hounsfield Units, and optionally computes GPU-accelerated window/level
/// recommendations via histogram percentiles.
///
/// ## Example
///
/// ```swift
/// let loader = DicomVolumeLoader() // Uses DicomDecoderSeriesLoader by default
///
/// loader.loadVolume(from: folderURL, progress: { update in
///     switch update {
///     case .started(let totalSlices):
///         print("Loading \(totalSlices) DICOM slices")
///     case .reading(let fraction):
///         progressBar.doubleValue = fraction
///     }
/// }, completion: { result in
///     switch result {
///     case .success(let importResult):
///         applyDataset(importResult.dataset)
///         print("Loaded: \(importResult.seriesDescription)")
///     case .failure(let error):
///         showError(error)
///     }
/// })
/// ```
///
/// ## Topics
///
/// ### Initialization
/// - ``init(seriesLoader:device:commandQueue:histogramCalculator:statisticsCalculator:)``
/// - ``init()``
///
/// ### Loading Volumes
/// - ``loadVolume(from:progress:completion:)``
///
/// ### GPU Acceleration
/// - ``histogramCalculator``
/// - ``statisticsCalculator``
///
/// ### Progress Translation
/// - ``uiUpdate(from:)``
public final class DicomVolumeLoader {
    private let logger = Logger(subsystem: "com.mtk.dicom", category: "Loader")
    private let loader: DicomSeriesLoading

    /// Optional Metal device for GPU-accelerated statistics computation.
    private let device: (any MTLDevice)?

    /// Optional command queue for GPU-accelerated statistics computation.
    private let commandQueue: (any MTLCommandQueue)?

    /// Optional histogram calculator for GPU-accelerated histogram computation.
    ///
    /// When provided (along with ``statisticsCalculator``), auto-windowing computes 2nd/98th
    /// percentile window recommendations from volume intensity histogram.
    public var histogramCalculator: VolumeHistogramCalculator?

    /// Optional statistics calculator for GPU-accelerated percentile and Otsu computations.
    ///
    /// Used with ``histogramCalculator`` to compute recommended window/level from histogram percentiles.
    public var statisticsCalculator: VolumeStatisticsCalculator?

    /// Initialize with a custom DICOM series loader and optional GPU acceleration.
    ///
    /// - Parameters:
    ///   - seriesLoader: DICOM series loading implementation (``DicomDecoderSeriesLoader`` or custom bridge)
    ///   - device: Optional Metal device for GPU-accelerated auto-windowing statistics
    ///   - commandQueue: Optional command queue for GPU operations
    ///   - histogramCalculator: Optional histogram calculator for intensity distribution analysis
    ///   - statisticsCalculator: Optional statistics calculator for percentile-based window recommendations
    ///
    /// - Note: GPU parameters are optional. When omitted, window recommendations default to intensity range min/max.
    public init(seriesLoader: DicomSeriesLoading,
                device: (any MTLDevice)? = nil,
                commandQueue: (any MTLCommandQueue)? = nil,
                histogramCalculator: VolumeHistogramCalculator? = nil,
                statisticsCalculator: VolumeStatisticsCalculator? = nil) {
        self.loader = seriesLoader
        self.device = device
        self.commandQueue = commandQueue
        self.histogramCalculator = histogramCalculator
        self.statisticsCalculator = statisticsCalculator
    }
    
    private struct PreparedDirectory {
        let url: URL
        let cleanupRoot: URL?
    }
    
    /// Load a DICOM volume from a URL, supporting directories, ZIP archives, or individual files.
    ///
    /// Executes on a background queue. Progress callbacks and completion handler are dispatched to the main queue.
    ///
    /// ## Workflow
    ///
    /// 1. If source is a ZIP, extracts to temporary directory with path traversal validation
    /// 2. Delegates DICOM parsing to ``DicomSeriesLoading`` implementation
    /// 3. Converts pixel values to Hounsfield Units using DICOM Rescale Slope/Intercept
    /// 4. Optionally computes 2nd/98th percentile window recommendation via GPU histogram
    /// 5. Constructs ``VolumeDataset`` with spatial metadata from Image Orientation/Position Patient
    ///
    /// - Parameters:
    ///   - url: Source URL (directory containing DICOM files, .zip archive, or single .dcm file)
    ///   - progress: Progress callback receiving ``DicomVolumeProgress`` events on main queue
    ///   - completion: Completion handler with ``DicomImportResult`` or ``DicomVolumeLoaderError`` on main queue
    ///
    /// ## Supported Formats
    ///
    /// - 16-bit scalar CT/MR volumes (signed or unsigned pixel representation)
    /// - Standard DICOM files with Image Orientation Patient (0020,0037) and Image Position Patient (0020,0032)
    /// - ZIP archives with DICOM files (nested directories supported)
    ///
    /// ## Example
    ///
    /// ```swift
    /// let loader = DicomVolumeLoader()
    /// loader.loadVolume(from: selectedURL, progress: { update in
    ///     if case .reading(let fraction) = update {
    ///         self.progressBar.doubleValue = fraction
    ///     }
    /// }, completion: { result in
    ///     switch result {
    ///     case .success(let importResult):
    ///         self.applyDataset(importResult.dataset)
    ///     case .failure(let error):
    ///         self.presentError(error)
    ///     }
    /// })
    /// ```
    public func loadVolume(from url: URL,
                    progress: @escaping (DicomVolumeProgress) -> Void,
                    completion: @escaping (Result<DicomImportResult, Error>) -> Void) {
        let sourceURL = url.standardizedFileURL
        logger.info("Starting DICOM import from \(sourceURL.path(percentEncoded: false))")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let prepared = try self.prepareDirectory(from: url)
                let directoryURL = prepared.url

                var convertedData: Data?
                var dimensions = SIMD3<Int32>(repeating: 0)
                var spacing = SIMD3<Float>(repeating: 0)
                var orientation = matrix_identity_float3x3
                var origin = float3.zero
                var slope: Double = 1.0
                var intercept: Double = 0.0
                var isSigned = false
                var minHU = Int32.max
                var maxHU = Int32.min
                var encounteredFatalError = false

                let volume = try self.loader.loadSeries(at: directoryURL, progress: { fraction, slicesLoaded, sliceData, partialVolume in
                    if encounteredFatalError { return }

                    guard let partialVolume = partialVolume as? any DICOMSeriesVolumeProtocol else { return }

                    if convertedData == nil {
                        if partialVolume.bitsAllocated != 16 {
                            encounteredFatalError = true
                            DispatchQueue.main.async {
                                completion(.failure(DicomVolumeLoaderError.unsupportedBitDepth))
                            }
                            return
                        }

                        dimensions = SIMD3(Int32(partialVolume.width),
                                            Int32(partialVolume.height),
                                            Int32(partialVolume.depth))
                        let meterScale: Float = 0.001
                        spacing = SIMD3(Float(partialVolume.spacingX) * meterScale,
                                        Float(partialVolume.spacingY) * meterScale,
                                        Float(partialVolume.spacingZ) * meterScale)
                        orientation = partialVolume.orientation
                        origin = SIMD3<Float>(partialVolume.origin) * meterScale
                        slope = partialVolume.rescaleSlope == 0 ? 1.0 : partialVolume.rescaleSlope
                        intercept = partialVolume.rescaleIntercept
                        isSigned = partialVolume.isSignedPixel
                        let voxelCount = Int(partialVolume.width) * Int(partialVolume.height) * Int(partialVolume.depth)
                        convertedData = Data(count: voxelCount * MemoryLayout<Int16>.size)
                        DispatchQueue.main.async {
                            progress(.started(totalSlices: Int(partialVolume.depth)))
                        }
                    }

                    guard convertedData != nil else { return }

                    if let sliceData = sliceData {
                        convertedData!.withUnsafeMutableBytes { destBuffer in
                            guard let destPtr = destBuffer.bindMemory(to: Int16.self).baseAddress else { return }
                            let sliceVoxelCount = Int(dimensions.x) * Int(dimensions.y)
                            let sliceIndex = max(Int(slicesLoaded) - 1, 0)
                            let offset = sliceIndex * sliceVoxelCount
                            sliceData.withUnsafeBytes { rawBuffer in
                                if isSigned {
                                    let source = rawBuffer.bindMemory(to: Int16.self)
                                    for index in 0..<sliceVoxelCount {
                                        let rawValue = Int32(source[index])
                                        let huDouble = Double(rawValue) * slope + intercept
                                        let huRounded = Int32(lround(huDouble))
                                        minHU = min(minHU, huRounded)
                                        maxHU = max(maxHU, huRounded)
                                        destPtr[offset + index] = VolumetricMath.clampHU(huRounded)
                                    }
                                } else {
                                    let source = rawBuffer.bindMemory(to: UInt16.self)
                                    for index in 0..<sliceVoxelCount {
                                        let rawValue = Int32(source[index])
                                        let huDouble = Double(rawValue) * slope + intercept
                                        let huRounded = Int32(lround(huDouble))
                                        minHU = min(minHU, huRounded)
                                        maxHU = max(maxHU, huRounded)
                                        destPtr[offset + index] = VolumetricMath.clampHU(huRounded)
                                    }
                                }
                            }
                        }
                    }
                    DispatchQueue.main.async {
                        progress(.reading(fraction))
                    }
                })

                if encounteredFatalError {
                    if let cleanupRoot = prepared.cleanupRoot {
                        try? FileManager.default.removeItem(at: cleanupRoot)
                    }
                    return
                }

                guard let convertedData else {
                    self.logger.error("DICOM loader did not produce voxel data for \(sourceURL.lastPathComponent)")
                    throw DicomVolumeLoaderError.missingResult
                }

                let range = Self.intensityRange(minHU: minHU, maxHU: maxHU)
                var dataset = self.makeDataset(data: convertedData,
                                               width: Int(dimensions.x),
                                               height: Int(dimensions.y),
                                               depth: Int(dimensions.z),
                                               spacing: spacing,
                                               orientationMatrix: orientation,
                                               origin: origin,
                                               intensityRange: range)

                if let cleanupRoot = prepared.cleanupRoot {
                    try? FileManager.default.removeItem(at: cleanupRoot)
                }

                self.computeRecommendedWindow(for: dataset,
                                              intensityRange: range) { updatedDataset in
                    if let updatedDataset {
                        dataset = updatedDataset
                    }

                    let result = DicomImportResult(dataset: dataset,
                                                   sourceURL: url,
                                                   seriesDescription: (volume as? any DICOMSeriesVolumeProtocol)?.seriesDescription ?? "")

                    self.logger.info("DICOM import completed for \(sourceURL.lastPathComponent) (\(dimensions.x)x\(dimensions.y)x\(dimensions.z))")
                    DispatchQueue.main.async {
                        completion(.success(result))
                    }
                }
            } catch let error as NSError {
                self.logger.error("DICOM import failed for \(sourceURL.lastPathComponent): \(error.localizedDescription)")
                DispatchQueue.main.async {
                    completion(.failure(DicomVolumeLoaderError.bridgeError(error)))
                }
            } catch {
                self.logger.error("DICOM import failed for \(sourceURL.lastPathComponent): \(error.localizedDescription)")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    private func prepareDirectory(from url: URL) throws -> PreparedDirectory {
        if url.hasDirectoryPath {
            logger.info("Using DICOM directory at \(url.path(percentEncoded: false))")
            return PreparedDirectory(url: url, cleanupRoot: nil)
        }

        if url.pathExtension.lowercased() == "zip" {
            let extracted = try unzip(url: url)
            logger.info("Extracted archive \(url.lastPathComponent) to \(extracted.url.path(percentEncoded: false))")
            return extracted
        }

        // Assume individual file inside a directory; use parent directory.
        let parent = url.deletingLastPathComponent()
        logger.info("Using parent directory \(parent.path(percentEncoded: false)) for selected file \(url.lastPathComponent)")
        return PreparedDirectory(url: parent, cleanupRoot: nil)
    }

    private func unzip(url: URL) throws -> PreparedDirectory {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(),
                                     isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let archive: Archive
        do {
            guard let opened = try Archive(url: url, accessMode: .read) else {
                logger.error("Archive initializer returned nil for \(url.lastPathComponent)")
                throw DicomVolumeLoaderError.missingResult
            }
            archive = opened
        } catch {
            logger.error("Failed to open archive \(url.lastPathComponent): \(error.localizedDescription)")
            throw DicomVolumeLoaderError.bridgeError(error as NSError)
        }

        var extractedEntries = 0
        for entry in archive {
            // Validate entry path to prevent path traversal attacks
            let sanitizedPath = try Self.sanitizeZipEntryPath(entry.path)
            let destinationURL = temporaryDirectory.appendingPathComponent(sanitizedPath)
            let destinationDir = destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: destinationURL)
            extractedEntries += 1
        }
        logger.info("Extracted \(extractedEntries) entries from \(url.lastPathComponent)")

        // If the archive expands to a single directory, dive into it for cleanliness.
        let contents = try FileManager.default.contentsOfDirectory(at: temporaryDirectory,
                                                                   includingPropertiesForKeys: [.isDirectoryKey],
                                                                   options: [.skipsHiddenFiles])
        if contents.count == 1, (try contents.first?.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return PreparedDirectory(url: contents[0], cleanupRoot: temporaryDirectory)
        }

        return PreparedDirectory(url: temporaryDirectory, cleanupRoot: temporaryDirectory)
    }
}

private extension DicomVolumeLoader {
    /// Validate and sanitize ZIP entry path to prevent path traversal attacks
    /// - Parameter entryPath: Raw path from ZIP entry
    /// - Returns: Sanitized path safe for extraction
    /// - Throws: DicomVolumeLoaderError.pathTraversal if path is malicious
    static func sanitizeZipEntryPath(_ entryPath: String) throws -> String {
        // Reject absolute paths
        guard !entryPath.hasPrefix("/") else {
            throw DicomVolumeLoaderError.pathTraversal
        }

        // Normalize path components and check for traversal attempts
        let components = entryPath.split(separator: "/").map(String.init)
        for component in components {
            // Reject parent directory references
            if component == ".." {
                throw DicomVolumeLoaderError.pathTraversal
            }
            // Reject hidden files/directories (security best practice)
            if component.hasPrefix(".") && component != "." {
                throw DicomVolumeLoaderError.pathTraversal
            }
        }

        // Filter out current directory references and join
        let sanitizedComponents = components.filter { $0 != "." }
        guard !sanitizedComponents.isEmpty else {
            throw DicomVolumeLoaderError.pathTraversal
        }

        return sanitizedComponents.joined(separator: "/")
    }

    static func intensityRange(minHU: Int32, maxHU: Int32) -> ClosedRange<Int32> {
        var minHU = minHU
        var maxHU = maxHU
        let clampMin: Int32 = -1024
        let clampMax: Int32 = 3071
        if minHU > maxHU {
            minHU = clampMin
            maxHU = clampMax
        } else {
            minHU = Swift.max(minHU, clampMin)
            maxHU = Swift.min(maxHU, clampMax)
        }
        return minHU...maxHU
    }

    func makeDataset(data: Data,
                     width: Int,
                     height: Int,
                     depth: Int,
                     spacing: SIMD3<Float>,
                     orientationMatrix: simd_float3x3,
                     origin: SIMD3<Float>,
                     intensityRange: ClosedRange<Int32>,
                     recommendedWindow: ClosedRange<Int32>? = nil) -> VolumeDataset {
        let volumeDimensions = VolumeDimensions(width: width, height: height, depth: depth)
        let volumeSpacing = VolumeSpacing(x: Double(spacing.x),
                                          y: Double(spacing.y),
                                          z: Double(spacing.z))
        let row = SIMD3<Float>(orientationMatrix.columns.0.x,
                               orientationMatrix.columns.0.y,
                               orientationMatrix.columns.0.z)
        let column = SIMD3<Float>(orientationMatrix.columns.1.x,
                                  orientationMatrix.columns.1.y,
                                  orientationMatrix.columns.1.z)
        let orientation = VolumeOrientation(row: row, column: column, origin: origin)
        return VolumeDataset(data: data,
                             dimensions: volumeDimensions,
                             spacing: volumeSpacing,
                             pixelFormat: .int16Signed,
                             intensityRange: intensityRange,
                             orientation: orientation,
                             recommendedWindow: recommendedWindow)
    }

    func computeRecommendedWindow(for dataset: VolumeDataset,
                                  intensityRange: ClosedRange<Int32>,
                                  completion: @escaping (VolumeDataset?) -> Void) {
        guard let histogramCalculator,
              let statisticsCalculator,
              let device,
              let commandQueue else {
            completion(nil)
            return
        }

        let factory = VolumeTextureFactory(dataset: dataset)
        guard let volumeTexture = factory.generate(device: device) else {
            logger.warning("Failed to create Metal texture for histogram computation")
            completion(nil)
            return
        }
        volumeTexture.label = "VolumeTexture3D.Histogram"

        let channelCount = 1
        let voxelMin = Int32(intensityRange.lowerBound)
        let voxelMax = Int32(intensityRange.upperBound)

        histogramCalculator.computeHistogram(for: volumeTexture,
                                             channelCount: channelCount,
                                             voxelMin: voxelMin,
                                             voxelMax: voxelMax,
                                             bins: 0) { [weak self] histogramResult in
            guard let self else {
                completion(nil)
                return
            }

            switch histogramResult {
            case .success(let histograms):
                let percentiles: [Float] = [0.02, 0.98]
                statisticsCalculator.computePercentiles(from: histograms,
                                                       percentiles: percentiles) { [weak self] percentilesResult in
                    guard let self else {
                        completion(nil)
                        return
                    }

                    switch percentilesResult {
                    case .success(let percentileBins):
                        guard percentileBins.count == 2 else {
                            self.logger.warning("Expected 2 percentile bins, got \(percentileBins.count)")
                            completion(nil)
                            return
                        }

                        let binToHU = { (bin: UInt32) -> Int32 in
                            let binCount = histograms[0].count
                            let normalizedBin = Float(bin) / Float(binCount - 1)
                            let huValue = Float(voxelMin) + normalizedBin * Float(voxelMax - voxelMin)
                            return Int32(huValue.rounded())
                        }

                        let minHU = binToHU(percentileBins[0])
                        let maxHU = binToHU(percentileBins[1])
                        let recommendedWindow = minHU...maxHU

                        var updatedDataset = dataset
                        updatedDataset.recommendedWindow = recommendedWindow

                        self.logger.info("Computed recommended window: [\(minHU), \(maxHU)] from percentiles [2%, 98%]")
                        completion(updatedDataset)

                    case .failure(let error):
                        self.logger.warning("Failed to compute percentiles: \(error.localizedDescription)")
                        completion(nil)
                    }
                }

            case .failure(let error):
                self.logger.warning("Failed to compute histogram: \(error.localizedDescription)")
                completion(nil)
            }
        }
    }
}

public extension DicomVolumeLoader {
    /// Translate internal progress updates into UI-friendly events.
    ///
    /// Maps ``DicomVolumeProgress`` cases to ``DicomVolumeUIProgress`` for consumption by
    /// AppKit `NSProgressIndicator` or SwiftUI `ProgressView` bindings.
    ///
    /// - Parameter update: Internal progress update from ``loadVolume(from:progress:completion:)``
    /// - Returns: UI-friendly progress update suitable for binding to progress views
    ///
    /// ## Example
    ///
    /// ```swift
    /// loader.loadVolume(from: url, progress: { internalProgress in
    ///     let uiProgress = DicomVolumeLoader.uiUpdate(from: internalProgress)
    ///     switch uiProgress {
    ///     case .started(let totalSlices):
    ///         statusLabel.stringValue = "Loading \(totalSlices) slices..."
    ///     case .reading(let fraction):
    ///         progressBar.doubleValue = fraction * 100.0
    ///     }
    /// }, completion: { result in
    ///     // Handle result
    /// })
    /// ```
    static func uiUpdate(from update: DicomVolumeProgress) -> DicomVolumeUIProgress {
        switch update {
        case .started(let total):
            return .started(totalSlices: total)
        case .reading(let fraction):
            return .reading(fraction)
        }
    }

    /// Convenience initializer using the default Swift-based DICOM decoder.
    ///
    /// Equivalent to `DicomVolumeLoader(seriesLoader: DicomDecoderSeriesLoader())`.
    /// Uses the pure-Swift DICOM-Decoder package without external native dependencies.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let loader = DicomVolumeLoader() // Uses DicomDecoderSeriesLoader
    /// loader.loadVolume(from: directoryURL, progress: { _ in }, completion: { result in
    ///     // Handle result
    /// })
    /// ```
    convenience init() {
        self.init(seriesLoader: DicomDecoderSeriesLoader())
    }
}
