//
//  TransferFunction.swift
//  MTK
//
//  Declares the transfer function model and helpers used to build Metal textures.
//
//  Thales Matheus Mendonça Santos — October 2025

import Foundation
import Metal
import simd

/// A transfer function mapping volume intensity values to color and opacity.
///
/// `TransferFunction` defines how raw volume data intensities are converted to RGBA values
/// for rendering. It supports:
/// - Separate color and alpha control points with piecewise linear interpolation
/// - Color space conversion (linear and sRGB)
/// - Adjustable value ranges and shift offsets
/// - JSON serialization for loading from `.tf` files
/// - Metal texture generation for GPU-based rendering
///
/// ## File Format
/// Transfer functions are typically stored as JSON `.tf` files with the following structure:
/// ```json
/// {
///   "version": 1,
///   "name": "CT Bone",
///   "min": -1024,
///   "max": 3071,
///   "colorSpace": "linear",
///   "colourPoints": [
///     {"dataValue": -1024, "colourValue": {"r": 0.2, "g": 0.15, "b": 0.1, "a": 1}},
///     {"dataValue": 3071, "colourValue": {"r": 1, "g": 0.95, "b": 0.9, "a": 1}}
///   ],
///   "alphaPoints": [
///     {"dataValue": -1024, "alphaValue": 0},
///     {"dataValue": 200, "alphaValue": 0},
///     {"dataValue": 1000, "alphaValue": 0.8},
///     {"dataValue": 3071, "alphaValue": 1}
///   ]
/// }
/// ```
///
/// ## Usage
/// ```swift
/// // Load from file
/// if let tf = TransferFunction.load(from: url) {
///     // Generate Metal texture
///     if let texture = tf.makeTexture(device: metalDevice) {
///         // Apply to volume renderer
///     }
/// }
/// ```
///
/// - SeeAlso: `VolumeTransferFunctionLibrary`, `VolumeRenderingBuiltinPreset`
public struct TransferFunction: Codable {
    /// Color space for color point interpolation.
    ///
    /// Defines how RGB color values are interpreted and interpolated.
    public enum ColorSpace: String, Codable {
        /// Linear RGB color space (no gamma correction).
        case linear

        /// sRGB color space with gamma 2.2 approximation.
        case sRGB

        /// Convert a color component from this color space to linear RGB.
        ///
        /// - Parameter component: Color component value (0...1)
        /// - Returns: Linear RGB value (0...1)
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

    /// RGBA color value for transfer function control points.
    ///
    /// Represents a color with red, green, blue, and alpha components.
    /// Supports arithmetic operations for color interpolation.
    public struct RGBAColor: Codable, Sizeable {
        /// Red component (0...1).
        public var r: Float = 0

        /// Green component (0...1).
        public var g: Float = 0

        /// Blue component (0...1).
        public var b: Float = 0

        /// Alpha component (0...1).
        public var a: Float = 0

        /// Initialize a black transparent color (0, 0, 0, 0).
        public init() {}

        /// Component-wise addition of two colors.
        /// - Parameters:
        ///   - lhs: First color
        ///   - rhs: Second color
        /// - Returns: Sum of components (unclamped)
        public static func +(lhs: RGBAColor, rhs: RGBAColor) -> RGBAColor {
            RGBAColor(r: lhs.r + rhs.r, g: lhs.g + rhs.g, b: lhs.b + rhs.b, a: lhs.a + rhs.a)
        }

        /// Scalar multiplication of a color.
        /// - Parameters:
        ///   - lhs: Color to scale
        ///   - rhs: Scalar multiplier
        /// - Returns: Scaled color (unclamped)
        public static func *(lhs: RGBAColor, rhs: Float) -> RGBAColor {
            RGBAColor(r: lhs.r * rhs, g: lhs.g * rhs, b: lhs.b * rhs, a: lhs.a * rhs)
        }

        /// Initialize a color with RGBA components.
        /// - Parameters:
        ///   - r: Red component (0...1)
        ///   - g: Green component (0...1)
        ///   - b: Blue component (0...1)
        ///   - a: Alpha component (0...1)
        public init(r: Float, g: Float, b: Float, a: Float) {
            self.r = r
            self.g = g
            self.b = b
            self.a = a
        }
    }

    /// A control point mapping a data value to an RGBA color.
    ///
    /// Used to define the color transfer function. Colors are interpolated
    /// linearly between control points.
    public struct ColorPoint: Codable {
        /// Volume data intensity value.
        ///
        /// Should be within the transfer function's `minimumValue...maximumValue` range.
        public var dataValue: Float = 0

        /// RGBA color at this intensity.
        public var colourValue: RGBAColor = .init()
    }

    /// A control point mapping a data value to an alpha (opacity) value.
    ///
    /// Used to define the opacity transfer function. Alpha values are interpolated
    /// linearly between control points.
    public struct AlphaPoint: Codable {
        /// Volume data intensity value.
        ///
        /// Should be within the transfer function's `minimumValue...maximumValue` range.
        public var dataValue: Float = 0

        /// Opacity at this intensity (0 = transparent, 1 = opaque).
        public var alphaValue: Float = 0
    }

    /// Transfer function file format version.
    ///
    /// Used for forward/backward compatibility when loading `.tf` files.
    public var version: Int?

    /// Human-readable name for this transfer function (e.g., "CT Bone", "MR Angio").
    public var name: String = ""

    /// Color control points defining the color transfer function.
    ///
    /// Colors are interpolated linearly between points based on volume intensity.
    /// Use `sanitizedColourPoints()` to ensure valid ranges and endpoints.
    public var colourPoints: [ColorPoint] = []

    /// Alpha (opacity) control points defining the opacity transfer function.
    ///
    /// Opacity is interpolated linearly between points based on volume intensity.
    /// Use `sanitizedAlphaPoints()` to ensure valid ranges and endpoints.
    public var alphaPoints: [AlphaPoint] = []

    /// Minimum volume intensity value.
    ///
    /// Data values below this are clamped to this value before lookup.
    /// Default: -1024 (typical CT Hounsfield Unit minimum)
    public var minimumValue: Float = -1024

    /// Maximum volume intensity value.
    ///
    /// Data values above this are clamped to this value before lookup.
    /// Default: 3071 (typical CT Hounsfield Unit maximum)
    public var maximumValue: Float = 3071

    /// Intensity shift offset applied before transfer function lookup.
    ///
    /// Allows windowing adjustments without modifying control points.
    /// Default: 0 (no shift)
    public var shift: Float = 0

    /// Color space for color point interpolation.
    ///
    /// - `.linear`: No gamma correction (default)
    /// - `.sRGB`: Apply sRGB gamma correction during interpolation
    public var colorSpace: ColorSpace = .linear

    /// Initialize an empty transfer function.
    ///
    /// Creates a transfer function with no control points and default intensity range (-1024...3071).
    public init() {}

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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        colourPoints = try container.decodeIfPresent([ColorPoint].self, forKey: .colourPoints) ?? []
        alphaPoints = try container.decodeIfPresent([AlphaPoint].self, forKey: .alphaPoints) ?? []
        minimumValue = try container.decodeIfPresent(Float.self, forKey: .minimumValue) ?? minimumValue
        maximumValue = try container.decodeIfPresent(Float.self, forKey: .maximumValue) ?? maximumValue
        shift = try container.decodeIfPresent(Float.self, forKey: .shift) ?? shift
        colorSpace = try container.decodeIfPresent(ColorSpace.self, forKey: .colorSpace) ?? .linear
    }

    /// Load a transfer function from a JSON `.tf` file.
    ///
    /// Parses a JSON file containing transfer function definition including:
    /// - Control points (color and alpha)
    /// - Value range (min/max)
    /// - Color space
    /// - Metadata (name, version)
    ///
    /// - Parameters:
    ///   - url: URL to the `.tf` JSON file
    ///   - logger: Logger for error reporting (default: MTKCore logger)
    /// - Returns: Parsed `TransferFunction`, or `nil` if loading or parsing fails
    ///
    /// ## Example
    /// ```swift
    /// let url = Bundle.main.url(forResource: "ct_bone", withExtension: "tf")!
    /// if let tf = TransferFunction.load(from: url) {
    ///     print("Loaded transfer function: \(tf.name)")
    /// }
    /// ```
    public static func load(from url: URL,
                            logger: Logger = Logger(subsystem: "com.mtk.volumerendering",
                                                     category: "TransferFunction")) -> TransferFunction? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(TransferFunction.self, from: data)
        } catch {
            logger.error("Failed to load transfer function at \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    /// Generate a 1D Metal texture from this transfer function.
    ///
    /// Creates a 1D RGBA texture by interpolating color and alpha control points.
    /// The texture maps volume intensity values (normalized to 0...1) to RGBA colors.
    ///
    /// - Parameters:
    ///   - device: Metal device for texture creation
    ///   - logger: Logger for error reporting (default: MTKCore logger)
    /// - Returns: 1D Metal texture, or `nil` if generation fails
    ///
    /// ## Example
    /// ```swift
    /// @MainActor
    /// func setupTransferFunction() {
    ///     if let tf = TransferFunction.load(from: url),
    ///        let texture = tf.makeTexture(device: metalDevice) {
    ///         // Bind texture to volume rendering shader
    ///     }
    /// }
    /// ```
    ///
    /// - Important: Must be called from the main actor due to Metal texture creation requirements.
    @MainActor
    public func makeTexture(device: any MTLDevice,
                            logger: Logger = Logger(subsystem: "com.mtk.volumerendering",
                                                     category: "TransferFunction")) -> (any MTLTexture)? {
        TransferFunctions.texture(for: self, device: device, logger: logger)
    }
}

public extension TransferFunction {
    /// Sanitize and validate color control points.
    ///
    /// Ensures color points are valid for texture generation by:
    /// - Filtering out non-finite values
    /// - Clamping data values to `minimumValue...maximumValue`
    /// - Sorting by data value
    /// - Removing duplicate data values (keeping last)
    /// - Adding endpoint control points if missing
    ///
    /// - Parameter defaultColour: Color to use for auto-generated endpoints (default: white)
    /// - Returns: Array of validated color points with guaranteed endpoints
    func sanitizedColourPoints(defaultColour: RGBAColor = RGBAColor(r: 1, g: 1, b: 1, a: 1)) -> [ColorPoint] {
        var normalized = colourPoints
            .filter { $0.dataValue.isFinite }
            .map { point -> ColorPoint in
                var adjusted = point
                adjusted.dataValue = VolumetricMath.clampFloat(adjusted.dataValue, lower: minimumValue, upper: maximumValue)
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

    /// Sanitize and validate alpha control points.
    ///
    /// Ensures alpha points are valid for texture generation by:
    /// - Filtering out non-finite values
    /// - Clamping data values to `minimumValue...maximumValue`
    /// - Clamping alpha values to `defaultRange`
    /// - Sorting by data value
    /// - Removing duplicate data values (keeping last)
    /// - Adding endpoint control points if missing
    ///
    /// - Parameter defaultRange: Alpha range for auto-generated endpoints (default: 0...1)
    /// - Returns: Array of validated alpha points with guaranteed endpoints
    func sanitizedAlphaPoints(defaultRange: (Float, Float) = (0, 1)) -> [AlphaPoint] {
        var normalized = alphaPoints
            .filter { $0.dataValue.isFinite && $0.alphaValue.isFinite }
            .map { point -> AlphaPoint in
                var adjusted = point
                adjusted.dataValue = VolumetricMath.clampFloat(adjusted.dataValue, lower: minimumValue, upper: maximumValue)
                adjusted.alphaValue = VolumetricMath.clampFloat(adjusted.alphaValue,
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
