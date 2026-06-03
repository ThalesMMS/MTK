//
//  VolumeDatasetFactory.swift
//  MTK
//
//  Factory methods to convert volumetric series data to VolumeDataset.
//  Handles pixel format mapping, orientation transfer, and spacing conversion.
//  Thales Matheus Mendonça Santos — November 2025
//

import Foundation
import simd

/// Factory for creating VolumeDataset instances from MTKCore volumetric input DTOs.
///
/// MTKCore does not parse DICOM or own application-side loading. Apps that use
/// GDCM, DICOM-Decoder, or another loader should map their decoded scalar volume
/// into ``VolumetricSeriesData``/``VolumetricSeriesDataProvider`` or construct a
/// ``VolumeDataset`` directly.
public enum VolumeDatasetFactory {

    /// Creates a VolumeDataset from volumetric series data.
    ///
    /// This factory method converts domain-level volumetric series data to the
    /// VolumeDataset structure used throughout the MTK volume rendering stack.
    /// It handles:
    /// - Voxel data preservation
    /// - Dimension mapping (width, height, depth)
    /// - Spacing conversion (x, y, z coordinates)
    /// - Pixel format conversion with type safety
    /// - Orientation matrix and origin transfer
    /// - Intensity range mapping
    /// - Recommended window level transfer
    ///
    /// - Parameters:
    ///   - voxels: Raw voxel data as Data object
    ///   - dimensions: 3D dimensions (width, height, depth)
    ///   - spacing: Physical spacing between voxels (x, y, z)
    ///   - pixelFormat: Source pixel format type
    ///   - intensityRange: Min/max intensity values for the dataset
    ///   - orientation: Volumetric orientation with row/column vectors and origin
    ///   - recommendedWindow: Optional window level for display optimization
    ///
    /// - Returns: A fully initialized VolumeDataset ready for rendering
    ///
    /// - Note: This method preserves all metadata from the source volumetric data.
    ///   The resulting VolumeDataset is immutable (Sendable) and thread-safe.
    ///
    /// - Example:
    ///   ```swift
    ///   let sourceData = VolumetricSeriesData(...)
    ///   let dataset = VolumeDatasetFactory.makeVolumeDataset(
    ///       voxels: sourceData.voxels,
    ///       dimensions: sourceData.dimensions,
    ///       spacing: sourceData.spacing,
    ///       pixelFormat: sourceData.pixelFormat,
    ///       intensityRange: sourceData.intensityRange,
    ///       orientation: sourceData.orientation,
    ///       recommendedWindow: sourceData.recommendedWindow
    ///   )
    ///   ```
    public static func makeVolumeDataset(
        voxels: Data,
        dimensions: VolumetricDimensions,
        spacing: VolumetricSpacing,
        pixelFormat: VolumetricPixelFormat,
        intensityRange: ClosedRange<Int32>,
        orientation: VolumetricOrientation,
        recommendedWindow: ClosedRange<Int32>?
    ) -> VolumeDataset {
        VolumeDataset(
            data: voxels,
            dimensions: VolumeDimensions(
                width: dimensions.width,
                height: dimensions.height,
                depth: dimensions.depth
            ),
            spacing: VolumeSpacing(
                x: spacing.x,
                y: spacing.y,
                z: spacing.z
            ),
            pixelFormat: pixelFormat.toVolumePixelFormat(),
            intensityRange: intensityRange,
            orientation: VolumeOrientation(
                row: orientation.row,
                column: orientation.column,
                origin: orientation.origin
            ),
            recommendedWindow: recommendedWindow
        )
    }

    /// Convenience method for converting complete volumetric series data providers.
    ///
    /// This method provides a simpler interface when you have a complete
    /// ``VolumetricSeriesDataProvider`` and want to convert it without extracting
    /// individual properties. `VolumetricSeriesData` conforms to this contract,
    /// and app-side adapters may conform when they already expose MTKCore DTO
    /// fields.
    ///
    /// - Parameters:
    ///   - seriesData: The source volumetric series data object
    ///
    /// - Returns: A fully initialized VolumeDataset
    ///
    /// - Example:
    ///   ```swift
    ///   let seriesData = await loadVolumetricSeries()
    ///   let dataset = VolumeDatasetFactory.makeVolumeDataset(from: seriesData)
    ///   ```
    public static func makeVolumeDataset<SeriesData: VolumetricSeriesDataProvider>(
        from seriesData: SeriesData
    ) -> VolumeDataset {
        makeVolumeDataset(
            voxels: seriesData.voxels,
            dimensions: seriesData.dimensions,
            spacing: seriesData.spacing,
            pixelFormat: seriesData.pixelFormat,
            intensityRange: seriesData.intensityRange,
            orientation: seriesData.orientation,
            recommendedWindow: seriesData.recommendedWindow
        )
    }
}

// MARK: - Volumetric Series Data Provider

/// Stable MTKCore boundary for renderer-ready volumetric input.
///
/// App-side DICOM loaders keep ownership of parsing, PHI handling, ordering,
/// decompression, and rescale/window metadata. The provider exposes only the
/// scalar volume fields MTKCore needs to create a ``VolumeDataset``.
public protocol VolumetricSeriesDataProvider {
    var voxels: Data { get }
    var dimensions: VolumetricDimensions { get }
    var spacing: VolumetricSpacing { get }
    var pixelFormat: VolumetricPixelFormat { get }
    var intensityRange: ClosedRange<Int32> { get }
    var orientation: VolumetricOrientation { get }
    var recommendedWindow: ClosedRange<Int32>? { get }
}

// MARK: - Stable MTKCore Volumetric Input DTOs

/// MTKCore-owned dimensions DTO for renderer-ready volume input.
public struct VolumetricDimensions: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var depth: Int

    public init(width: Int, height: Int, depth: Int) {
        self.width = width
        self.height = height
        self.depth = depth
    }
}

/// MTKCore-owned physical spacing DTO for renderer-ready volume input.
public struct VolumetricSpacing: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// MTKCore-owned orientation DTO for renderer-ready volume input.
public struct VolumetricOrientation: Sendable, Equatable {
    public var row: SIMD3<Float>
    public var column: SIMD3<Float>
    public var origin: SIMD3<Float>

    public init(row: SIMD3<Float>, column: SIMD3<Float>, origin: SIMD3<Float>) {
        self.row = row
        self.column = column
        self.origin = origin
    }
}

/// MTKCore-owned pixel format DTO for renderer-ready volume input.
public enum VolumetricPixelFormat: Sendable, Equatable {
    case int16Signed
    case int16Unsigned

    /// Converts volumetric pixel format to MTK's VolumePixelFormat.
    public func toVolumePixelFormat() -> VolumePixelFormat {
        switch self {
        case .int16Signed:
            return .int16Signed
        case .int16Unsigned:
            return .int16Unsigned
        }
    }
}

/// Stable MTKCore DTO for complete renderer-ready volumetric series data.
///
/// Use this type when an app-side loader has already decoded and validated a
/// single scalar volume. It intentionally does not model DICOM parsing,
/// decompression, slice sorting, PHI, or PACS/networking concerns.
public struct VolumetricSeriesData: Sendable, Equatable, VolumetricSeriesDataProvider {
    public var voxels: Data
    public var dimensions: VolumetricDimensions
    public var spacing: VolumetricSpacing
    public var pixelFormat: VolumetricPixelFormat
    public var intensityRange: ClosedRange<Int32>
    public var orientation: VolumetricOrientation
    public var recommendedWindow: ClosedRange<Int32>?

    public init(
        voxels: Data,
        dimensions: VolumetricDimensions,
        spacing: VolumetricSpacing,
        pixelFormat: VolumetricPixelFormat,
        intensityRange: ClosedRange<Int32>,
        orientation: VolumetricOrientation,
        recommendedWindow: ClosedRange<Int32>? = nil
    ) {
        self.voxels = voxels
        self.dimensions = dimensions
        self.spacing = spacing
        self.pixelFormat = pixelFormat
        self.intensityRange = intensityRange
        self.orientation = orientation
        self.recommendedWindow = recommendedWindow
    }
}
