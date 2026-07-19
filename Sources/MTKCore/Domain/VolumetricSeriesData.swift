import Foundation

/// Stable MTKCore DTO for complete renderer-ready volumetric series data.
///
/// Use this type when an app-side loader has already decoded and validated a
/// single scalar volume. It intentionally does not model DICOM parsing,
/// decompression, slice sorting, PHI, or PACS/networking concerns.
public struct VolumetricSeriesData: Sendable, Equatable, VolumetricSeriesDataProvider {
    public var voxels: Data
    public var dimensions: VolumetricDimensions
    public var spacing: VolumetricSpacing
    public var isInPlaneSpacingCalibrated: Bool
    public var isOrientationVerified: Bool
    public var pixelFormat: VolumetricPixelFormat
    public var intensityRange: ClosedRange<Int32>
    public var orientation: VolumetricOrientation
    public var recommendedWindow: ClosedRange<Int32>?

    public init(
        voxels: Data,
        dimensions: VolumetricDimensions,
        spacing: VolumetricSpacing,
        isInPlaneSpacingCalibrated: Bool = false,
        isOrientationVerified: Bool = false,
        pixelFormat: VolumetricPixelFormat,
        intensityRange: ClosedRange<Int32>,
        orientation: VolumetricOrientation,
        recommendedWindow: ClosedRange<Int32>? = nil
    ) {
        self.voxels = voxels
        self.dimensions = dimensions
        self.spacing = spacing
        self.isInPlaneSpacingCalibrated = isInPlaneSpacingCalibrated
        self.isOrientationVerified = isOrientationVerified
        self.pixelFormat = pixelFormat
        self.intensityRange = intensityRange
        self.orientation = orientation
        self.recommendedWindow = recommendedWindow
    }
}
