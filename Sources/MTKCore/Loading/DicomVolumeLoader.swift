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

/// Protocol for DICOM series volume data abstraction
public protocol DICOMSeriesVolumeProtocol {
    var bitsAllocated: Int { get }
    var width: Int { get }
    var height: Int { get }
    var depth: Int { get }
    var spacingX: Double { get }
    var spacingY: Double { get }
    var spacingZ: Double { get }
    var orientation: simd_float3x3 { get }
    var origin: SIMD3<Float> { get }
    var rescaleSlope: Double { get }
    var rescaleIntercept: Double { get }
    var isSignedPixel: Bool { get }
    var seriesDescription: String { get }
}

/// Protocol for DICOM series loading abstraction
public protocol DicomSeriesLoading: AnyObject {
    func loadSeries(at url: URL,
                    progress: ((Double, UInt, Data?, Any) -> Void)?) throws -> Any
}

/// Errors that can occur during DICOM volume loading
public enum DicomVolumeLoaderError: Error {
    case securityScopeUnavailable
    case unsupportedBitDepth
    case missingResult
    case pathTraversal
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

/// Result of a successful DICOM import operation
public struct DicomImportResult {
    public let dataset: VolumeDataset
    public let sourceURL: URL
    public let seriesDescription: String
    
    public init(dataset: VolumeDataset, sourceURL: URL, seriesDescription: String) {
        self.dataset = dataset
        self.sourceURL = sourceURL
        self.seriesDescription = seriesDescription
    }
}

/// Progress updates during DICOM volume loading
public enum DicomVolumeProgress {
    case started(totalSlices: Int)
    case reading(Double)
}

/// UI-friendly progress updates
public enum DicomVolumeUIProgress {
    case started(totalSlices: Int)
    case reading(Double)
}

/// DICOM volume loader with async progress tracking
public final class DicomVolumeLoader {
    private let logger = Logger(subsystem: "com.mtk.dicom", category: "Loader")
    private let loader: DicomSeriesLoading

    /// Optional Metal device for GPU-accelerated statistics computation
    private let device: (any MTLDevice)?

    /// Optional command queue for GPU-accelerated statistics computation
    private let commandQueue: (any MTLCommandQueue)?

    /// Optional histogram calculator for GPU-accelerated histogram computation
    public var histogramCalculator: VolumeHistogramCalculator?

    /// Optional statistics calculator for GPU-accelerated percentile and Otsu computations
    public var statisticsCalculator: VolumeStatisticsCalculator?

    /// Initialize with a custom series loader
    /// - Parameters:
    ///   - seriesLoader: DICOM series loading implementation
    ///   - device: Optional Metal device for GPU-accelerated statistics
    ///   - commandQueue: Optional command queue for GPU operations
    ///   - histogramCalculator: Optional histogram calculator for auto-windowing
    ///   - statisticsCalculator: Optional statistics calculator for auto-windowing
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
    
    /// Load a DICOM volume from a URL (directory, ZIP, or individual file)
    /// - Parameters:
    ///   - url: Source URL for DICOM data
    ///   - progress: Progress callback with loading updates
    ///   - completion: Completion handler with import result or error
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
    /// Translate internal progress updates into UI-friendly events
    /// - Parameter update: Internal progress update
    /// - Returns: UI-friendly progress update
    static func uiUpdate(from update: DicomVolumeProgress) -> DicomVolumeUIProgress {
        switch update {
        case .started(let total):
            return .started(totalSlices: total)
        case .reading(let fraction):
            return .reading(fraction)
        }
    }

    /// Convenience initializer using the default Swift DICOM decoder
    convenience init() {
        self.init(seriesLoader: DicomDecoderSeriesLoader())
    }
}
