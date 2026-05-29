import CoreGraphics
import Foundation
import MTKCore
import simd

public struct RTStructureContourOverlayConfiguration: Equatable, Sendable {
    public var sliceToleranceMillimeters: Double
    public var showsLabels: Bool
    public var lineWidth: Double

    public init(sliceToleranceMillimeters: Double = 1,
                showsLabels: Bool = true,
                lineWidth: Double = 2) {
        self.sliceToleranceMillimeters = sliceToleranceMillimeters.isFinite
            ? max(sliceToleranceMillimeters, 0)
            : 1
        self.showsLabels = showsLabels
        self.lineWidth = lineWidth.isFinite ? max(lineWidth, 1) : 2
    }

    public static let `default` = RTStructureContourOverlayConfiguration()
}

public enum RTStructureContourOverlayProjector {
    public static func annotations(
        for overlays: [RTStructureContourOverlay],
        dataset: VolumeDataset,
        axis: MTKCore.Axis,
        sliceIndex: Int,
        configuration: RTStructureContourOverlayConfiguration = .default
    ) -> [ViewerROIAnnotation] {
        let count = sliceCount(for: axis, dimensions: dataset.dimensions)
        guard count > 0 else { return [] }
        let clampedSliceIndex = min(max(sliceIndex, 0), count - 1)
        let normalized = count > 1 ? Float(clampedSliceIndex) / Float(count - 1) : 0
        let plane = MPRPlaneGeometryFactory.makePlane(for: dataset,
                                                      axis: axis.mprPlaneAxis,
                                                      slicePosition: normalized)
        return projectedAnnotations(for: overlays,
                                    axis: axis,
                                    sliceIndex: clampedSliceIndex,
                                    plane: plane,
                                    configuration: configuration)
    }

    public static func annotations(
        for overlays: [RTStructureContourOverlay],
        axis: MTKCore.Axis,
        sliceIndex: Int,
        plane: MPRPlaneGeometry,
        configuration: RTStructureContourOverlayConfiguration = .default
    ) -> [ViewerROIAnnotation] {
        projectedAnnotations(for: overlays,
                             axis: axis,
                             sliceIndex: max(sliceIndex, 0),
                             plane: plane,
                             configuration: configuration)
    }
}

private extension RTStructureContourOverlayProjector {
    struct Projection {
        var points: [SIMD3<Float>]
        var renderAsClosedPath: Bool
    }

    static func projectedAnnotations(for overlays: [RTStructureContourOverlay],
                                     axis: MTKCore.Axis,
                                     sliceIndex: Int,
                                     plane: MPRPlaneGeometry,
                                     configuration: RTStructureContourOverlayConfiguration) -> [ViewerROIAnnotation] {
        overlays.flatMap { overlay in
            guard overlay.isVisible else { return [ViewerROIAnnotation]() }
            return overlay.contours.compactMap { contour in
                annotation(for: contour,
                           overlayID: overlay.id,
                           axis: axis,
                           sliceIndex: sliceIndex,
                           plane: plane,
                           configuration: configuration)
            }
        }
    }

    static func annotation(for contour: RTStructureContour,
                           overlayID: String,
                           axis: MTKCore.Axis,
                           sliceIndex: Int,
                           plane: MPRPlaneGeometry,
                           configuration: RTStructureContourOverlayConfiguration) -> ViewerROIAnnotation? {
        guard let projection = projectedContour(contour,
                                                onto: plane,
                                                toleranceMillimeters: Float(configuration.sliceToleranceMillimeters)) else {
            return nil
        }
        let normalizedPoints = projection.points.compactMap { normalizedImagePoint(for: $0, plane: plane) }
        guard projection.renderAsClosedPath ? normalizedPoints.count >= 3 : normalizedPoints.count >= 2 else {
            return nil
        }
        let kind: ViewerROIKind = projection.renderAsClosedPath ? .closedPath : .curvedLine
        return ViewerROIAnnotation(
            kind: kind,
            axis: axis,
            sliceIndex: sliceIndex,
            seriesIdentifier: overlayID,
            normalizedImagePoints: normalizedPoints,
            text: configuration.showsLabels ? label(for: contour) : nil,
            style: style(for: contour, configuration: configuration)
        )
    }

    static func projectedContour(_ contour: RTStructureContour,
                                 onto plane: MPRPlaneGeometry,
                                 toleranceMillimeters: Float) -> Projection? {
        let worldPoints = contour.patientPoints
            .map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
            .filter(isFinite)
        guard worldPoints.count >= 2 else { return nil }

        let normal = normalized(plane.normalWorld)
        let distances = worldPoints.map { simd_dot($0 - plane.originWorld, normal) }
        if distances.allSatisfy({ abs($0) <= toleranceMillimeters }) {
            return Projection(points: worldPoints,
                              renderAsClosedPath: contour.isClosedPlanar && worldPoints.count >= 3)
        }

        let edges = contourEdges(points: worldPoints, closed: contour.isClosedPlanar)
        var intersections: [SIMD3<Float>] = []
        for edge in edges {
            let d0 = simd_dot(edge.start - plane.originWorld, normal)
            let d1 = simd_dot(edge.end - plane.originWorld, normal)
            if abs(d0) <= toleranceMillimeters {
                appendUnique(edge.start, to: &intersections)
            }
            if d0 * d1 < 0 {
                let t = d0 / (d0 - d1)
                appendUnique(edge.start + t * (edge.end - edge.start), to: &intersections)
            } else if abs(d1) <= toleranceMillimeters {
                appendUnique(edge.end, to: &intersections)
            }
        }
        guard intersections.count >= 2 else { return nil }
        return Projection(points: intersections, renderAsClosedPath: false)
    }

    static func normalizedImagePoint(for worldPoint: SIMD3<Float>,
                                     plane: MPRPlaneGeometry) -> CGPoint? {
        let relative = worldPoint - plane.originWorld
        let uDenominator = simd_dot(plane.axisUWorld, plane.axisUWorld)
        let vDenominator = simd_dot(plane.axisVWorld, plane.axisVWorld)
        guard uDenominator > Float.ulpOfOne,
              vDenominator > Float.ulpOfOne else {
            return nil
        }
        let u = simd_dot(relative, plane.axisUWorld) / uDenominator
        let v = simd_dot(relative, plane.axisVWorld) / vDenominator
        guard u.isFinite, v.isFinite else { return nil }
        return CGPoint(x: CGFloat(u), y: CGFloat(v))
    }

    static func contourEdges(points: [SIMD3<Float>],
                             closed: Bool) -> [(start: SIMD3<Float>, end: SIMD3<Float>)] {
        var edges = zip(points, points.dropFirst()).map { (start: $0.0, end: $0.1) }
        if closed, let first = points.first, let last = points.last {
            edges.append((start: last, end: first))
        }
        return edges
    }

    static func appendUnique(_ point: SIMD3<Float>,
                             to points: inout [SIMD3<Float>]) {
        guard !points.contains(where: { simd_length($0 - point) < 0.0001 }) else { return }
        points.append(point)
    }

    static func label(for contour: RTStructureContour) -> String {
        ClinicalDisplayTextSanitizer.safeSeriesTitle(contour.label) ?? "ROI \(contour.roiNumber)"
    }

    static func style(for contour: RTStructureContour,
                      configuration: RTStructureContourOverlayConfiguration) -> ViewerROIStyle {
        let color = ViewerROIColor(
            red: Double(contour.displayColor.x),
            green: Double(contour.displayColor.y),
            blue: Double(contour.displayColor.z),
            alpha: Double(contour.displayColor.w)
        )
        return ViewerROIStyle(
            strokeColor: color,
            textColor: color,
            labelBackgroundColor: .black,
            lineWidth: configuration.lineWidth
        )
    }

    static func sliceCount(for axis: MTKCore.Axis,
                           dimensions: VolumeDimensions) -> Int {
        switch axis {
        case .axial:
            return dimensions.depth
        case .coronal:
            return dimensions.height
        case .sagittal:
            return dimensions.width
        }
    }

    static func normalized(_ vector: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(vector)
        guard length > Float.ulpOfOne else { return SIMD3<Float>(0, 0, 1) }
        return vector / length
    }

    static func isFinite(_ point: SIMD3<Float>) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
    }
}

private extension MTKCore.Axis {
    var mprPlaneAxis: MPRPlaneAxis {
        switch self {
        case .axial:
            return .z
        case .coronal:
            return .y
        case .sagittal:
            return .x
        }
    }
}
