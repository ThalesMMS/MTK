//
//  SampleDistanceCalculator.swift
//  MTKCore
//
//  Calculates sampling distances and provides helpers to
//  normalize them for shader use.
//

import simd

public enum SampleDistanceQuality: Float, CaseIterable, Sendable {
    case fast      = 1.0   // lowest quality / fastest
    case balanced  = 1.5
    case high      = 2.5
    case maximum   = 4.0
}

public enum SampleDistanceCalculator {
    /// Base (unnormalized) sample distance in world units (mm).
    public static func baseSampleDistance(spacing: (x: Double, y: Double, z: Double)) -> Float {
        let sx = Float(spacing.x)
        let sy = Float(spacing.y)
        let sz = Float(spacing.z)
        return 0.7 * sqrt(sx * sx + sy * sy + sz * sz)
    }

    /// Quality-scaled sample distance.
    public static func sampleDistance(spacing: (x: Double, y: Double, z: Double),
                                      quality: SampleDistanceQuality = .high) -> Float {
        let base = baseSampleDistance(spacing: spacing)
        return base / quality.rawValue
    }

    /// Normalizes a sample distance for use in the shader's unit cube.
    public static func normalizedSampleDistance(_ sampleDistance: Float,
                                                dataset: VolumeDataset) -> Float {
        let bounds = MPRCameraConfiguration.worldBounds(for: dataset)
        guard bounds.count >= 6 else { return sampleDistance }
        let dx = bounds[1] - bounds[0]
        let dy = bounds[3] - bounds[2]
        let dz = bounds[5] - bounds[4]
        let worldDiagonal = sqrt(dx * dx + dy * dy + dz * dz)
        guard worldDiagonal > .ulpOfOne else { return sampleDistance }
        return sampleDistance * sqrt(3.0) / worldDiagonal
    }
}

public extension VolumeDataset {
    /// Sample distance based on spacing and quality.
    func CompatibleSampleDistance(quality: SampleDistanceQuality = .high) -> Float {
        SampleDistanceCalculator.sampleDistance(
            spacing: (spacing.x, spacing.y, spacing.z),
            quality: quality
        )
    }

    /// Normalized sample distance ready for shader consumption.
    func normalizedSampleDistance(sampleDistance: Float,
                                  quality: SampleDistanceQuality = .high) -> Float {
        let distance = sampleDistance > 0 ? sampleDistance : CompatibleSampleDistance(quality: quality)
        return SampleDistanceCalculator.normalizedSampleDistance(distance, dataset: self)
    }
}

public extension VolumeRenderRequest.Quality {
    var sampleQuality: SampleDistanceQuality {
        switch self {
        case .preview: return .fast
        case .interactive: return .balanced
        case .production: return .high
        }
    }
}

