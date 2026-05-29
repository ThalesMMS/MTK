import Foundation
import simd

public enum MPRPresentationGraphicKind: String, Equatable, Sendable {
    case point
    case polyline
    case polygon
    case text
    case arrow
}

public struct MPRPresentationGraphicStyle: Equatable, Sendable {
    public var strokeColor: SIMD4<Float>
    public var textColor: SIMD4<Float>
    public var lineWidth: Float

    public init(strokeColor: SIMD4<Float> = SIMD4<Float>(1, 0.86, 0.18, 1),
                textColor: SIMD4<Float> = SIMD4<Float>(1, 0.86, 0.18, 1),
                lineWidth: Float = 2) {
        self.strokeColor = Self.clampedColor(strokeColor)
        self.textColor = Self.clampedColor(textColor)
        self.lineWidth = lineWidth.isFinite ? max(lineWidth, 1) : 2
    }

    private static func clampedColor(_ color: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(
            clamp(color.x),
            clamp(color.y),
            clamp(color.z),
            clamp(color.w)
        )
    }

    private static func clamp(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public struct MPRPresentationGraphicAnnotation: Equatable, Sendable {
    public var id: String
    public var kind: MPRPresentationGraphicKind
    public var axis: Axis
    public var sliceIndex: Int?
    public var normalizedImagePoints: [SIMD2<Float>]
    public var text: String?
    public var layerName: String?
    public var style: MPRPresentationGraphicStyle

    public init(id: String,
                kind: MPRPresentationGraphicKind,
                axis: Axis,
                sliceIndex: Int? = nil,
                normalizedImagePoints: [SIMD2<Float>],
                text: String? = nil,
                layerName: String? = nil,
                style: MPRPresentationGraphicStyle = MPRPresentationGraphicStyle()) {
        self.id = id.isEmpty ? UUID().uuidString : id
        self.kind = kind
        self.axis = axis
        self.sliceIndex = sliceIndex
        self.normalizedImagePoints = normalizedImagePoints.map(Self.clampedPoint)
        self.text = text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.layerName = layerName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.style = style
    }

    private static func clampedPoint(_ point: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2<Float>(clamp(point.x), clamp(point.y))
    }

    private static func clamp(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public enum MPRPresentationShutter: Equatable, Sendable {
    case rectangular(min: SIMD2<Float>, max: SIMD2<Float>)
    case circular(center: SIMD2<Float>, radius: Float)
}

public struct MPRPresentationState: Equatable, Sendable {
    public var id: String
    public var window: ClosedRange<Int32>?
    public var invert: Bool?
    public var viewportTransform: MPRViewportTransform
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    public var shutter: MPRPresentationShutter?
    public var graphicAnnotations: [MPRPresentationGraphicAnnotation]
    public var iccProfile: Data?

    public init(id: String = UUID().uuidString,
                window: ClosedRange<Int32>? = nil,
                invert: Bool? = nil,
                viewportTransform: MPRViewportTransform = .identity,
                flipHorizontal: Bool = false,
                flipVertical: Bool = false,
                shutter: MPRPresentationShutter? = nil,
                graphicAnnotations: [MPRPresentationGraphicAnnotation] = [],
                iccProfile: Data? = nil) {
        self.id = id.isEmpty ? UUID().uuidString : id
        self.window = window.map { min($0.lowerBound, $0.upperBound)...max($0.lowerBound, $0.upperBound) }
        self.invert = invert
        self.viewportTransform = viewportTransform
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.shutter = shutter
        self.graphicAnnotations = graphicAnnotations
        self.iccProfile = iccProfile?.isEmpty == false ? iccProfile : nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
