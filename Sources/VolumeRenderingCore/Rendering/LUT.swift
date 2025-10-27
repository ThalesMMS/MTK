//
//  LUT.swift
//  Isis DICOM Viewer
//
//  Declara o modelo TransferFunction com suporte a pontos de cor e alpha, além de conversão entre espaços de cor lineares e sRGB.
//  Fornece utilitários para carregar descrições JSON e gerar texturas Metal utilizadas pelos renderizadores volumétricos e MPR.
//  Thales Matheus Mendonça Santos - September 2025
//

import Foundation
import Metal
import OSLog
import simd

public struct TransferFunction: Codable {
    public enum ColorSpace: String, Codable {
        case linear
        case sRGB

        public func toLinear(_ component: Float) -> Float {
            let clamped = max(0, min(component, 1))
            switch self {
            case .linear:
                return clamped
            case .sRGB:
                if clamped <= 0.04045 {
                    return clamped / 12.92
                }
                return pow((clamped + 0.055) / 1.055, 2.4)
            }
        }
    }

    public struct RGBAColor: Codable, sizeable {
        public var r: Float = 0
        public var g: Float = 0
        public var b: Float = 0
        public var a: Float = 0

        public init() {}

        public static func +(lhs: RGBAColor, rhs: RGBAColor) -> RGBAColor {
            RGBAColor(r: lhs.r + rhs.r, g: lhs.g + rhs.g, b: lhs.b + rhs.b, a: lhs.a + rhs.a)
        }

        public static func *(lhs: RGBAColor, rhs: Float) -> RGBAColor {
            RGBAColor(r: lhs.r * rhs, g: lhs.g * rhs, b: lhs.b * rhs, a: lhs.a * rhs)
        }

        public init(r: Float, g: Float, b: Float, a: Float) {
            self.r = r
            self.g = g
            self.b = b
            self.a = a
        }
    }

    public struct ColorPoint: Codable {
        public var dataValue: Float = 0
        public var colourValue: RGBAColor = .init()
    }

    public struct AlphaPoint: Codable {
        public var dataValue: Float = 0
        public var alphaValue: Float = 0
    }

    public var version: Int?
    public var name: String = ""
    public var colourPoints: [ColorPoint] = []
    public var alphaPoints: [AlphaPoint] = []

    public var minimumValue: Float = -1024
    public var maximumValue: Float = 3071
    public var shift: Float = 0
    public var colorSpace: ColorSpace = .linear

    private enum CodingKeys: String, CodingKey {
        case version
        case name
        case colourPoints
        case alphaPoints
        case minimumValue = "min"
        case maximumValue = "max"
        case shift
        case colorSpace
    }

    public static func load(from url: URL,
                            logger: Logger = Logger(subsystem: "com.isis.metalvolumetrics",
                                                     category: "Volumetric.TransferFunction")) -> TransferFunction? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(TransferFunction.self, from: data)
        } catch {
            logger.error("Failed to load transfer function at \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    @MainActor
    public func makeTexture(device: any MTLDevice,
                            logger: Logger = Logger(subsystem: "com.isis.metalvolumetrics",
                                                     category: "Volumetric.TransferFunction")) -> (any MTLTexture)? {
        TransferFunctions.texture(for: self, device: device, logger: logger)
    }
}

public extension TransferFunction {
    func sanitizedColourPoints(defaultColour: RGBAColor = RGBAColor(r: 1, g: 1, b: 1, a: 1)) -> [ColorPoint] {
        var normalized = colourPoints
            .filter { $0.dataValue.isFinite }
            .map { point -> ColorPoint in
                var adjusted = point
                adjusted.dataValue = clamp(adjusted.dataValue, lower: minimumValue, upper: maximumValue)
                return adjusted
            }
            .sorted { $0.dataValue < $1.dataValue }

        normalized = deduplicate(points: normalized)

        guard !normalized.isEmpty else {
            return [
                ColorPoint(dataValue: minimumValue, colourValue: defaultColour),
                ColorPoint(dataValue: maximumValue, colourValue: defaultColour)
            ]
        }

        if normalized[0].dataValue > minimumValue {
            normalized.insert(ColorPoint(dataValue: minimumValue, colourValue: normalized[0].colourValue), at: 0)
        } else {
            normalized[0].dataValue = minimumValue
        }

        if normalized[normalized.count - 1].dataValue < maximumValue {
            normalized.append(ColorPoint(dataValue: maximumValue,
                                         colourValue: normalized[normalized.count - 1].colourValue))
        } else {
            normalized[normalized.count - 1].dataValue = maximumValue
        }

        return normalized
    }

    func sanitizedAlphaPoints(defaultRange: (Float, Float) = (0, 1)) -> [AlphaPoint] {
        var normalized = alphaPoints
            .filter { $0.dataValue.isFinite && $0.alphaValue.isFinite }
            .map { point -> AlphaPoint in
                var adjusted = point
                adjusted.dataValue = clamp(adjusted.dataValue, lower: minimumValue, upper: maximumValue)
                adjusted.alphaValue = clamp(adjusted.alphaValue,
                                            lower: defaultRange.0,
                                            upper: defaultRange.1)
                return adjusted
            }
            .sorted { $0.dataValue < $1.dataValue }

        normalized = deduplicate(points: normalized)

        guard !normalized.isEmpty else {
            return [
                AlphaPoint(dataValue: minimumValue, alphaValue: defaultRange.0),
                AlphaPoint(dataValue: maximumValue, alphaValue: defaultRange.1)
            ]
        }

        if normalized[0].dataValue > minimumValue {
            normalized.insert(AlphaPoint(dataValue: minimumValue, alphaValue: normalized[0].alphaValue), at: 0)
        } else {
            normalized[0].dataValue = minimumValue
        }

        if normalized[normalized.count - 1].dataValue < maximumValue {
            normalized.append(AlphaPoint(dataValue: maximumValue,
                                         alphaValue: normalized[normalized.count - 1].alphaValue))
        } else {
            normalized[normalized.count - 1].dataValue = maximumValue
        }

        return normalized
    }
}

private extension TransferFunction {
    func clamp(_ value: Float, lower: Float, upper: Float) -> Float {
        Swift.max(lower, Swift.min(value, upper))
    }

    func deduplicate(points: [ColorPoint]) -> [ColorPoint] {
        var result: [ColorPoint] = []
        for point in points {
            if let last = result.last, last.dataValue == point.dataValue {
                result[result.count - 1] = point
            } else {
                result.append(point)
            }
        }
        return result
    }

    func deduplicate(points: [AlphaPoint]) -> [AlphaPoint] {
        var result: [AlphaPoint] = []
        for point in points {
            if let last = result.last, last.dataValue == point.dataValue {
                result[result.count - 1] = point
            } else {
                result.append(point)
            }
        }
        return result
    }
}
