//
//  TransferFunction2D.swift
//  MTK
//
//  2D transfer function model with gradient-intensity control points.
//  Enables improved tissue boundary visualization by mapping both intensity
//  and gradient magnitude to color/opacity.
//
//  Thales Matheus Mendonça Santos — February 2026

import Foundation
import Metal
import simd

public struct TransferFunction2D: Codable {
    /// 2D control point defined by intensity, gradient magnitude, and RGBA color
    public struct ColorPoint2D: Codable {
        public var intensity: Float = 0
        public var gradientMagnitude: Float = 0
        public var colourValue: TransferFunction.RGBAColor = .init()

        public init() {}

        public init(intensity: Float, gradientMagnitude: Float, colourValue: TransferFunction.RGBAColor) {
            self.intensity = intensity
            self.gradientMagnitude = gradientMagnitude
            self.colourValue = colourValue
        }
    }

    /// 2D alpha control point defined by intensity, gradient magnitude, and alpha value
    public struct AlphaPoint2D: Codable {
        public var intensity: Float = 0
        public var gradientMagnitude: Float = 0
        public var alphaValue: Float = 0

        public init() {}

        public init(intensity: Float, gradientMagnitude: Float, alphaValue: Float) {
            self.intensity = intensity
            self.gradientMagnitude = gradientMagnitude
            self.alphaValue = alphaValue
        }
    }

    public var version: Int?
    public var name: String = ""
    public var colourPoints: [ColorPoint2D] = []
    public var alphaPoints: [AlphaPoint2D] = []

    public var minimumIntensity: Float = -1024
    public var maximumIntensity: Float = 3071
    public var minimumGradient: Float = 0
    public var maximumGradient: Float = 100
    public var shift: Float = 0
    public var colorSpace: TransferFunction.ColorSpace = .linear

    /// Resolution of the 2D texture (width = intensity bins, height = gradient bins)
    public var intensityResolution: Int = 256
    public var gradientResolution: Int = 256

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version
        case name
        case colourPoints
        case alphaPoints
        case minimumIntensity = "minIntensity"
        case maximumIntensity = "maxIntensity"
        case minimumGradient = "minGradient"
        case maximumGradient = "maxGradient"
        case shift
        case colorSpace
        case intensityResolution
        case gradientResolution
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        colourPoints = try container.decodeIfPresent([ColorPoint2D].self, forKey: .colourPoints) ?? []
        alphaPoints = try container.decodeIfPresent([AlphaPoint2D].self, forKey: .alphaPoints) ?? []
        minimumIntensity = try container.decodeIfPresent(Float.self, forKey: .minimumIntensity) ?? minimumIntensity
        maximumIntensity = try container.decodeIfPresent(Float.self, forKey: .maximumIntensity) ?? maximumIntensity
        minimumGradient = try container.decodeIfPresent(Float.self, forKey: .minimumGradient) ?? minimumGradient
        maximumGradient = try container.decodeIfPresent(Float.self, forKey: .maximumGradient) ?? maximumGradient
        shift = try container.decodeIfPresent(Float.self, forKey: .shift) ?? shift
        colorSpace = try container.decodeIfPresent(TransferFunction.ColorSpace.self, forKey: .colorSpace) ?? .linear
        intensityResolution = try container.decodeIfPresent(Int.self, forKey: .intensityResolution) ?? intensityResolution
        gradientResolution = try container.decodeIfPresent(Int.self, forKey: .gradientResolution) ?? gradientResolution
    }

    public static func load(from url: URL,
                            logger: Logger = Logger(subsystem: "com.mtk.volumerendering",
                                                     category: "TransferFunction2D")) -> TransferFunction2D? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(TransferFunction2D.self, from: data)
        } catch {
            logger.error("Failed to load 2D transfer function at \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    @MainActor
    public func makeTexture(device: any MTLDevice,
                            logger: Logger = Logger(subsystem: "com.mtk.volumerendering",
                                                     category: "TransferFunction2D")) -> (any MTLTexture)? {
        let options = TransferFunctions.TextureOptions(
            resolution: intensityResolution,
            gradientResolution: gradientResolution
        )
        return TransferFunctions.texture(for: self, device: device, options: options, logger: logger)
    }
}

public extension TransferFunction2D {
    func sanitizedColourPoints(defaultColour: TransferFunction.RGBAColor = TransferFunction.RGBAColor(r: 1, g: 1, b: 1, a: 1)) -> [ColorPoint2D] {
        var normalized = colourPoints
            .filter { $0.intensity.isFinite && $0.gradientMagnitude.isFinite }
            .map { point -> ColorPoint2D in
                var adjusted = point
                adjusted.intensity = VolumetricMath.clampFloat(adjusted.intensity, lower: minimumIntensity, upper: maximumIntensity)
                adjusted.gradientMagnitude = VolumetricMath.clampFloat(adjusted.gradientMagnitude, lower: minimumGradient, upper: maximumGradient)
                return adjusted
            }
            .sorted { ($0.intensity, $0.gradientMagnitude) < ($1.intensity, $1.gradientMagnitude) }

        normalized = deduplicate(points: normalized)

        guard !normalized.isEmpty else {
            return [
                ColorPoint2D(intensity: minimumIntensity, gradientMagnitude: minimumGradient, colourValue: defaultColour),
                ColorPoint2D(intensity: maximumIntensity, gradientMagnitude: maximumGradient, colourValue: defaultColour)
            ]
        }

        return normalized
    }

    func sanitizedAlphaPoints(defaultRange: (Float, Float) = (0, 1)) -> [AlphaPoint2D] {
        var normalized = alphaPoints
            .filter { $0.intensity.isFinite && $0.gradientMagnitude.isFinite && $0.alphaValue.isFinite }
            .map { point -> AlphaPoint2D in
                var adjusted = point
                adjusted.intensity = VolumetricMath.clampFloat(adjusted.intensity, lower: minimumIntensity, upper: maximumIntensity)
                adjusted.gradientMagnitude = VolumetricMath.clampFloat(adjusted.gradientMagnitude, lower: minimumGradient, upper: maximumGradient)
                adjusted.alphaValue = VolumetricMath.clampFloat(adjusted.alphaValue,
                                            lower: defaultRange.0,
                                            upper: defaultRange.1)
                return adjusted
            }
            .sorted { ($0.intensity, $0.gradientMagnitude) < ($1.intensity, $1.gradientMagnitude) }

        normalized = deduplicate(points: normalized)

        guard !normalized.isEmpty else {
            return [
                AlphaPoint2D(intensity: minimumIntensity, gradientMagnitude: minimumGradient, alphaValue: defaultRange.0),
                AlphaPoint2D(intensity: maximumIntensity, gradientMagnitude: maximumGradient, alphaValue: defaultRange.1)
            ]
        }

        return normalized
    }
}

private extension TransferFunction2D {
    func deduplicate(points: [ColorPoint2D]) -> [ColorPoint2D] {
        var result: [ColorPoint2D] = []
        for point in points {
            if let last = result.last, last.intensity == point.intensity && last.gradientMagnitude == point.gradientMagnitude {
                result[result.count - 1] = point
            } else {
                result.append(point)
            }
        }
        return result
    }

    func deduplicate(points: [AlphaPoint2D]) -> [AlphaPoint2D] {
        var result: [AlphaPoint2D] = []
        for point in points {
            if let last = result.last, last.intensity == point.intensity && last.gradientMagnitude == point.gradientMagnitude {
                result[result.count - 1] = point
            } else {
                result.append(point)
            }
        }
        return result
    }
}
