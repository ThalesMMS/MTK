//
//  VolumeDataset.swift
//  MTK
//
//  Core volumetric data structures shared across volume rendering stacks.
//  Mirrors the legacy DomainPorts module so clients can exchange datasets
//  without depending on the application targets.
//

import Foundation
import simd

/// Spatial orientation of a volumetric dataset in 3D space.
///
/// Defines the directional vectors and origin point for mapping voxel coordinates
/// to patient or world space. Used to correctly position and orient medical imaging
/// volumes during rendering and multi-planar reconstruction.
///
/// The row and column vectors define the orientation of the image plane, while the
/// origin specifies the position of the first voxel in world coordinates.
public struct VolumeOrientation: Sendable, Equatable {
    /// Direction vector for the row axis (typically left-to-right in patient space).
    public var row: SIMD3<Float>

    /// Direction vector for the column axis (typically top-to-bottom in patient space).
    public var column: SIMD3<Float>

    /// Position of the first voxel in world coordinates.
    public var origin: SIMD3<Float>

    /// Creates a new volume orientation with the specified directional vectors and origin.
    ///
    /// - Parameters:
    ///   - row: Direction vector for the row axis
    ///   - column: Direction vector for the column axis
    ///   - origin: Position of the first voxel in world coordinates
    public init(row: SIMD3<Float>, column: SIMD3<Float>, origin: SIMD3<Float>) {
        self.row = row
        self.column = column
        self.origin = origin
    }
}

public extension VolumeOrientation {
    /// Default orientation with axis-aligned directional vectors and origin at zero.
    ///
    /// Used as the fallback orientation when no specific patient orientation is provided.
    /// - Row axis: `(1, 0, 0)` — aligned with X-axis
    /// - Column axis: `(0, 1, 0)` — aligned with Y-axis
    /// - Origin: `(0, 0, 0)` — world space origin
    static let canonical = VolumeOrientation(
        row: SIMD3<Float>(1, 0, 0),
        column: SIMD3<Float>(0, 1, 0),
        origin: .zero
    )
}

/// Dimensions of a volumetric dataset in voxels.
///
/// Represents the size of a 3D volume in discrete voxel units along each axis.
/// Used to define the resolution of medical imaging volumes for texture allocation
/// and coordinate mapping.
public struct VolumeDimensions: Sendable, Equatable {
    /// Number of voxels along the width (X) axis.
    public var width: Int

    /// Number of voxels along the height (Y) axis.
    public var height: Int

    /// Number of voxels along the depth (Z) axis.
    public var depth: Int

    /// Creates new volume dimensions with the specified voxel counts.
    ///
    /// - Parameters:
    ///   - width: Number of voxels along the X axis
    ///   - height: Number of voxels along the Y axis
    ///   - depth: Number of voxels along the Z axis
    public init(width: Int, height: Int, depth: Int) {
        self.width = width
        self.height = height
        self.depth = depth
    }

    /// Total number of voxels in the volume.
    ///
    /// Computed as `width × height × depth`. Use this to validate buffer sizes
    /// and allocate storage for volume data.
    public var voxelCount: Int {
        width * height * depth
    }
}

/// Physical spacing between adjacent voxels in meters.
///
/// Defines the real-world distance between voxel centers along each axis.
/// Essential for accurate physical measurements, aspect ratio correction,
/// and proper scaling during visualization of medical imaging data.
///
/// Values are typically in the range of 0.0001 to 0.01 meters (0.1mm to 10mm)
/// for medical CT and MR imaging.
public struct VolumeSpacing: Sendable, Equatable {
    /// Spacing between voxels along the X axis in meters.
    public var x: Double

    /// Spacing between voxels along the Y axis in meters.
    public var y: Double

    /// Spacing between voxels along the Z axis in meters.
    public var z: Double

    /// Creates new volume spacing with the specified distances.
    ///
    /// - Parameters:
    ///   - x: Spacing along the X axis in meters
    ///   - y: Spacing along the Y axis in meters
    ///   - z: Spacing along the Z axis in meters
    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// Pixel data format for volumetric datasets.
///
/// Defines the bit depth and signedness of voxel intensity values.
/// Used to correctly interpret raw volume data and configure Metal texture formats
/// for GPU-accelerated rendering.
public enum VolumePixelFormat: Sendable, Equatable {
    /// Signed 16-bit integer voxel values (range: -32768 to 32767).
    ///
    /// Common format for CT imaging where Hounsfield units can be negative
    /// (e.g., air = -1000, water = 0, bone = +1000).
    case int16Signed

    /// Unsigned 16-bit integer voxel values (range: 0 to 65535).
    ///
    /// Common format for MR imaging and some CT scanners that apply
    /// a positive offset to intensity values.
    case int16Unsigned

    /// Number of bytes required to store a single voxel.
    ///
    /// Returns `2` for all 16-bit formats. Use this to calculate total
    /// buffer size as `dimensions.voxelCount * bytesPerVoxel`.
    public var bytesPerVoxel: Int {
        switch self {
        case .int16Signed, .int16Unsigned:
            return MemoryLayout<UInt16>.size
        }
    }

    /// Default intensity range for this pixel format.
    ///
    /// Provides the full representable range of intensity values:
    /// - `.int16Signed`: -32768...32767
    /// - `.int16Unsigned`: 0...65535
    ///
    /// Used as fallback when no explicit intensity range is provided during dataset creation.
    public var defaultIntensityRange: ClosedRange<Int32> {
        switch self {
        case .int16Signed:
            let minValue = Int32(Int16.min)
            let maxValue = Int32(Int16.max)
            return minValue...maxValue
        case .int16Unsigned:
            let minValue = Int32(UInt16.min)
            let maxValue = Int32(UInt16.max)
            return minValue...maxValue
        }
    }
}

/// Complete 3D volumetric dataset with voxel data and metadata.
///
/// Represents a medical imaging volume (CT, MR, etc.) with raw voxel intensity data
/// and all metadata required for correct rendering, measurements, and spatial analysis.
///
/// ## Usage
/// Create a dataset from raw voxel data:
/// ```swift
/// let voxels = Data(/* raw 16-bit voxel buffer */)
/// let dataset = VolumeDataset(
///     data: voxels,
///     dimensions: VolumeDimensions(width: 512, height: 512, depth: 300),
///     spacing: VolumeSpacing(x: 0.0007, y: 0.0007, z: 0.001),
///     pixelFormat: .int16Signed,
///     intensityRange: -1024...3071
/// )
/// ```
///
/// The dataset can then be uploaded to Metal textures via `VolumeTextureFactory`
/// and rendered using `MetalRaycaster` or SceneKit volume materials.
public struct VolumeDataset: Sendable, Equatable {
    /// Raw voxel intensity data.
    ///
    /// Packed binary buffer containing voxel intensities in the format specified by `pixelFormat`.
    /// Size must equal `dimensions.voxelCount * pixelFormat.bytesPerVoxel`.
    public var data: Data

    /// Volume dimensions in voxels.
    public var dimensions: VolumeDimensions

    /// Physical spacing between voxels in meters.
    public var spacing: VolumeSpacing

    /// Format of voxel intensity values in the data buffer.
    public var pixelFormat: VolumePixelFormat

    /// Spatial orientation in 3D space.
    public var orientation: VolumeOrientation

    /// Actual range of intensity values present in the volume.
    ///
    /// May be narrower than the full representable range of `pixelFormat`.
    /// Used to optimize transfer function mapping and histogram calculations.
    public var intensityRange: ClosedRange<Int32>

    /// Suggested window/level range for initial display.
    ///
    /// Optional preset window that provides good default visualization for this dataset type.
    /// For example, CT chest scans might recommend a lung window (-600 to 1500 HU).
    public var recommendedWindow: ClosedRange<Int32>?

    /// Creates a new volumetric dataset.
    ///
    /// - Parameters:
    ///   - data: Raw voxel buffer (size must match `dimensions.voxelCount * pixelFormat.bytesPerVoxel`)
    ///   - dimensions: Volume size in voxels
    ///   - spacing: Physical distance between voxel centers in meters
    ///   - pixelFormat: Format of voxel values in the data buffer
    ///   - intensityRange: Actual intensity range in the data (defaults to `pixelFormat.defaultIntensityRange`)
    ///   - orientation: Spatial orientation (defaults to `.canonical`)
    ///   - recommendedWindow: Suggested display window range (optional)
    public init(data: Data,
                dimensions: VolumeDimensions,
                spacing: VolumeSpacing,
                pixelFormat: VolumePixelFormat,
                intensityRange: ClosedRange<Int32>? = nil,
                orientation: VolumeOrientation? = nil,
                recommendedWindow: ClosedRange<Int32>? = nil) {
        self.data = data
        self.dimensions = dimensions
        self.spacing = spacing
        self.pixelFormat = pixelFormat
        self.intensityRange = intensityRange ?? pixelFormat.defaultIntensityRange
        self.orientation = orientation ?? .canonical
        self.recommendedWindow = recommendedWindow
    }

    /// Total number of voxels in the dataset.
    ///
    /// Convenience accessor for `dimensions.voxelCount`.
    public var voxelCount: Int {
        dimensions.voxelCount
    }

    /// Physical dimensions of the volume in meters.
    ///
    /// Computed as element-wise product of `spacing` and `dimensions`.
    /// Returns the full extent of the volume in real-world coordinates:
    /// - `x = spacing.x * dimensions.width`
    /// - `y = spacing.y * dimensions.height`
    /// - `z = spacing.z * dimensions.depth`
    ///
    /// Use this to set SceneKit node scales or compute bounding boxes.
    public var scale: VolumeSpacing {
        VolumeSpacing(
            x: spacing.x * Double(dimensions.width),
            y: spacing.y * Double(dimensions.height),
            z: spacing.z * Double(dimensions.depth)
        )
    }
}
