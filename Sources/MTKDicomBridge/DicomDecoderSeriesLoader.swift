//
//  DicomDecoderSeriesLoader.swift
//  MTK
//
//  Swift implementation of DicomSeriesLoading backed by DICOM-Decoder package
//  Streams slice data and metadata without external native dependencies
//  Thales Matheus Mendonça Santos — November 2025
//

import Foundation
import Metal
import MTKCore
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
    private let cacheLock = NSLock()
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

        do {
            resetCachedVolume()
            let metadata = Self.readMetadata(from: url)
            let volume = try loader.loadSeries(in: url, progress: { [weak self] fraction, slices, sliceData, seriesVolume in
                guard let self else { return }
                let bridged = self.bridge(seriesVolume, metadata: metadata)
                progress?(fraction, UInt(slices), sliceData, bridged)
            })

            return bridge(volume, metadata: metadata)
        } catch let error as DicomSeriesLoaderError {
            throw Self.map(error)
        }
    }

    /// Bridge a DicomCore.DicomSeriesVolume into a DICOMSeriesVolumeProtocol-conforming wrapper.
    ///
    /// Caches the bridged volume to avoid redundant wrapping during incremental progress callbacks.
    ///
    /// - Parameter volume: DICOM-Decoder volume to bridge
    /// - Returns: Cached or newly created bridged volume
    private func bridge(_ volume: DicomSeriesVolume, metadata: BridgedVolumeMetadata) -> BridgedVolume {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedVolume, cached.referencesSameVolume(as: volume) {
            return cached
        }
        let bridged = BridgedVolume(volume: volume, metadata: metadata)
        cachedVolume = bridged
        return bridged
    }

    private func resetCachedVolume() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedVolume = nil
    }

    static func readMetadata(from directory: URL) -> BridgedVolumeMetadata {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .empty
        }

        let fileURLs = enumerator.compactMap { $0 as? URL }.sorted { $0.path < $1.path }
        var seriesMetadata = BridgedVolumeMetadata.empty
        var sliceMetadata: [DICOMSliceMetadata] = []

        for fileURL in fileURLs {
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues?.isRegularFile == true else { continue }
            guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { continue }

            guard let metadata = readSliceMetadata(fromDICOMData: data) else { continue }
            seriesMetadata = seriesMetadata.merging(metadata.seriesMetadata)
            sliceMetadata.append(metadata)
        }

        if let spacingZ = computeSliceSpacing(from: sliceMetadata) {
            seriesMetadata = seriesMetadata.withSpacingZ(spacingZ)
        }

        return seriesMetadata
    }

    private static func readSliceMetadata(fromDICOMData data: Data) -> DICOMSliceMetadata? {
        let startOffset = hasDICMPreamble(data) ? 132 : 0
        if let metadata = parseMetadata(from: data, startOffset: startOffset, explicitVR: true) {
            return metadata
        }
        if let metadata = parseMetadata(from: data, startOffset: startOffset, explicitVR: false) {
            return metadata
        }
        return nil
    }

    private static func computeSliceSpacing(from metadata: [DICOMSliceMetadata]) -> Double? {
        let positionedSlices = metadata.compactMap { slice -> SIMD3<Double>? in
            slice.imagePositionPatient
        }
        guard positionedSlices.count >= 2 else { return nil }

        let normal = metadata.lazy.compactMap(\.imageOrientationPatient).first.flatMap(sliceNormal(from:))
            ?? SIMD3<Double>(0, 0, 1)
        let projections = positionedSlices
            .map { simd_dot($0, normal) }
            .filter(\.isFinite)
            .sorted()
        guard projections.count >= 2 else { return nil }

        let deltas = zip(projections.dropFirst(), projections)
            .map { abs($0 - $1) }
            .filter { $0.isFinite && $0 > 0.0001 }
            .sorted()
        guard !deltas.isEmpty else { return nil }

        let middle = deltas.count / 2
        if deltas.count.isMultiple(of: 2) {
            return (deltas[middle - 1] + deltas[middle]) / 2
        }
        return deltas[middle]
    }

    private static func sliceNormal(from orientation: [Double]) -> SIMD3<Double>? {
        guard orientation.count >= 6 else { return nil }
        let row = SIMD3<Double>(orientation[0], orientation[1], orientation[2])
        let column = SIMD3<Double>(orientation[3], orientation[4], orientation[5])
        let normal = simd_cross(row, column)
        let length = simd_length(normal)
        guard length.isFinite, length > 0.0001 else {
            return nil
        }
        return normal / length
    }

    private static func hasDICMPreamble(_ data: Data) -> Bool {
        guard data.count >= 132 else { return false }
        return data[128] == 0x44 && data[129] == 0x49 && data[130] == 0x43 && data[131] == 0x4D
    }

    private static func parseMetadata(from data: Data,
                                      startOffset: Int,
                                      explicitVR: Bool) -> DICOMSliceMetadata? {
        var offset = startOffset
        var modality = ""
        var windowCenter: Double?
        var windowWidth: Double?
        var imageOrientationPatient: [Double]?
        var imagePositionPatient: SIMD3<Double>?
        var instanceNumber: Int?
        var foundMetadata = false

        while offset + 8 <= data.count {
            let group = readUInt16LE(from: data, at: offset)
            let element = readUInt16LE(from: data, at: offset + 2)
            let tag = (UInt32(group) << 16) | UInt32(element)
            if tag == 0x7FE0_0010 {
                break
            }

            let valueOffset: Int
            let valueLength: UInt32
            if explicitVR {
                guard let vr = valueRepresentation(from: data, at: offset + 4) else {
                    return foundMetadata
                        ? DICOMSliceMetadata(
                            modality: modality,
                            windowCenter: windowCenter,
                            windowWidth: windowWidth,
                            imageOrientationPatient: imageOrientationPatient,
                            imagePositionPatient: imagePositionPatient,
                            instanceNumber: instanceNumber
                        )
                        : nil
                }
                if usesLongExplicitLength(vr) {
                    guard offset + 12 <= data.count else { break }
                    valueLength = readUInt32LE(from: data, at: offset + 8)
                    valueOffset = offset + 12
                } else {
                    valueLength = UInt32(readUInt16LE(from: data, at: offset + 6))
                    valueOffset = offset + 8
                }
            } else {
                valueLength = readUInt32LE(from: data, at: offset + 4)
                valueOffset = offset + 8
            }

            if valueLength == UInt32.max {
                guard let nextOffset = offsetAfterUndefinedLengthValue(in: data, from: valueOffset),
                      nextOffset > offset else {
                    break
                }
                offset = nextOffset
                continue
            }

            if valueOffset > data.count {
                break
            }

            let length = Int(valueLength)
            guard length >= 0, valueOffset + length <= data.count else {
                break
            }

            if tag == 0x0008_0060 {
                modality = dicomString(from: data, offset: valueOffset, length: length)
                foundMetadata = foundMetadata || !modality.isEmpty
            } else if tag == 0x0028_1050 {
                windowCenter = firstDouble(in: dicomString(from: data, offset: valueOffset, length: length))
                foundMetadata = foundMetadata || windowCenter != nil
            } else if tag == 0x0028_1051 {
                windowWidth = firstDouble(in: dicomString(from: data, offset: valueOffset, length: length))
                foundMetadata = foundMetadata || windowWidth != nil
            } else if tag == 0x0020_0037 {
                let values = doubles(in: dicomString(from: data, offset: valueOffset, length: length))
                if values.count >= 6 {
                    imageOrientationPatient = Array(values.prefix(6))
                    foundMetadata = true
                }
            } else if tag == 0x0020_0032 {
                let values = doubles(in: dicomString(from: data, offset: valueOffset, length: length))
                if values.count >= 3 {
                    imagePositionPatient = SIMD3<Double>(values[0], values[1], values[2])
                    foundMetadata = true
                }
            } else if tag == 0x0020_0013 {
                if let value = firstDouble(in: dicomString(from: data, offset: valueOffset, length: length)),
                   value.isFinite {
                    instanceNumber = Int(value)
                }
                foundMetadata = foundMetadata || instanceNumber != nil
            }

            let nextOffset = valueOffset + length
            guard nextOffset > offset else { break }
            offset = nextOffset
        }

        guard foundMetadata else { return nil }
        return DICOMSliceMetadata(
            modality: modality,
            windowCenter: windowCenter,
            windowWidth: windowWidth,
            imageOrientationPatient: imageOrientationPatient,
            imagePositionPatient: imagePositionPatient,
            instanceNumber: instanceNumber
        )
    }

    private static func offsetAfterUndefinedLengthValue(in data: Data, from valueOffset: Int) -> Int? {
        guard valueOffset + 8 <= data.count else { return nil }
        var offset = valueOffset
        while offset + 8 <= data.count {
            let group = readUInt16LE(from: data, at: offset)
            let element = readUInt16LE(from: data, at: offset + 2)
            if group == 0xFFFE, element == 0xE0DD {
                return offset + 8
            }
            offset += 1
        }
        return nil
    }

    private static func valueRepresentation(from data: Data, at offset: Int) -> String? {
        guard offset + 2 <= data.count else { return nil }
        let bytes = [data[offset], data[offset + 1]]
        guard bytes.allSatisfy({ ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) }) else {
            return nil
        }
        return String(bytes: bytes, encoding: .ascii)
    }

    private static func usesLongExplicitLength(_ vr: String) -> Bool {
        switch vr {
        case "OB", "OD", "OF", "OL", "OW", "SQ", "UC", "UR", "UT", "UN":
            return true
        default:
            return false
        }
    }

    private static func dicomString(from data: Data, offset: Int, length: Int) -> String {
        let bytes = data[offset..<(offset + length)].filter { $0 != 0 }
        return String(bytes: bytes, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
    }

    private static func readUInt16LE(from data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(from data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) |
            (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) |
            (UInt32(data[offset + 3]) << 24)
    }

    private static func firstDouble(in dicomValue: String) -> Double? {
        let value = dicomValue
            .split(whereSeparator: { $0 == "\\" || $0.isWhitespace })
            .first
            .map(String.init)
        return value.flatMap(Double.init)
    }

    private static func doubles(in dicomValue: String) -> [Double] {
        dicomValue
            .split(whereSeparator: { $0 == "\\" || $0.isWhitespace })
            .compactMap { Double($0) }
    }

    private static func map(_ error: DicomSeriesLoaderError) -> DicomVolumeLoaderError {
        switch error {
        case .unsupportedBitDepth:
            return .unsupportedBitDepth
        case .unsupportedSamplesPerPixel(let samples):
            return .unsupportedPixelData(reason: "Unsupported samples per pixel: \(samples)")
        case .inconsistentDimensions:
            return .invalidGeometry(reason: "Inconsistent slice dimensions")
        case .inconsistentOrientation:
            return .invalidGeometry(reason: "Inconsistent slice orientation")
        case .inconsistentPixelRepresentation:
            return .unsupportedPixelData(reason: "Inconsistent signed/unsigned pixel representation")
        case .noDicomFiles:
            return .missingResult
        case .failedToDecode(let url):
            return .bridgeError(NSError(
                domain: "DicomCore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to decode DICOM file: \(url.lastPathComponent)"]
            ))
        }
    }
}

struct BridgedVolumeMetadata: Equatable {
    static let empty = BridgedVolumeMetadata(modality: "", windowCenter: nil, windowWidth: nil, spacingZ: nil)

    let modality: String
    let windowCenter: Double?
    let windowWidth: Double?
    let spacingZ: Double?

    func merging(_ other: BridgedVolumeMetadata) -> BridgedVolumeMetadata {
        BridgedVolumeMetadata(
            modality: modality.isEmpty ? other.modality : modality,
            windowCenter: windowCenter ?? other.windowCenter,
            windowWidth: windowWidth ?? other.windowWidth,
            spacingZ: spacingZ ?? other.spacingZ
        )
    }

    func withSpacingZ(_ spacingZ: Double) -> BridgedVolumeMetadata {
        BridgedVolumeMetadata(
            modality: modality,
            windowCenter: windowCenter,
            windowWidth: windowWidth,
            spacingZ: spacingZ
        )
    }
}

private struct DICOMSliceMetadata: Equatable {
    let modality: String
    let windowCenter: Double?
    let windowWidth: Double?
    let imageOrientationPatient: [Double]?
    let imagePositionPatient: SIMD3<Double>?
    let instanceNumber: Int?

    var seriesMetadata: BridgedVolumeMetadata {
        BridgedVolumeMetadata(
            modality: modality,
            windowCenter: windowCenter,
            windowWidth: windowWidth,
            spacingZ: nil
        )
    }
}

/// Bridge adapter conforming DicomCore.DicomSeriesVolume to DICOMSeriesVolumeProtocol.
///
/// Wraps the DICOM-Decoder package's volume representation, translating property names and
/// converting coordinate system matrices from Double to Float precision for Metal compatibility.
private final class BridgedVolume: DICOMSeriesVolumeProtocol {
    private let volume: DicomSeriesVolume
    private let metadata: BridgedVolumeMetadata

    /// Create a bridge wrapper around a DicomSeriesVolume.
    ///
    /// - Parameter volume: DICOM-Decoder volume to wrap
    init(volume: DicomSeriesVolume, metadata: BridgedVolumeMetadata) {
        self.volume = volume
        self.metadata = metadata
    }

    /// Check if this bridge matches the current per-load cache key.
    ///
    /// Used for caching optimization to avoid redundant bridging during progress callbacks.
    ///
    /// - Parameter other: DicomSeriesVolume to compare against
    /// - Returns: True for the same per-load progress placeholder or final volume payload shape.
    func referencesSameVolume(as other: DicomSeriesVolume) -> Bool {
        volume.width == other.width &&
            volume.height == other.height &&
            volume.depth == other.depth &&
            volume.voxels.count == other.voxels.count
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
    var spacingZ: Double { metadata.spacingZ ?? volume.spacing.z }

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

    /// Imaging modality from DICOM metadata (0008,0060).
    var modality: String { metadata.modality }

    /// Window center from DICOM metadata (0028,1050), when present.
    var windowCenter: Double? { metadata.windowCenter }

    /// Window width from DICOM metadata (0028,1051), when present.
    var windowWidth: Double? { metadata.windowWidth }
}

public extension DicomVolumeLoader {
    /// Convenience initializer using the versioned DICOM-Decoder bridge product.
    ///
    /// Import `MTKDicomBridge` when the default Swift DICOM parser is desired. `MTKCore`
    /// itself only requires an injected ``DicomSeriesLoading`` implementation.
    convenience init(device: (any MTLDevice)? = nil) {
        self.init(seriesLoader: DicomDecoderSeriesLoader(), device: device)
    }
}
