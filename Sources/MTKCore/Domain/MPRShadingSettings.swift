//
//  MPRShadingSettings.swift
//  MTK
//
//  Presentation-stage lighting controls for MPR images.
//

import Foundation

public struct MPRShadingSettings: Codable, Equatable, Sendable {
    public static let componentRange: ClosedRange<Float> = 0...1

    public var isEnabled: Bool
    public var ambient: Float
    public var diffuse: Float
    public var specular: Float

    public init(isEnabled: Bool = false,
                ambient: Float = 0.35,
                diffuse: Float = 0.55,
                specular: Float = 0.10) {
        self.isEnabled = isEnabled
        self.ambient = ambient
        self.diffuse = diffuse
        self.specular = specular
    }

    public static let `default` = MPRShadingSettings()

    public var sanitized: MPRShadingSettings {
        MPRShadingSettings(
            isEnabled: isEnabled,
            ambient: Self.sanitize(ambient, fallback: Self.default.ambient),
            diffuse: Self.sanitize(diffuse, fallback: Self.default.diffuse),
            specular: Self.sanitize(specular, fallback: Self.default.specular)
        )
    }

    private static func sanitize(_ value: Float, fallback: Float) -> Float {
        guard value.isFinite else { return fallback }
        return min(max(value, componentRange.lowerBound), componentRange.upperBound)
    }
}
