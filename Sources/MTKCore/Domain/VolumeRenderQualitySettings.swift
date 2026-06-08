//
//  VolumeRenderQualitySettings.swift
//  MTKCore
//
//  Public quality contract for 3D volume rendering controls.
//

import Foundation

public enum VolumeRenderQualityOption: String, CaseIterable, Codable, Identifiable, Sendable {
    case low
    case medium
    case high
    case fantastic

    public var id: String { rawValue }

    public var sampleCount: Float {
        switch self {
        case .low:
            return 256
        case .medium:
            return 512
        case .high:
            return 768
        case .fantastic:
            return 1_024
        }
    }

    public var depthGradientScale: Float {
        switch self {
        case .low:
            return 2.0
        case .medium:
            return 1.5
        case .high:
            return 1.0
        case .fantastic:
            return 0.75
        }
    }
}

public enum VolumeRenderIterationQuality: String, CaseIterable, Codable, Identifiable, Sendable {
    case low
    case medium
    case high

    public var id: String { rawValue }

    public var sampleMultiplier: Float {
        switch self {
        case .low:
            return 0.75
        case .medium:
            return 1.0
        case .high:
            return 1.25
        }
    }
}

public enum VolumeShadowMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case off
    case hard
    case soft

    public var id: String { rawValue }

    public var shaderValue: Int32 {
        switch self {
        case .off:
            return 0
        case .hard:
            return 1
        case .soft:
            return 2
        }
    }

    public var isEnabled: Bool {
        self != .off
    }
}

public struct VolumeRenderQualitySettings: Codable, Equatable, Sendable {
    public static let `default` = VolumeRenderQualitySettings(
        renderResolution: .high,
        interactingResolution: .medium,
        depthResolution: .high,
        iterations: .medium,
        shadowMode: .off,
        disableShadowsWhenInteracting: false,
        directionalLightIntensity: 1.0,
        ambientLightIntensity: 0.2
    )

    public var renderResolution: VolumeRenderQualityOption
    public var interactingResolution: VolumeRenderQualityOption
    public var depthResolution: VolumeRenderQualityOption
    public var iterations: VolumeRenderIterationQuality
    public var shadowMode: VolumeShadowMode
    public var disableShadowsWhenInteracting: Bool
    public var directionalLightIntensity: Double
    public var ambientLightIntensity: Double

    public init(renderResolution: VolumeRenderQualityOption = Self.default.renderResolution,
                interactingResolution: VolumeRenderQualityOption = Self.default.interactingResolution,
                depthResolution: VolumeRenderQualityOption = Self.default.depthResolution,
                iterations: VolumeRenderIterationQuality = Self.default.iterations,
                shadowMode: VolumeShadowMode = Self.default.shadowMode,
                disableShadowsWhenInteracting: Bool = Self.default.disableShadowsWhenInteracting,
                directionalLightIntensity: Double = Self.default.directionalLightIntensity,
                ambientLightIntensity: Double = Self.default.ambientLightIntensity) {
        self.renderResolution = renderResolution
        self.interactingResolution = interactingResolution
        self.depthResolution = depthResolution
        self.iterations = iterations
        self.shadowMode = shadowMode
        self.disableShadowsWhenInteracting = disableShadowsWhenInteracting
        self.directionalLightIntensity = directionalLightIntensity
        self.ambientLightIntensity = ambientLightIntensity
    }

    public var sanitized: VolumeRenderQualitySettings {
        var copy = self
        copy.directionalLightIntensity = Self.clamp(directionalLightIntensity, lower: 0, upper: 2)
        copy.ambientLightIntensity = Self.clamp(ambientLightIntensity, lower: 0, upper: 1)
        return copy
    }

    public var finalSamplingStep: Float {
        max(1, renderResolution.sampleCount * iterations.sampleMultiplier)
    }

    public var interactingSamplingStep: Float {
        max(1, interactingResolution.sampleCount * iterations.sampleMultiplier)
    }

    public var interactionSamplingFactor: Float {
        let ratio = interactingSamplingStep / finalSamplingStep
        return VolumetricMath.clampFloat(ratio, lower: 0.1, upper: 1)
    }

    public var depthGradientScale: Float {
        depthResolution.depthGradientScale
    }

    public func effectiveShadowMode(for quality: VolumeRenderRequest.Quality) -> VolumeShadowMode {
        guard shadowMode.isEnabled else { return .off }
        if disableShadowsWhenInteracting, quality != .production {
            return .off
        }
        return directionalLightIntensity > 0 ? shadowMode : .off
    }

    public func lightingEnabled(for quality: VolumeRenderRequest.Quality) -> Bool {
        _ = quality
        return directionalLightIntensity > 0 || ambientLightIntensity > 0
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        guard value.isFinite else { return lower }
        return min(max(value, lower), upper)
    }
}
