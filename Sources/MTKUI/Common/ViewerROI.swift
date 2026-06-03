import CoreGraphics
import Foundation
import MTKCore
import simd

public enum ViewerROIKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case distance
    case angle
    case cobbAngle
    case point
    case area
    case ellipse
    case closedPath
    case curvedLine
    case text
    case arrow
    case scribble
    case volume
    case ctr

    public var id: String { rawValue }

    public var stableIdentifier: String {
        switch self {
        case .distance:
            return "distance"
        case .angle:
            return "angle"
        case .cobbAngle:
            return "cobb-angle"
        case .point:
            return "point"
        case .area:
            return "area"
        case .ellipse:
            return "ellipse"
        case .closedPath:
            return "closed-path"
        case .curvedLine:
            return "curved-line"
        case .text:
            return "text"
        case .arrow:
            return "arrow"
        case .scribble:
            return "scribble"
        case .volume:
            return "volume"
        case .ctr:
            return "ctr"
        }
    }

    public var displayName: String {
        switch self {
        case .distance:
            return "Distance"
        case .angle:
            return "Angle"
        case .cobbAngle:
            return "Cobb Angle"
        case .point:
            return "Point"
        case .area:
            return "Area"
        case .ellipse:
            return "Ellipse"
        case .closedPath:
            return "Polygon"
        case .curvedLine:
            return "Curved Line"
        case .text:
            return "Text"
        case .arrow:
            return "Arrow"
        case .scribble:
            return "Freehand"
        case .volume:
            return "Volume"
        case .ctr:
            return "CTR"
        }
    }

    public var systemImage: String {
        switch self {
        case .distance:
            return "ruler"
        case .angle:
            return "angle"
        case .cobbAngle:
            return "c.square"
        case .point:
            return "circle"
        case .area:
            return "circle.dotted"
        case .ellipse:
            return "oval"
        case .closedPath:
            return "skew"
        case .curvedLine:
            return "point.topleft.down.curvedto.point.bottomright.up"
        case .text:
            return "textformat"
        case .arrow:
            return "arrow.up.right"
        case .scribble:
            return "scribble"
        case .volume:
            return "cube"
        case .ctr:
            return "heart.rectangle"
        }
    }

    public var supportsDrawnAnnotationMeasurement: Bool {
        switch self {
        case .volume:
            return false
        default:
            return true
        }
    }

    public var isImplementedInMPRFirstDelivery: Bool {
        supportsDrawnAnnotationMeasurement
    }

    public var measurementModel: ViewerROIMeasurementModel {
        switch self {
        case .distance:
            return .distance
        case .angle, .cobbAngle:
            return .angle
        case .point:
            return .point
        case .area:
            return .area
        case .ellipse:
            return .ellipse
        case .closedPath:
            return .polygon
        case .curvedLine:
            return .polyline
        case .text:
            return .text
        case .arrow:
            return .arrow
        case .scribble:
            return .freehand
        case .volume:
            return .volume
        case .ctr:
            return .ratio
        }
    }

    public var defaultMeasurementUnit: ViewerROIMeasurementUnit {
        switch self {
        case .distance, .curvedLine, .scribble:
            return .millimeters
        case .angle, .cobbAngle:
            return .degrees
        case .area, .ellipse, .closedPath:
            return .squareMillimeters
        case .volume:
            return .cubicMillimeters
        case .ctr:
            return .unitless
        case .point, .text, .arrow:
            return .none
        }
    }
}

public enum ViewerROIMeasurementModel: String, Codable, Equatable, Sendable {
    case none
    case point
    case distance
    case angle
    case area
    case ellipse
    case polygon
    case polyline
    case freehand
    case text
    case arrow
    case ratio
    case volume
    case quantitative
}

public enum ViewerROIMeasurementUnit: String, Codable, Equatable, Sendable {
    case none
    case millimeters
    case pixels
    case degrees
    case squareMillimeters
    case squarePixels
    case cubicMillimeters
    case unitless
    case quantitative
}

public enum ViewerROIMeasurement: Equatable, Sendable {
    case distanceMillimeters(Double)
    case distancePixels(Double)
    case angleDegrees(Double)
    case areaSquareMillimeters(Double)
    case areaPixels(Double)
    case lengthMillimeters(Double)
    case lengthPixels(Double)
    case ratio(Double)
    case volumeCubicMillimeters(Double)

    public var displayText: String {
        switch self {
        case .distanceMillimeters(let millimeters):
            return String(format: "%.1f mm", millimeters)
        case .distancePixels(let pixels):
            return String(format: "%.1f px", pixels)
        case .angleDegrees(let degrees):
            return String(format: "%.1f deg", degrees)
        case .areaSquareMillimeters(let squareMillimeters):
            return String(format: "%.1f mm2", squareMillimeters)
        case .areaPixels(let pixels):
            return String(format: "%.1f px2", pixels)
        case .lengthMillimeters(let millimeters):
            return String(format: "%.1f mm", millimeters)
        case .lengthPixels(let pixels):
            return String(format: "%.1f px", pixels)
        case .ratio(let ratio):
            return String(format: "CTR %.2f", ratio)
        case .volumeCubicMillimeters(let cubicMillimeters):
            return String(format: "%.1f mm3", cubicMillimeters)
        }
    }

    public var model: ViewerROIMeasurementModel {
        switch self {
        case .distanceMillimeters, .distancePixels:
            return .distance
        case .angleDegrees:
            return .angle
        case .areaSquareMillimeters, .areaPixels:
            return .area
        case .lengthMillimeters, .lengthPixels:
            return .polyline
        case .ratio:
            return .ratio
        case .volumeCubicMillimeters:
            return .volume
        }
    }

    public var unit: ViewerROIMeasurementUnit {
        switch self {
        case .distanceMillimeters, .lengthMillimeters:
            return .millimeters
        case .distancePixels, .lengthPixels:
            return .pixels
        case .angleDegrees:
            return .degrees
        case .areaSquareMillimeters:
            return .squareMillimeters
        case .areaPixels:
            return .squarePixels
        case .ratio:
            return .unitless
        case .volumeCubicMillimeters:
            return .cubicMillimeters
        }
    }

    public var primaryValue: Double {
        switch self {
        case .distanceMillimeters(let value),
             .distancePixels(let value),
             .angleDegrees(let value),
             .areaSquareMillimeters(let value),
             .areaPixels(let value),
             .lengthMillimeters(let value),
             .lengthPixels(let value),
             .ratio(let value),
             .volumeCubicMillimeters(let value):
            return value
        }
    }

    public var distanceMillimeters: Double? {
        switch self {
        case .distanceMillimeters(let millimeters):
            return millimeters
        case .distancePixels, .angleDegrees, .areaSquareMillimeters, .areaPixels,
             .lengthMillimeters, .lengthPixels, .ratio, .volumeCubicMillimeters:
            return nil
        }
    }
}

public struct ViewerROIColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    public static let yellow = ViewerROIColor(red: 1, green: 0.86, blue: 0.18)
    public static let black = ViewerROIColor(red: 0, green: 0, blue: 0, alpha: 0.72)

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public struct ViewerROIStyle: Codable, Equatable, Sendable {
    public var strokeColor: ViewerROIColor
    public var textColor: ViewerROIColor
    public var labelBackgroundColor: ViewerROIColor
    public var lineWidth: Double

    public init(strokeColor: ViewerROIColor = .yellow,
                textColor: ViewerROIColor = .yellow,
                labelBackgroundColor: ViewerROIColor = .black,
                lineWidth: Double = 2) {
        self.strokeColor = strokeColor
        self.textColor = textColor
        self.labelBackgroundColor = labelBackgroundColor
        self.lineWidth = lineWidth.isFinite ? max(lineWidth, 1) : 2
    }

    public static let `default` = ViewerROIStyle()
}

public struct ViewerROIAnnotation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var kind: ViewerROIKind
    public var axis: MTKCore.Axis
    public var sliceIndex: Int?
    public var seriesIdentifier: String?
    public var normalizedImagePoints: [CGPoint]
    public var text: String?
    public var measurement: ViewerROIMeasurement?
    public var style: ViewerROIStyle

    public init(id: UUID = UUID(),
                kind: ViewerROIKind,
                axis: MTKCore.Axis,
                sliceIndex: Int? = nil,
                seriesIdentifier: String? = nil,
                normalizedImagePoints: [CGPoint],
                text: String? = nil,
                measurement: ViewerROIMeasurement? = nil,
                style: ViewerROIStyle = .default) {
        self.id = id
        self.kind = kind
        self.axis = axis
        self.sliceIndex = sliceIndex
        self.seriesIdentifier = seriesIdentifier
        self.normalizedImagePoints = normalizedImagePoints.map(Self.clampedPoint)
        self.text = ClinicalDisplayTextSanitizer.safeSeriesTitle(text)
        self.measurement = measurement
        self.style = style
    }

    public var measurementModel: ViewerROIMeasurementModel {
        kind.measurementModel
    }

    public var measurementUnit: ViewerROIMeasurementUnit {
        measurement?.unit ?? kind.defaultMeasurementUnit
    }

    public var persistentState: ViewerROIPersistentState {
        ViewerROIPersistentState(annotation: self)
    }

    fileprivate static func clampedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: clamp(point.x), y: clamp(point.y))
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public struct ViewerROIPersistentPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x.isFinite ? min(max(x, 0), 1) : 0
        self.y = y.isFinite ? min(max(y, 0), 1) : 0
    }

    public init(_ point: CGPoint) {
        self.init(x: Double(point.x), y: Double(point.y))
    }

    public var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

public struct ViewerROIPersistentMeasurement: Codable, Equatable, Sendable {
    public var model: ViewerROIMeasurementModel
    public var unit: ViewerROIMeasurementUnit
    public var value: Double
    public var displayText: String

    public init(model: ViewerROIMeasurementModel,
                unit: ViewerROIMeasurementUnit,
                value: Double,
                displayText: String) {
        self.model = model
        self.unit = unit
        self.value = value.isFinite ? value : 0
        self.displayText = displayText
    }

    public init(_ measurement: ViewerROIMeasurement) {
        self.init(model: measurement.model,
                  unit: measurement.unit,
                  value: measurement.primaryValue,
                  displayText: measurement.displayText)
    }
}

public struct ViewerROIPersistentState: Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: ViewerROIKind
    public var axis: String
    public var sliceIndex: Int?
    public var seriesIdentifier: String?
    public var normalizedImagePoints: [ViewerROIPersistentPoint]
    public var text: String?
    public var measurementModel: ViewerROIMeasurementModel
    public var measurementUnit: ViewerROIMeasurementUnit
    public var measurement: ViewerROIPersistentMeasurement?
    public var style: ViewerROIStyle

    public init(annotation: ViewerROIAnnotation) {
        self.id = annotation.id
        self.kind = annotation.kind
        self.axis = annotation.axis.persistentIdentifier
        self.sliceIndex = annotation.sliceIndex
        self.seriesIdentifier = annotation.seriesIdentifier
        self.normalizedImagePoints = annotation.normalizedImagePoints.map(ViewerROIPersistentPoint.init)
        self.text = annotation.text
        self.measurementModel = annotation.measurementModel
        self.measurementUnit = annotation.measurementUnit
        self.measurement = annotation.measurement.map(ViewerROIPersistentMeasurement.init)
        self.style = annotation.style
    }
}

public enum ViewerROIPointFactory {
    public static func points(kind: ViewerROIKind,
                              start: CGPoint,
                              end: CGPoint) -> [CGPoint] {
        switch kind {
        case .distance, .arrow, .curvedLine, .scribble:
            return [start, end]
        case .point, .text:
            return [end]
        case .angle:
            return [CGPoint(x: end.x, y: start.y), start, end]
        case .cobbAngle:
            return [
                start,
                CGPoint(x: end.x, y: start.y),
                CGPoint(x: start.x, y: end.y),
                end
            ]
        case .area, .ellipse, .closedPath, .volume:
            return [
                start,
                CGPoint(x: end.x, y: start.y),
                end,
                CGPoint(x: start.x, y: end.y)
            ]
        case .ctr:
            let left = min(start.x, end.x)
            let right = max(start.x, end.x)
            let y = (start.y + end.y) * 0.5
            let centerX = (left + right) * 0.5
            let cardiacHalfWidth = (right - left) * 0.25
            return [
                CGPoint(x: left, y: y),
                CGPoint(x: right, y: y),
                CGPoint(x: centerX - cardiacHalfWidth, y: y),
                CGPoint(x: centerX + cardiacHalfWidth, y: y)
            ]
        }
    }
}

public struct ViewerROIStore: Equatable, Sendable {
    public private(set) var annotations: [ViewerROIAnnotation]

    public init(annotations: [ViewerROIAnnotation] = []) {
        self.annotations = annotations
    }

    public mutating func add(_ annotation: ViewerROIAnnotation) {
        annotations.append(annotation)
    }

    public func annotations(axis: MTKCore.Axis,
                            sliceIndex: Int? = nil,
                            seriesIdentifier: String? = nil) -> [ViewerROIAnnotation] {
        annotations.filter { annotation in
            if let seriesIdentifier, annotation.seriesIdentifier != seriesIdentifier {
                return false
            }
            guard annotation.axis == axis else { return false }
            guard let sliceIndex else { return true }
            return annotation.sliceIndex == nil || annotation.sliceIndex == sliceIndex
        }
    }

    @discardableResult
    public mutating func deleteAnnotations(axis: MTKCore.Axis,
                                           sliceIndex: Int? = nil,
                                           seriesIdentifier: String? = nil) -> [ViewerROIAnnotation] {
        let removed = annotations(axis: axis,
                                  sliceIndex: sliceIndex,
                                  seriesIdentifier: seriesIdentifier)
        let removedIDs = Set(removed.map(\.id))
        annotations.removeAll { removedIDs.contains($0.id) }
        return removed
    }

    public mutating func deleteAll() {
        annotations.removeAll()
    }

    @discardableResult
    public mutating func deleteAll(seriesIdentifier: String?) -> [ViewerROIAnnotation] {
        guard let seriesIdentifier else {
            let removed = annotations
            annotations.removeAll()
            return removed
        }
        let removed = annotations.filter { $0.seriesIdentifier == seriesIdentifier }
        let removedIDs = Set(removed.map(\.id))
        annotations.removeAll { removedIDs.contains($0.id) }
        return removed
    }

    public func hitTest(normalizedPoint point: CGPoint,
                        axis: MTKCore.Axis,
                        sliceIndex: Int? = nil,
                        seriesIdentifier: String? = nil,
                        tolerance: CGFloat = 0.025) -> ViewerROIAnnotation? {
        annotations(axis: axis, sliceIndex: sliceIndex, seriesIdentifier: seriesIdentifier)
            .reversed()
            .first { annotation in
                annotation.normalizedImagePoints.contains { candidate in
                    Self.distance(candidate, point) <= tolerance
                } || Self.minSegmentDistance(annotation.normalizedImagePoints, point) <= tolerance
            }
    }

    public mutating func moveAnnotation(id: UUID,
                                        by delta: CGVector) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[index].normalizedImagePoints = annotations[index].normalizedImagePoints.map { point in
            CGPoint(x: point.x + delta.dx, y: point.y + delta.dy)
        }.map(ViewerROIAnnotation.clampedPoint)
    }

    public mutating func movePoint(annotationID: UUID,
                                   pointIndex: Int,
                                   to point: CGPoint) {
        guard let annotationIndex = annotations.firstIndex(where: { $0.id == annotationID }),
              annotations[annotationIndex].normalizedImagePoints.indices.contains(pointIndex) else {
            return
        }
        annotations[annotationIndex].normalizedImagePoints[pointIndex] = ViewerROIAnnotation.clampedPoint(point)
    }

    private static func minSegmentDistance(_ points: [CGPoint],
                                           _ point: CGPoint) -> CGFloat {
        guard points.count >= 2 else { return .greatestFiniteMagnitude }
        return zip(points, points.dropFirst())
            .map { segmentDistance(point, start: $0.0, end: $0.1) }
            .min() ?? .greatestFiniteMagnitude
    }

    private static func segmentDistance(_ point: CGPoint,
                                        start: CGPoint,
                                        end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(point, start) }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let projection = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        return distance(point, projection)
    }

    private static func distance(_ lhs: CGPoint,
                                 _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}

public enum ViewerROIMeasurementCalculator {
    public static func volumeMeasurement(in layer: VolumeLayer,
                                         label: UInt16? = nil) throws -> ViewerROIMeasurement {
        try ViewerROILabelmapVolumeCalculator.summary(in: layer, label: label).measurement
    }

    public static func measurement(kind: ViewerROIKind,
                                   axis: MTKCore.Axis,
                                   normalizedImagePoints points: [CGPoint],
                                   dimensions: VolumeDimensions? = nil,
                                   spacing: VolumeSpacing? = nil) -> ViewerROIMeasurement? {
        switch kind {
        case .distance:
            if let dimensions, let spacing,
               let millimeters = distanceMillimeters(axis: axis,
                                                     normalizedImagePoints: points,
                                                     dimensions: dimensions,
                                                     spacing: spacing) {
                return .distanceMillimeters(millimeters)
            }
            guard let dimensions,
                  let pixels = distancePixels(axis: axis,
                                              normalizedImagePoints: points,
                                              dimensions: dimensions) else {
                return nil
            }
            return .distancePixels(pixels)
        case .angle:
            return angleDegrees(normalizedImagePoints: points).map(ViewerROIMeasurement.angleDegrees)
        case .cobbAngle:
            return cobbAngleDegrees(normalizedImagePoints: points).map(ViewerROIMeasurement.angleDegrees)
        case .area, .closedPath:
            if let dimensions, let spacing,
               let squareMillimeters = areaSquareMillimeters(axis: axis,
                                                             normalizedImagePoints: points,
                                                             dimensions: dimensions,
                                                             spacing: spacing) {
                return .areaSquareMillimeters(squareMillimeters)
            }
            guard let dimensions,
                  let pixels = areaPixels(axis: axis,
                                          normalizedImagePoints: points,
                                          dimensions: dimensions) else {
                return nil
            }
            return .areaPixels(pixels)
        case .ellipse:
            if let dimensions, let spacing,
               let squareMillimeters = ellipseAreaSquareMillimeters(axis: axis,
                                                                    normalizedImagePoints: points,
                                                                    dimensions: dimensions,
                                                                    spacing: spacing) {
                return .areaSquareMillimeters(squareMillimeters)
            }
            guard let dimensions,
                  let pixels = ellipseAreaPixels(axis: axis,
                                                 normalizedImagePoints: points,
                                                 dimensions: dimensions) else {
                return nil
            }
            return .areaPixels(pixels)
        case .curvedLine:
            if let dimensions, let spacing,
               let millimeters = polylineLengthMillimeters(axis: axis,
                                                           normalizedImagePoints: points,
                                                           dimensions: dimensions,
                                                           spacing: spacing) {
                return .lengthMillimeters(millimeters)
            }
            guard let dimensions,
                  let pixels = polylineLengthPixels(axis: axis,
                                                    normalizedImagePoints: points,
                                                    dimensions: dimensions) else {
                return nil
            }
            return .lengthPixels(pixels)
        case .scribble:
            if let dimensions, let spacing,
               let millimeters = polylineLengthMillimeters(axis: axis,
                                                           normalizedImagePoints: points,
                                                           dimensions: dimensions,
                                                           spacing: spacing) {
                return .lengthMillimeters(millimeters)
            }
            guard let dimensions,
                  let pixels = polylineLengthPixels(axis: axis,
                                                    normalizedImagePoints: points,
                                                    dimensions: dimensions) else {
                return nil
            }
            return .lengthPixels(pixels)
        case .ctr:
            return ctrRatio(axis: axis,
                            normalizedImagePoints: points,
                            dimensions: dimensions,
                            spacing: spacing).map(ViewerROIMeasurement.ratio)
        case .volume, .point, .text, .arrow:
            return nil
        }
    }

    public static func distanceMillimeters(axis: MTKCore.Axis,
                                           normalizedImagePoints points: [CGPoint],
                                           dimensions: VolumeDimensions,
                                           spacing: VolumeSpacing) -> Double? {
        guard let pair = firstPointPair(points) else { return nil }

        let width: Int
        let height: Int
        let spacingU: Double
        let spacingV: Double
        switch axis {
        case .axial:
            width = dimensions.width
            height = dimensions.height
            spacingU = spacing.x
            spacingV = spacing.y
        case .coronal:
            width = dimensions.width
            height = dimensions.depth
            spacingU = spacing.x
            spacingV = spacing.z
        case .sagittal:
            width = dimensions.height
            height = dimensions.depth
            spacingU = spacing.y
            spacingV = spacing.z
        }

        let deltaU = Double(pair.end.x - pair.start.x) * Double(max(width - 1, 0)) * spacingU
        let deltaV = Double(pair.end.y - pair.start.y) * Double(max(height - 1, 0)) * spacingV
        return finiteDistance(deltaU: deltaU, deltaV: deltaV)
    }

    public static func distancePixels(axis: MTKCore.Axis,
                                      normalizedImagePoints points: [CGPoint],
                                      dimensions: VolumeDimensions) -> Double? {
        guard let pair = firstPointPair(points) else { return nil }
        let size = imageSize(axis: axis, dimensions: dimensions)
        let deltaU = Double(pair.end.x - pair.start.x) * Double(max(size.width - 1, 0))
        let deltaV = Double(pair.end.y - pair.start.y) * Double(max(size.height - 1, 0))
        return finiteDistance(deltaU: deltaU, deltaV: deltaV)
    }

    public static func distanceMillimeters(normalizedImagePoints points: [CGPoint],
                                           plane: MPRPlaneGeometry) -> Double? {
        guard let pair = firstPointPair(points) else { return nil }
        let deltaU = Float(pair.end.x - pair.start.x)
        let deltaV = Float(pair.end.y - pair.start.y)
        guard deltaU.isFinite, deltaV.isFinite else { return nil }
        let worldDelta = deltaU * plane.axisUWorld + deltaV * plane.axisVWorld
        let distance = Double(simd_length(worldDelta))
        return distance.isFinite ? distance : nil
    }

    public static func angleDegrees(normalizedImagePoints points: [CGPoint]) -> Double? {
        guard points.count >= 3 else { return nil }
        return angleDegrees(lineAStart: points[1],
                            lineAEnd: points[0],
                            lineBStart: points[1],
                            lineBEnd: points[2])
    }

    public static func cobbAngleDegrees(normalizedImagePoints points: [CGPoint]) -> Double? {
        guard points.count >= 4 else { return nil }
        return angleDegrees(lineAStart: points[0],
                            lineAEnd: points[1],
                            lineBStart: points[2],
                            lineBEnd: points[3])
    }

    public static func areaSquareMillimeters(axis: MTKCore.Axis,
                                             normalizedImagePoints points: [CGPoint],
                                             dimensions: VolumeDimensions,
                                             spacing: VolumeSpacing) -> Double? {
        guard points.count >= 3 else { return nil }
        let size = imageSize(axis: axis, dimensions: dimensions)
        let spacing = imageSpacing(axis: axis, spacing: spacing)
        let scaled = points.map { point in
            CGPoint(x: CGFloat(Double(point.x) * Double(max(size.width - 1, 0)) * spacing.u),
                    y: CGFloat(Double(point.y) * Double(max(size.height - 1, 0)) * spacing.v))
        }
        return finiteArea(points: scaled)
    }

    public static func areaPixels(axis: MTKCore.Axis,
                                  normalizedImagePoints points: [CGPoint],
                                  dimensions: VolumeDimensions) -> Double? {
        guard points.count >= 3 else { return nil }
        let size = imageSize(axis: axis, dimensions: dimensions)
        let scaled = points.map { point in
            CGPoint(x: CGFloat(Double(point.x) * Double(max(size.width - 1, 0))),
                    y: CGFloat(Double(point.y) * Double(max(size.height - 1, 0))))
        }
        return finiteArea(points: scaled)
    }

    public static func ellipseAreaSquareMillimeters(axis: MTKCore.Axis,
                                                    normalizedImagePoints points: [CGPoint],
                                                    dimensions: VolumeDimensions,
                                                    spacing: VolumeSpacing) -> Double? {
        guard let size = boundingSize(axis: axis,
                                      normalizedImagePoints: points,
                                      dimensions: dimensions,
                                      spacing: spacing) else {
            return nil
        }
        let area = Double.pi * size.width * size.height * 0.25
        return area.isFinite ? area : nil
    }

    public static func ellipseAreaPixels(axis: MTKCore.Axis,
                                         normalizedImagePoints points: [CGPoint],
                                         dimensions: VolumeDimensions) -> Double? {
        guard let size = boundingSizePixels(axis: axis,
                                           normalizedImagePoints: points,
                                           dimensions: dimensions) else {
            return nil
        }
        let area = Double.pi * size.width * size.height * 0.25
        return area.isFinite ? area : nil
    }

    public static func polylineLengthMillimeters(axis: MTKCore.Axis,
                                                 normalizedImagePoints points: [CGPoint],
                                                 dimensions: VolumeDimensions,
                                                 spacing: VolumeSpacing) -> Double? {
        guard points.count >= 2 else { return nil }
        let size = imageSize(axis: axis, dimensions: dimensions)
        let spacing = imageSpacing(axis: axis, spacing: spacing)
        return zip(points, points.dropFirst()).reduce(0.0) { total, pair in
            let deltaU = Double(pair.1.x - pair.0.x) * Double(max(size.width - 1, 0)) * spacing.u
            let deltaV = Double(pair.1.y - pair.0.y) * Double(max(size.height - 1, 0)) * spacing.v
            return total + (finiteDistance(deltaU: deltaU, deltaV: deltaV) ?? 0)
        }
    }

    public static func polylineLengthPixels(axis: MTKCore.Axis,
                                            normalizedImagePoints points: [CGPoint],
                                            dimensions: VolumeDimensions) -> Double? {
        guard points.count >= 2 else { return nil }
        let size = imageSize(axis: axis, dimensions: dimensions)
        return zip(points, points.dropFirst()).reduce(0.0) { total, pair in
            let deltaU = Double(pair.1.x - pair.0.x) * Double(max(size.width - 1, 0))
            let deltaV = Double(pair.1.y - pair.0.y) * Double(max(size.height - 1, 0))
            return total + (finiteDistance(deltaU: deltaU, deltaV: deltaV) ?? 0)
        }
    }

    public static func ctrRatio(axis: MTKCore.Axis,
                                normalizedImagePoints points: [CGPoint],
                                dimensions: VolumeDimensions? = nil,
                                spacing: VolumeSpacing? = nil) -> Double? {
        guard points.count >= 4 else { return nil }
        let thoraxPoints = [points[0], points[1]]
        let cardiacPoints = [points[2], points[3]]
        let thoraxDistance: Double?
        let cardiacDistance: Double?
        if let dimensions, let spacing {
            thoraxDistance = distanceMillimeters(axis: axis,
                                                normalizedImagePoints: thoraxPoints,
                                                dimensions: dimensions,
                                                spacing: spacing)
            cardiacDistance = distanceMillimeters(axis: axis,
                                                 normalizedImagePoints: cardiacPoints,
                                                 dimensions: dimensions,
                                                 spacing: spacing)
        } else if let dimensions {
            thoraxDistance = distancePixels(axis: axis,
                                            normalizedImagePoints: thoraxPoints,
                                            dimensions: dimensions)
            cardiacDistance = distancePixels(axis: axis,
                                             normalizedImagePoints: cardiacPoints,
                                             dimensions: dimensions)
        } else {
            thoraxDistance = finiteDistance(deltaU: Double(points[1].x - points[0].x),
                                            deltaV: Double(points[1].y - points[0].y))
            cardiacDistance = finiteDistance(deltaU: Double(points[3].x - points[2].x),
                                             deltaV: Double(points[3].y - points[2].y))
        }
        guard let thoraxDistance, let cardiacDistance, thoraxDistance > 0 else { return nil }
        let ratio = cardiacDistance / thoraxDistance
        return ratio.isFinite ? ratio : nil
    }

    private static func firstPointPair(_ points: [CGPoint]) -> (start: CGPoint, end: CGPoint)? {
        guard points.count >= 2 else { return nil }
        return (points[0], points[1])
    }

    private static func finiteDistance(deltaU: Double, deltaV: Double) -> Double? {
        guard deltaU.isFinite, deltaV.isFinite else { return nil }
        let distance = (deltaU * deltaU + deltaV * deltaV).squareRoot()
        return distance.isFinite ? distance : nil
    }

    private static func angleDegrees(lineAStart: CGPoint,
                                     lineAEnd: CGPoint,
                                     lineBStart: CGPoint,
                                     lineBEnd: CGPoint) -> Double? {
        let ax = Double(lineAEnd.x - lineAStart.x)
        let ay = Double(lineAEnd.y - lineAStart.y)
        let bx = Double(lineBEnd.x - lineBStart.x)
        let by = Double(lineBEnd.y - lineBStart.y)
        let lengthA = (ax * ax + ay * ay).squareRoot()
        let lengthB = (bx * bx + by * by).squareRoot()
        guard lengthA > 0, lengthB > 0 else { return nil }
        let cosine = min(max((ax * bx + ay * by) / (lengthA * lengthB), -1), 1)
        let degrees = acos(cosine) * 180.0 / .pi
        return degrees.isFinite ? degrees : nil
    }

    private static func finiteArea(points: [CGPoint]) -> Double? {
        guard points.count >= 3 else { return nil }
        var sum = 0.0
        for index in points.indices {
            let next = points[index == points.index(before: points.endIndex) ? points.startIndex : points.index(after: index)]
            let current = points[index]
            sum += Double(current.x * next.y - next.x * current.y)
        }
        let area = abs(sum) * 0.5
        return area.isFinite ? area : nil
    }

    private static func boundingSize(axis: MTKCore.Axis,
                                     normalizedImagePoints points: [CGPoint],
                                     dimensions: VolumeDimensions,
                                     spacing: VolumeSpacing) -> (width: Double, height: Double)? {
        guard let bounds = normalizedBounds(points) else { return nil }
        let size = imageSize(axis: axis, dimensions: dimensions)
        let spacing = imageSpacing(axis: axis, spacing: spacing)
        let width = Double(bounds.width) * Double(max(size.width - 1, 0)) * spacing.u
        let height = Double(bounds.height) * Double(max(size.height - 1, 0)) * spacing.v
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    private static func boundingSizePixels(axis: MTKCore.Axis,
                                           normalizedImagePoints points: [CGPoint],
                                           dimensions: VolumeDimensions) -> (width: Double, height: Double)? {
        guard let bounds = normalizedBounds(points) else { return nil }
        let size = imageSize(axis: axis, dimensions: dimensions)
        let width = Double(bounds.width) * Double(max(size.width - 1, 0))
        let height = Double(bounds.height) * Double(max(size.height - 1, 0))
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    private static func normalizedBounds(_ points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard rect.width.isFinite, rect.height.isFinite else { return nil }
        return rect
    }

    private static func imageSize(axis: MTKCore.Axis,
                                  dimensions: VolumeDimensions) -> (width: Int, height: Int) {
        switch axis {
        case .axial:
            return (dimensions.width, dimensions.height)
        case .coronal:
            return (dimensions.width, dimensions.depth)
        case .sagittal:
            return (dimensions.height, dimensions.depth)
        }
    }

    private static func imageSpacing(axis: MTKCore.Axis,
                                     spacing: VolumeSpacing) -> (u: Double, v: Double) {
        switch axis {
        case .axial:
            return (spacing.x, spacing.y)
        case .coronal:
            return (spacing.x, spacing.z)
        case .sagittal:
            return (spacing.y, spacing.z)
        }
    }
}

public struct ViewerROILabelmapVolumeSummary: Equatable, Sendable {
    public var layerID: String
    public var label: UInt16?
    public var segmentName: String?
    public var voxelCount: Int
    public var volumeCubicMillimeters: Double

    public init(layerID: String,
                label: UInt16?,
                segmentName: String?,
                voxelCount: Int,
                volumeCubicMillimeters: Double) {
        self.layerID = layerID
        self.label = label
        self.segmentName = segmentName
        self.voxelCount = voxelCount
        self.volumeCubicMillimeters = volumeCubicMillimeters.isFinite ? volumeCubicMillimeters : 0
    }

    public var measurement: ViewerROIMeasurement {
        .volumeCubicMillimeters(volumeCubicMillimeters)
    }
}

public enum ViewerROILabelmapVolumeError: Error, Equatable, LocalizedError {
    case missingLabelmap(String)
    case malformedLabelmap(String)
    case emptySelection(String, UInt16?)
    case invalidSpacing(String)

    public var errorDescription: String? {
        switch self {
        case .missingLabelmap(let id):
            return "ROI layer \(id) does not contain a labelmap volume."
        case .malformedLabelmap(let id):
            return "ROI layer \(id) has malformed labelmap data."
        case .emptySelection(let id, let label):
            if let label {
                return "ROI layer \(id) has no voxels for label \(label)."
            }
            return "ROI layer \(id) has no selected labelmap voxels."
        case .invalidSpacing(let id):
            return "ROI layer \(id) has invalid voxel spacing."
        }
    }
}

public enum ViewerROILabelmapVolumeCalculator {
    public static func summary(in layer: VolumeLayer,
                               label: UInt16? = nil) throws -> ViewerROILabelmapVolumeSummary {
        guard let labelmap = layer.labelmap else {
            throw ViewerROILabelmapVolumeError.missingLabelmap(layer.id)
        }
        guard labelmap.dataset.pixelFormat == .int16Unsigned,
              labelmap.dataset.data.count >= labelmap.dataset.dimensions.voxelCount * MemoryLayout<UInt16>.size else {
            throw ViewerROILabelmapVolumeError.malformedLabelmap(layer.id)
        }
        let spacing = labelmap.dataset.spacing
        let voxelVolume = spacing.x * spacing.y * spacing.z
        guard voxelVolume.isFinite, voxelVolume > 0 else {
            throw ViewerROILabelmapVolumeError.invalidSpacing(layer.id)
        }

        var voxelCount = 0
        for linearIndex in 0..<labelmap.dataset.dimensions.voxelCount {
            let storedLabel = readUInt16LittleEndian(labelmap.dataset.data, atLinearIndex: linearIndex)
            guard storedLabel > 0,
                  label == nil || storedLabel == label else {
                continue
            }
            voxelCount += 1
        }
        guard voxelCount > 0 else {
            throw ViewerROILabelmapVolumeError.emptySelection(layer.id, label)
        }
        let segmentName = label.flatMap { labelmap.segmentsByLabel[$0]?.name }
        return ViewerROILabelmapVolumeSummary(layerID: layer.id,
                                              label: label,
                                              segmentName: segmentName,
                                              voxelCount: voxelCount,
                                              volumeCubicMillimeters: Double(voxelCount) * voxelVolume)
    }

    private static func readUInt16LittleEndian(_ data: Data, atLinearIndex linearIndex: Int) -> UInt16 {
        let byteOffset = linearIndex * MemoryLayout<UInt16>.size
        let low = UInt16(data[byteOffset])
        let high = UInt16(data[byteOffset + 1]) << 8
        return low | high
    }
}

private extension MTKCore.Axis {
    var persistentIdentifier: String {
        switch self {
        case .axial:
            return "axial"
        case .coronal:
            return "coronal"
        case .sagittal:
            return "sagittal"
        }
    }
}
