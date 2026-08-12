//
//  StreamedVolumeResource.swift
//  MTK
//
//  Immutable ownership token for a volume texture uploaded from slices.
//

import Foundation
@preconcurrency import Metal

/// Package-scoped GPU resource that can be adopted by multiple MTK renderers
/// without replaying its source stream or materializing a CPU voxel buffer.
/// Its state is immutable and `MTLTexture` is imported with `@preconcurrency`;
/// adding mutable state requires re-evaluating the unchecked conformance.
package final class StreamedVolumeResource: @unchecked Sendable {
    package let id: UUID
    package let texture: any MTLTexture
    package let descriptor: VolumeUploadDescriptor
    private let referenceDimensions: VolumeDimensions
    private let referenceSpacing: VolumeSpacing
    private let referenceOrientation: VolumeOrientation
    private let referenceIntensityRange: ClosedRange<Int32>

    package init(id: UUID = UUID(),
                 texture: any MTLTexture,
                 descriptor: VolumeUploadDescriptor,
                 referenceDataset: VolumeDataset) throws {
        try Self.validate(descriptor: descriptor, referenceDataset: referenceDataset)
        self.id = id
        self.texture = texture
        self.descriptor = descriptor
        self.referenceDimensions = referenceDataset.dimensions
        self.referenceSpacing = referenceDataset.spacing
        self.referenceOrientation = referenceDataset.orientation
        self.referenceIntensityRange = referenceDataset.intensityRange
    }

    package func matches(dataset: VolumeDataset) -> Bool {
        dataset.dimensions == referenceDimensions &&
            dataset.spacing == referenceSpacing &&
            dataset.orientation == referenceOrientation &&
            dataset.pixelFormat == .int16Signed &&
            dataset.intensityRange == referenceIntensityRange
    }

    package static func validate(
        descriptor: VolumeUploadDescriptor,
        referenceDataset: VolumeDataset
    ) throws {
        guard descriptor.dimensions == referenceDataset.dimensions,
              descriptor.spacing == referenceDataset.spacing,
              descriptor.orientation == referenceDataset.orientation,
              referenceDataset.pixelFormat == .int16Signed,
              descriptor.intensityRange == referenceDataset.intensityRange else {
            throw StreamedVolumeResourceError.referenceMetadataMismatch
        }
    }
}
