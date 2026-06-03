//
//  SurfaceMeshShading.swift
//  MTKCore
//

import Foundation

public struct SurfaceMeshShading: Sendable, Equatable {
    public var lightingEnabled: Bool
    public var ambientIntensity: Float
    public var diffuseIntensity: Float
    public var specularIntensity: Float
    public var shininess: Float

    public init(lightingEnabled: Bool = true,
                ambientIntensity: Float = 0.35,
                diffuseIntensity: Float = 0.65,
                specularIntensity: Float = 0.08,
                shininess: Float = 24) {
        self.lightingEnabled = lightingEnabled
        self.ambientIntensity = ambientIntensity
        self.diffuseIntensity = diffuseIntensity
        self.specularIntensity = specularIntensity
        self.shininess = shininess
    }

    public static let clinicalDefault = SurfaceMeshShading()
    public static let matte = SurfaceMeshShading(ambientIntensity: 0.45,
                                                 diffuseIntensity: 0.55,
                                                 specularIntensity: 0,
                                                 shininess: 8)
    public static let glossy = SurfaceMeshShading(ambientIntensity: 0.28,
                                                  diffuseIntensity: 0.72,
                                                  specularIntensity: 0.35,
                                                  shininess: 48)
    public static let unlit = SurfaceMeshShading(lightingEnabled: false,
                                                 ambientIntensity: 1,
                                                 diffuseIntensity: 0,
                                                 specularIntensity: 0,
                                                 shininess: 1)

    var clampedAmbientIntensity: Float {
        clamp(ambientIntensity, minimum: 0, maximum: 1)
    }

    var clampedDiffuseIntensity: Float {
        clamp(diffuseIntensity, minimum: 0, maximum: 2)
    }

    var clampedSpecularIntensity: Float {
        clamp(specularIntensity, minimum: 0, maximum: 1)
    }

    var clampedShininess: Float {
        clamp(shininess, minimum: 1, maximum: 128)
    }

    private func clamp(_ value: Float, minimum: Float, maximum: Float) -> Float {
        guard value.isFinite else { return minimum }
        return min(max(value, minimum), maximum)
    }
}
