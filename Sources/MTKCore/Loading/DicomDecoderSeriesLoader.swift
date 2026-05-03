//
//  DicomDecoderSeriesLoader.swift
//  MTK
//
//  Swift implementation of DicomSeriesLoading backed by DICOM-Decoder package
//  Streams slice data and metadata without external native dependencies
//  Thales Matheus Mendonça Santos — November 2025
//

import Foundation
import simd
import DicomCore

/// Pure-Swift DICOM series loader backed by the DICOM-Decoder package.
///
/// Implements ``DicomSeriesLoading`` protocol using a pure-Swift DICOM parser, eliminating
/// dependencies on native parsing libraries. Parses DICOM files in a directory, sorts
/// slices by Image Position Patient using IPP projection onto slice normal, and streams slice
/// data incrementally via progress callbacks.
///
/// ## Features
///
/// - Pure Swift implementation (no Objective-C++ bridge)
/// - Automatic slice sorting via IPP projection
/// - Incremental progress reporting with per-slice data
/// - Support for signed and unsigned 16-bit pixel data
/// - Rescale Slope/Intercept extraction for HU conversion
///
/// ## Example
///
/// ```swift
/// let loader = DicomDecoderSeriesLoader()
/// let volume = try loader.loadSeries(at: directoryURL, progress: { fraction, slices, sliceData, partialVolume in
///     print("Loaded \(slices) slices (\(Int(fraction * 100))% complete)")
/// })
/// ```
///
/// ## Topics
///
/// ### Initialization
/// - ``init()``
///
/// ### Loading Series
/// - ``loadSeries(at:progress:)``
public final class DicomDecoderSeriesLoader: DicomSeriesLoading {
    private let loader = DicomCore.DicomSeriesLoader()
    private var cachedVolume: BridgedVolume?

    /// Initialize a DICOM-Decoder series loader.
    ///
    /// Creates a new instance backed by `DicomCore.DicomSeriesLoader` from the DICOM-Decoder package.
    public init() {}

    /// Load a DICOM series from a directory using DICOM-Decoder.
    ///
    /// Parses all DICOM files in the directory, sorts slices by Image Position Patient,
    /// and streams slice data via progress callbacks. Returns a bridged volume conforming
    /// to ``DICOMSeriesVolumeProtocol``.
    ///
    /// - Parameters:
    ///   - url: Directory containing DICOM files (*.dcm or any DICOM format)
    ///   - progress: Optional progress callback receiving (fraction, slices loaded, slice data, partial volume)
    ///
    /// - Returns: Bridged volume object conforming to ``DICOMSeriesVolumeProtocol``
    ///
    /// - Throws: DICOM parser errors for I/O failures, invalid DICOM data, or missing required tags
    ///
    /// ## Progress Reporting
    ///
    /// The progress callback receives:
    /// - `fraction`: Completion fraction (0.0...1.0)
    /// - `slices`: Number of slices loaded so far
    /// - `sliceData`: Raw pixel data for the latest slice (Int16 or UInt16)
    /// - `partialVolume`: Partial volume with updated dimensions and slice count
    public func loadSeries(at url: URL,
                           progress: ((Double, UInt, Data?, Any) -> Void)?) throws -> Any {
        guard url.isFileURL else {
            throw NSError(domain: "br.thalesmms.dicom.decoder",
                          code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The provided URL is not a local path."])
        }

        cachedVolume = nil
        let volume = try loader.loadSeries(in: url, progress: { [weak self] fraction, slices, sliceData, seriesVolume in
            guard let self else { return }
            let bridged = self.bridge(seriesVolume)
            progress?(fraction, UInt(slices), sliceData, bridged)
        })

        return bridge(volume)
    }

    /// Bridge a DicomCore.DicomSeriesVolume into a DICOMSeriesVolumeProtocol-conforming wrapper.
    ///
    /// Caches the bridged volume to avoid redundant wrapping during incremental progress callbacks.
    ///
    /// - Parameter volume: DICOM-Decoder volume to bridge
    /// - Returns: Cached or newly created bridged volume
    private func bridge(_ volume: DicomSeriesVolume) -> BridgedVolume {
        if let cached = cachedVolume, cached.referencesSameVolume(as: volume) {
            return cached
        }
        let bridged = BridgedVolume(volume: volume)
        cachedVolume = bridged
        return bridged
    }
}

/// Bridge adapter conforming DicomCore.DicomSeriesVolume to DICOMSeriesVolumeProtocol.
///
/// Wraps the DICOM-Decoder package's volume representation, translating property names and
/// converting coordinate system matrices from Double to Float precision for Metal compatibility.
private final class BridgedVolume: DICOMSeriesVolumeProtocol {
    private let volume: DicomSeriesVolume

    /// Create a bridge wrapper around a DicomSeriesVolume.
    ///
    /// - Parameter volume: DICOM-Decoder volume to wrap
    init(volume: DicomSeriesVolume) {
        self.volume = volume
    }

    /// Check if this bridge wraps the same underlying DicomSeriesVolume instance.
    ///
    /// Used for caching optimization to avoid redundant bridging during progress callbacks.
    ///
    /// - Parameter other: DicomSeriesVolume to compare against
    /// - Returns: True if wrapping the same volume instance (by voxel buffer identity and dimensions)
    func referencesSameVolume(as other: DicomSeriesVolume) -> Bool {
        volume.voxels == other.voxels && volume.width == other.width && volume.height == other.height && volume.depth == other.depth
    }

    // MARK: - DICOMSeriesVolumeProtocol Conformance

    /// Bits allocated per pixel sample (8 or 16).
    var bitsAllocated: Int { volume.bitsAllocated }

    /// Width of each slice in pixels (DICOM Columns).
    var width: Int { volume.width }

    /// Height of each slice in pixels (DICOM Rows).
    var height: Int { volume.height }

    /// Number of slices in the series (volume depth).
    var depth: Int { volume.depth }

    /// Physical spacing between pixel centers along the row direction (millimeters).
    var spacingX: Double { volume.spacing.x }

    /// Physical spacing between pixel centers along the column direction (millimeters).
    var spacingY: Double { volume.spacing.y }

    /// Physical spacing between slice centers (millimeters).
    var spacingZ: Double { volume.spacing.z }

    /// 3×3 orientation matrix mapping voxel indices to patient coordinate system.
    ///
    /// Converts DicomCore's Double-precision orientation matrix to Float precision for Metal.
    var orientation: simd_float3x3 {
        let row = SIMD3<Float>(Float(volume.orientation.columns.0.x),
                               Float(volume.orientation.columns.0.y),
                               Float(volume.orientation.columns.0.z))
        let column = SIMD3<Float>(Float(volume.orientation.columns.1.x),
                                  Float(volume.orientation.columns.1.y),
                                  Float(volume.orientation.columns.1.z))
        let normal = SIMD3<Float>(Float(volume.orientation.columns.2.x),
                                  Float(volume.orientation.columns.2.y),
                                  Float(volume.orientation.columns.2.z))
        return simd_float3x3(columns: (row, column, normal))
    }
    /// Origin position of the first voxel in patient coordinate system (millimeters).
    ///
    /// Converts DicomCore's Double-precision origin to Float precision for Metal.
    var origin: SIMD3<Float> {
        SIMD3<Float>(Float(volume.origin.x),
                     Float(volume.origin.y),
                     Float(volume.origin.z))
    }

    /// Rescale slope for converting stored pixel values to modality units.
    ///
    /// `HU = slope * pixelValue + intercept`
    var rescaleSlope: Double { volume.rescaleSlope }

    /// Rescale intercept for converting stored pixel values to modality units.
    ///
    /// `HU = slope * pixelValue + intercept`
    var rescaleIntercept: Double { volume.rescaleIntercept }

    /// Whether pixel data is stored as signed integers (true) or unsigned integers (false).
    var isSignedPixel: Bool { volume.isSignedPixel }

    /// Human-readable series description from DICOM metadata (0008,103E).
    var seriesDescription: String { volume.seriesDescription }

    /// Imaging modality (e.g. "CT", "MR") from DICOM metadata (0008,0060).
    var modality: String { volume.modality }

    var windowCenter: Double? { volume.windowCenter }
    var windowWidth: Double? { volume.windowWidth }
}
