//
//  VolumetricSeriesDataProvider.swift
//  MTKCore
//
//  Defines the input contract for decoded scalar volumes supplied by application-side
//  loaders.
//
//  Thales Matheus Mendonça Santos — July 2026
//

import Foundation

/// Stable MTKCore boundary for renderer-ready volumetric input.
///
/// App-side DICOM loaders keep ownership of parsing, PHI handling, ordering,
/// decompression, and rescale/window metadata. The provider exposes only the
/// scalar volume fields MTKCore needs to create a ``VolumeDataset``.
public protocol VolumetricSeriesDataProvider {
    var voxels: Data { get }
    var dimensions: VolumetricDimensions { get }
    var spacing: VolumetricSpacing { get }
    var isInPlaneSpacingCalibrated: Bool { get }
    var isOrientationVerified: Bool { get }
    var pixelFormat: VolumetricPixelFormat { get }
    var intensityRange: ClosedRange<Int32> { get }
    var orientation: VolumetricOrientation { get }
    var recommendedWindow: ClosedRange<Int32>? { get }
}

public extension VolumetricSeriesDataProvider {
    var isInPlaneSpacingCalibrated: Bool { false }
    var isOrientationVerified: Bool { false }
}
