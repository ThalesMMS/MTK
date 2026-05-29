//
//  VolumeDataset.swift
//  MTK
//
//  Core volumetric data structures shared across MTK rendering modules.
//  Keeps dataset exchange independent from application targets.
//

import Foundation
import simd

/// Spatial orientation of a volumetric dataset in 3D space.
///
/// Defines the directional vectors and origin point for mapping voxel coordinates
/// to patient/world space in millimeters. Used to correctly position and orient medical imaging
/// volumes during rendering and multi-planar reconstruction.
///
/// The row and column vectors define the orientation of the image plane, while the
/// origin specifies the position of the first voxel in patient/world coordinates.
public struct VolumeOrientation: Sendable, Equatable {
    /// Direction vector for the row axis (typically left-to-right in patient space).
    public var row: SIMD3<Float>

    /// Direction vector for the column axis (typically top-to-bottom in patient space).
    public var column: SIMD3<Float>

    /// Position of the first voxel in patient/world coordinates, in millimeters.
    public var origin: SIMD3<Float>

    /// Creates a new volume orientation with the specified directional vectors and origin.
    ///
    /// - Parameters:
    ///   - row: Direction vector for the row axis
    ///   - column: Direction vector for the column axis
    ///   - origin: Position of the first voxel in patient/world coordinates, in millimeters
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
    /// - Origin: `(0, 0, 0)` — patient/world space origin
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

/// Physical spacing between adjacent voxel centers in millimeters.
///
/// Defines the real-world distance between voxel centers along each axis.
/// Essential for accurate physical measurements, aspect ratio correction,
/// and proper scaling during visualization of medical imaging data.
///
/// Values are typically in the range of 0.1 to 10 millimeters for medical CT
/// and MR imaging.
public struct VolumeSpacing: Sendable, Equatable {
    /// Spacing between voxels along the X axis in millimeters.
    public var x: Double

    /// Spacing between voxels along the Y axis in millimeters.
    public var y: Double

    /// Spacing between voxels along the Z axis in millimeters.
    public var z: Double

    /// Creates new volume spacing with the specified distances.
    ///
    /// - Parameters:
    ///   - x: Spacing along the X axis in millimeters
    ///   - y: Spacing along the Y axis in millimeters
    ///   - z: Spacing along the Z axis in millimeters
    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public extension VolumeSpacing {
    /// Creates spacing values that are already expressed in millimeters.
    static func millimeters(x: Double, y: Double, z: Double) -> VolumeSpacing {
        VolumeSpacing(x: x, y: y, z: z)
    }

    /// Creates spacing values from meters, converting to millimeters for MTKCore.
    static func meters(x: Double, y: Double, z: Double) -> VolumeSpacing {
        VolumeSpacing(x: x * 1_000, y: y * 1_000, z: z * 1_000)
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

    /// Whether this scalar format stores signed integer values.
    public var isSigned: Bool {
        switch self {
        case .int16Signed:
            return true
        case .int16Unsigned:
            return false
        }
    }

    /// Number of bits in one scalar component.
    public var bitsPerScalar: Int {
        16
    }

    /// Human-readable scalar family for this voxel format.
    public var scalarTypeDescription: String {
        switch self {
        case .int16Signed:
            return "Int16"
        case .int16Unsigned:
            return "UInt16"
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

/// UI-independent clinical metadata associated with structured volume data.
public struct ClinicalImageMetadata: Sendable, Equatable {
    public var patientName: String?
    public var modality: String?
    public var studyDescription: String?
    public var seriesDescription: String?
    public var studyInstanceUID: String?
    public var seriesInstanceUID: String?
    public var frameOfReferenceUID: String?
    public var rescaleSlope: Double?
    public var rescaleIntercept: Double?
    public var sourcePixelFormat: VolumePixelFormat?
    public var windowCenter: Double?
    public var windowWidth: Double?

    public init(patientName: String? = nil,
                modality: String? = nil,
                studyDescription: String? = nil,
                seriesDescription: String? = nil,
                studyInstanceUID: String? = nil,
                seriesInstanceUID: String? = nil,
                frameOfReferenceUID: String? = nil,
                rescaleSlope: Double? = nil,
                rescaleIntercept: Double? = nil,
                sourcePixelFormat: VolumePixelFormat? = nil,
                windowCenter: Double? = nil,
                windowWidth: Double? = nil) {
        self.patientName = patientName
        self.modality = modality
        self.studyDescription = studyDescription
        self.seriesDescription = seriesDescription
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.frameOfReferenceUID = frameOfReferenceUID
        self.rescaleSlope = rescaleSlope
        self.rescaleIntercept = rescaleIntercept
        self.sourcePixelFormat = sourcePixelFormat
        self.windowCenter = windowCenter
        self.windowWidth = windowWidth
    }
}

/// Canonical structured 3D image metadata and affine transform contract.
///
/// `ImageData3D` is MTKCore's structured metadata model for scalar medical
/// volumes. Index/voxel space is continuous, with `(0, 0, 0)` at the
/// center of the first voxel. World space is DICOM-style patient/world space in
/// millimeters. Texture space is normalized `[0, 1]^3` and uses the center offset
/// `(index + 0.5) / dimensions` for sampling.
public struct ImageData3D: Sendable {
    public var dimensions: VolumeDimensions
    public var spacing: VolumeSpacing
    public var origin: SIMD3<Float>
    public var direction: simd_float3x3
    public var pixelFormat: VolumePixelFormat
    public var componentsPerVoxel: Int
    public var intensityRange: ClosedRange<Int32>
    public var recommendedWindow: ClosedRange<Int32>?
    public var clinicalMetadata: ClinicalImageMetadata?

    public init(dimensions: VolumeDimensions,
                spacing: VolumeSpacing,
                origin: SIMD3<Float>,
                direction: simd_float3x3,
                pixelFormat: VolumePixelFormat,
                componentsPerVoxel: Int = 1,
                intensityRange: ClosedRange<Int32>? = nil,
                recommendedWindow: ClosedRange<Int32>? = nil,
                clinicalMetadata: ClinicalImageMetadata? = nil) {
        precondition(componentsPerVoxel == 1,
                     "ImageData3D v1 supports only one scalar component per voxel; got \(componentsPerVoxel).")
        self.dimensions = dimensions
        self.spacing = spacing
        self.origin = origin
        self.direction = direction
        self.pixelFormat = pixelFormat
        self.componentsPerVoxel = componentsPerVoxel
        self.intensityRange = intensityRange ?? pixelFormat.defaultIntensityRange
        self.recommendedWindow = recommendedWindow
        self.clinicalMetadata = clinicalMetadata
    }

    public init(dimensions: VolumeDimensions,
                spacing: VolumeSpacing,
                orientation: VolumeOrientation,
                pixelFormat: VolumePixelFormat,
                componentsPerVoxel: Int = 1,
                intensityRange: ClosedRange<Int32>? = nil,
                recommendedWindow: ClosedRange<Int32>? = nil,
                clinicalMetadata: ClinicalImageMetadata? = nil) {
        let normal = ImageData3D.normalizedCross(orientation.row,
                                                 orientation.column,
                                                 fallback: SIMD3<Float>(0, 0, 1))
        self.init(dimensions: dimensions,
                  spacing: spacing,
                  origin: orientation.origin,
                  direction: simd_float3x3(columns: (orientation.row, orientation.column, normal)),
                  pixelFormat: pixelFormat,
                  componentsPerVoxel: componentsPerVoxel,
                  intensityRange: intensityRange,
                  recommendedWindow: recommendedWindow,
                  clinicalMetadata: clinicalMetadata)
    }

    /// Direction of increasing column/index-x values in patient/world space.
    public var rowDirection: SIMD3<Float> { direction.columns.0 }

    /// Direction of increasing row/index-y values in patient/world space.
    public var columnDirection: SIMD3<Float> { direction.columns.1 }

    /// Direction of increasing slice/index-z values in patient/world space.
    public var sliceDirection: SIMD3<Float> { direction.columns.2 }

    /// Number of bytes for one voxel, including all scalar components.
    public var bytesPerVoxel: Int {
        pixelFormat.bytesPerVoxel * componentsPerVoxel
    }

    /// Compatibility orientation view derived from the canonical affine contract.
    public var orientation: VolumeOrientation {
        get {
            VolumeOrientation(row: rowDirection, column: columnDirection, origin: origin)
        }
        set {
            origin = newValue.origin
            let normal = ImageData3D.normalizedCross(newValue.row,
                                                     newValue.column,
                                                     fallback: sliceDirection)
            direction = simd_float3x3(columns: (newValue.row, newValue.column, normal))
        }
    }

    /// Matrix mapping continuous voxel/index coordinates to world coordinates in millimeters.
    public var indexToWorld: simd_float4x4 {
        let xAxis = rowDirection * Float(spacing.x)
        let yAxis = columnDirection * Float(spacing.y)
        let zAxis = sliceDirection * Float(spacing.z)
        return simd_float4x4(columns: (
            simd_float4(xAxis.x, xAxis.y, xAxis.z, 0),
            simd_float4(yAxis.x, yAxis.y, yAxis.z, 0),
            simd_float4(zAxis.x, zAxis.y, zAxis.z, 0),
            simd_float4(origin.x, origin.y, origin.z, 1)
        ))
    }

    /// Matrix mapping world coordinates in millimeters back to continuous voxel/index space.
    public var worldToIndex: simd_float4x4 {
        simd_inverse(indexToWorld)
    }

    /// Matrix mapping continuous voxel/index coordinates to normalized texture coordinates.
    public var voxelToTexture: simd_float4x4 {
        precondition(dimensions.width > 0 && dimensions.height > 0 && dimensions.depth > 0,
                     "ImageData3D.voxelToTexture requires positive dimensions; got \(dimensions).")
        let width = Float(dimensions.width)
        let height = Float(dimensions.height)
        let depth = Float(dimensions.depth)
        return simd_float4x4(columns: (
            simd_float4(1 / width, 0, 0, 0),
            simd_float4(0, 1 / height, 0, 0),
            simd_float4(0, 0, 1 / depth, 0),
            simd_float4(0.5 / width, 0.5 / height, 0.5 / depth, 1)
        ))
    }

    /// Matrix mapping world coordinates in millimeters to normalized texture coordinates.
    public var worldToTexture: simd_float4x4 {
        voxelToTexture * worldToIndex
    }

    static func normalizedCross(_ lhs: SIMD3<Float>,
                                _ rhs: SIMD3<Float>,
                                fallback: SIMD3<Float>) -> SIMD3<Float> {
        let cross = simd_cross(lhs, rhs)
        let length = simd_length(cross)
        if length > Float.ulpOfOne {
            return cross / length
        }
        let fallbackLength = simd_length(fallback)
        if fallbackLength > Float.ulpOfOne {
            return fallback / fallbackLength
        }
        return SIMD3<Float>(0, 0, 1)
    }
}

extension ImageData3D: Equatable {
    public static func == (lhs: ImageData3D, rhs: ImageData3D) -> Bool {
        lhs.dimensions == rhs.dimensions &&
            lhs.spacing == rhs.spacing &&
            lhs.origin == rhs.origin &&
            lhs.direction.columns.0 == rhs.direction.columns.0 &&
            lhs.direction.columns.1 == rhs.direction.columns.1 &&
            lhs.direction.columns.2 == rhs.direction.columns.2 &&
            lhs.pixelFormat == rhs.pixelFormat &&
            lhs.componentsPerVoxel == rhs.componentsPerVoxel &&
            lhs.intensityRange == rhs.intensityRange &&
            lhs.recommendedWindow == rhs.recommendedWindow &&
            lhs.clinicalMetadata == rhs.clinicalMetadata
    }
}

/// Complete 3D volumetric dataset with voxel data and metadata.
///
/// Represents a medical imaging volume (CT, MR, etc.) with raw voxel intensity data
/// and all metadata required for correct rendering, measurements, and spatial analysis.
/// The canonical structured-image contract is exposed through ``imageData``.
///
/// ## Usage
/// Create a dataset from raw voxel data:
/// ```swift
/// let voxels = Data(/* raw 16-bit voxel buffer */)
/// let dataset = VolumeDataset(
///     data: voxels,
///     dimensions: VolumeDimensions(width: 512, height: 512, depth: 300),
///     spacing: VolumeSpacing(x: 0.7, y: 0.7, z: 1.0),
///     pixelFormat: .int16Signed,
///     intensityRange: -1024...3071
/// )
/// ```
///
/// The dataset can then be uploaded to Metal textures via `VolumeTextureFactory`
/// and rendered using the Metal adapters in this package.
public struct VolumeDataset: Sendable, Equatable {
    /// Raw voxel intensity data.
    ///
    /// Packed binary buffer containing voxel intensities in the format specified by `pixelFormat`.
    /// Size must equal `dimensions.voxelCount * pixelFormat.bytesPerVoxel`.
    public var data: Data

    /// Canonical structured image metadata and affine transform contract.
    public var imageData: ImageData3D

    /// Volume dimensions in voxels.
    public var dimensions: VolumeDimensions {
        get { imageData.dimensions }
        set { imageData.dimensions = newValue }
    }

    /// Physical spacing between voxel centers in millimeters.
    public var spacing: VolumeSpacing {
        get { imageData.spacing }
        set { imageData.spacing = newValue }
    }

    /// Format of voxel intensity values in the data buffer.
    public var pixelFormat: VolumePixelFormat {
        get { imageData.pixelFormat }
        set { imageData.pixelFormat = newValue }
    }

    /// Spatial orientation in 3D space.
    public var orientation: VolumeOrientation {
        get { imageData.orientation }
        set { imageData.orientation = newValue }
    }

    /// Actual range of intensity values present in the volume.
    ///
    /// May be narrower than the full representable range of `pixelFormat`.
    /// Used to optimize transfer function mapping and histogram calculations.
    public var intensityRange: ClosedRange<Int32> {
        get { imageData.intensityRange }
        set { imageData.intensityRange = newValue }
    }

    /// Suggested window/level range for initial display.
    ///
    /// Optional preset window that provides good default visualization for this dataset type.
    /// For example, CT chest scans might recommend a lung window (-600 to 1500 HU).
    public var recommendedWindow: ClosedRange<Int32>? {
        get { imageData.recommendedWindow }
        set { imageData.recommendedWindow = newValue }
    }

    /// Creates a new volumetric dataset.
    ///
    /// - Parameters:
    ///   - data: Raw voxel buffer (size must match `dimensions.voxelCount * pixelFormat.bytesPerVoxel`)
    ///   - dimensions: Volume size in voxels
    ///   - spacing: Physical distance between voxel centers in millimeters
    ///   - pixelFormat: Format of voxel values in the data buffer
    ///   - intensityRange: Actual intensity range in the data (defaults to `pixelFormat.defaultIntensityRange`)
    ///   - orientation: Spatial orientation (defaults to `.canonical`)
    ///   - recommendedWindow: Suggested display window range (optional)
    ///   - clinicalMetadata: Optional UI-independent clinical metadata
    public init(data: Data,
                dimensions: VolumeDimensions,
                spacing: VolumeSpacing,
                pixelFormat: VolumePixelFormat,
                intensityRange: ClosedRange<Int32>? = nil,
                orientation: VolumeOrientation? = nil,
                recommendedWindow: ClosedRange<Int32>? = nil,
                clinicalMetadata: ClinicalImageMetadata? = nil) {
        self.data = data
        self.imageData = ImageData3D(dimensions: dimensions,
                                     spacing: spacing,
                                     orientation: orientation ?? .canonical,
                                     pixelFormat: pixelFormat,
                                     intensityRange: intensityRange,
                                     recommendedWindow: recommendedWindow,
                                     clinicalMetadata: clinicalMetadata)
    }

    public init(data: Data, imageData: ImageData3D) {
        self.data = data
        self.imageData = imageData
    }

    /// Total number of voxels in the dataset.
    ///
    /// Convenience accessor for `dimensions.voxelCount`.
    public var voxelCount: Int {
        dimensions.voxelCount
    }

    /// Physical dimensions of the volume in millimeters.
    ///
    /// Computed as element-wise product of `spacing` and `dimensions`.
    /// Returns the full extent of the volume in real-world coordinates:
    /// - `x = spacing.x * dimensions.width`
    /// - `y = spacing.y * dimensions.height`
    /// - `z = spacing.z * dimensions.depth`
    ///
    /// Use this to scale spatial geometry or compute bounding boxes.
    public var scale: VolumeSpacing {
        VolumeSpacing(
            x: spacing.x * Double(dimensions.width),
            y: spacing.y * Double(dimensions.height),
            z: spacing.z * Double(dimensions.depth)
        )
    }
}
