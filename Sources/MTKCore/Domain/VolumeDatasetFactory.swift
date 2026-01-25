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

/// Factory for creating VolumeDataset instances from volumetric series data.
/// Manages type conversion and data transformation from legacy Isis structures
/// to MTK's standardized VolumeDataset format.
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

    /// Convenience method for converting complete volumetric series data objects.
    ///
    /// This method provides a simpler interface when you have a complete
    /// VolumetricSeriesData object and want to convert it without extracting
    /// individual properties.
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
    public static func makeVolumeDataset(from seriesData: VolumetricSeriesData) -> VolumeDataset {
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

// MARK: - Type Conversion Extensions

/// Protocol requirements for volumetric series data input.
/// Any source format must provide these properties for dataset conversion.
public protocol VolumetricSeriesDataProvider {
    associatedtype DimensionType
    associatedtype SpacingType
    associatedtype PixelFormatType
    associatedtype OrientationType

    var voxels: Data { get }
    var dimensions: DimensionType { get }
    var spacing: SpacingType { get }
    var pixelFormat: PixelFormatType { get }
    var intensityRange: ClosedRange<Int32> { get }
    var orientation: OrientationType { get }
    var recommendedWindow: ClosedRange<Int32>? { get }
}

// MARK: - Internal Type Definitions (placeholders for external types)

/// Represents 3D volumetric dimensions.
/// This is a placeholder; replace with actual VolumetricSeriesData structure from Isis.
public struct VolumetricDimensions {
    public var width: Int
    public var height: Int
    public var depth: Int

    public init(width: Int, height: Int, depth: Int) {
        self.width = width
        self.height = height
        self.depth = depth
    }
}

/// Represents physical spacing between voxels.
/// This is a placeholder; replace with actual spacing structure from Isis.
public struct VolumetricSpacing {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// Represents volumetric orientation in space.
/// This is a placeholder; replace with actual orientation structure from Isis.
public struct VolumetricOrientation {
    public var row: SIMD3<Float>
    public var column: SIMD3<Float>
    public var origin: SIMD3<Float>

    public init(row: SIMD3<Float>, column: SIMD3<Float>, origin: SIMD3<Float>) {
        self.row = row
        self.column = column
        self.origin = origin
    }
}

/// Pixel format enumeration for volumetric data.
/// This is a placeholder; replace with actual format type from Isis.
public enum VolumetricPixelFormat {
    case int16Signed
    case int16Unsigned

    /// Converts volumetric pixel format to MTK's VolumePixelFormat.
    func toVolumePixelFormat() -> VolumePixelFormat {
        switch self {
        case .int16Signed:
            return .int16Signed
        case .int16Unsigned:
            return .int16Unsigned
        }
    }
}

/// Represents complete volumetric series data.
/// This is a placeholder; replace with actual VolumetricSeriesData structure from Isis.
public struct VolumetricSeriesData: VolumetricSeriesDataProvider {
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
