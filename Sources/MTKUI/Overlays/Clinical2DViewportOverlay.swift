import Foundation
import MTKCore
import SwiftUI

public struct Clinical2DViewportOverlayState: Equatable, Sendable {
    public var axis: MTKCore.Axis
    public var subjectName: String?
    public var seriesTitle: String?
    public var imageSize: MPRImageAnnotationSize?
    public var windowLevel: WindowLevelShift
    public var sliceIndex: Int
    public var sliceCount: Int
    public var zoom: Double
    public var pan: SIMD2<Double>
    public var angleDegrees: Double
    public var isFlippedHorizontally: Bool
    public var isFlippedVertically: Bool
    public var slabThicknessMillimeters: Double?
    public var locationMillimeters: Double?
    public var activeTool: Clinical2DTool
    public var roiKind: ViewerROIKind
    public var roiAnnotations: [ViewerROIAnnotation]
    public var showsCrosshair: Bool
    public var hudSettings: TwoDHUDSettings

    public init(axis: MTKCore.Axis,
                subjectName: String? = nil,
                seriesTitle: String? = nil,
                imageSize: MPRImageAnnotationSize? = nil,
                windowLevel: WindowLevelShift,
                sliceIndex: Int,
                sliceCount: Int,
                zoom: Double,
                pan: SIMD2<Double> = .zero,
                angleDegrees: Double,
                isFlippedHorizontally: Bool = false,
                isFlippedVertically: Bool = false,
                slabThicknessMillimeters: Double? = nil,
                locationMillimeters: Double? = nil,
                activeTool: Clinical2DTool,
                roiKind: ViewerROIKind,
                roiAnnotations: [ViewerROIAnnotation] = [],
                showsCrosshair: Bool,
                hudSettings: TwoDHUDSettings = .default) {
        self.axis = axis
        self.subjectName = ClinicalDisplayTextSanitizer.safeSubjectName(subjectName)
        self.seriesTitle = ClinicalDisplayTextSanitizer.safeSeriesTitle(seriesTitle)
        self.imageSize = imageSize
        self.windowLevel = WindowLevelShift(window: windowLevel.window.isFinite ? windowLevel.window : 0,
                                            level: windowLevel.level.isFinite ? windowLevel.level : 0)
        self.sliceIndex = max(sliceIndex, 0)
        self.sliceCount = max(sliceCount, 0)
        self.zoom = zoom.isFinite ? max(zoom, 0) : 0
        self.pan = SIMD2<Double>(
            pan.x.isFinite ? pan.x : 0,
            pan.y.isFinite ? pan.y : 0
        )
        self.angleDegrees = angleDegrees.isFinite ? angleDegrees : 0
        self.isFlippedHorizontally = isFlippedHorizontally
        self.isFlippedVertically = isFlippedVertically
        self.slabThicknessMillimeters = Self.sanitizedNonNegative(slabThicknessMillimeters)
        self.locationMillimeters = locationMillimeters?.isFinite == true ? locationMillimeters : nil
        self.activeTool = activeTool
        self.roiKind = roiKind
        self.roiAnnotations = roiAnnotations
        self.showsCrosshair = showsCrosshair
        self.hudSettings = hudSettings
    }

    public var topLeadingLines: [String] {
        var lines: [String] = []
        if hudSettings.showsSubjectName, let subjectName {
            lines.append(subjectName)
        }
        guard hudSettings.showsTechnicalText else { return lines }
        if let imageSize {
            lines.append("Image size: \(imageSize.displayText)")
        }
        lines.append("WW: \(formatted(windowLevel.window)) WL: \(formatted(windowLevel.level))")
        return lines
    }

    public var topTrailingLines: [String] {
        var lines: [String] = []
        if hudSettings.showsSeriesTitle, let seriesTitle {
            lines.append(seriesTitle)
        }
        guard hudSettings.showsTechnicalText else { return lines }
        lines.append("Axis: \(axis.clinicalDisplayName)")
        lines.append("Tool: \(activeTool.title)")
        lines.append("ROI: \(roiKind.displayName)")
        return lines
    }

    public var bottomLeadingLines: [String] {
        guard hudSettings.showsTechnicalText else { return [] }
        var lines = [
            "Zoom: \(formatted(zoom * 100))%",
            "Angle: \(formatted(angleDegrees)) deg",
            "Image: \(displaySliceIndex)/\(max(sliceCount, 0))"
        ]
        if let slabThicknessMillimeters {
            lines.append("Thickness: \(formatted(slabThicknessMillimeters, fractionDigits: 2)) mm")
        }
        if let locationMillimeters {
            lines.append("Location: \(formatted(locationMillimeters, fractionDigits: 2)) mm")
        }
        return lines
    }

    public var axisIdentifier: String {
        switch axis {
        case .axial:
            return "axial"
        case .coronal:
            return "coronal"
        case .sagittal:
            return "sagittal"
        }
    }

    var orientationLabels: (leading: String, trailing: String, top: String, bottom: String) {
        switch axis {
        case .axial:
            return (leading: "R", trailing: "L", top: "A", bottom: "P")
        case .coronal:
            return (leading: "R", trailing: "L", top: "S", bottom: "I")
        case .sagittal:
            return (leading: "A", trailing: "P", top: "S", bottom: "I")
        }
    }

    var crosshairAngleDegrees: Double {
        isFlippedHorizontally != isFlippedVertically ? -angleDegrees : angleDegrees
    }

    private var displaySliceIndex: Int {
        guard sliceCount > 0 else { return 0 }
        return min(sliceIndex + 1, sliceCount)
    }

    private static func sanitizedNonNegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return max(value, 0)
    }

    private func formatted(_ value: Double, fractionDigits: Int = 0) -> String {
        String(format: "%.\(fractionDigits)f", value)
    }
}

public struct Clinical2DViewportOverlay: View {
    private let state: Clinical2DViewportOverlayState
    private let style: any VolumetricUIStyle

    public init(state: Clinical2DViewportOverlayState,
                style: any VolumetricUIStyle = DefaultVolumetricUIStyle()) {
        self.state = state
        self.style = style
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.cyan.opacity(0.72), lineWidth: 1)
                .padding(6)
                .allowsHitTesting(false)

            if state.hudSettings.showsOrientationMarkers {
                OrientationOverlayView(labels: state.orientationLabels, style: style)
                    .padding(24)
                    .allowsHitTesting(false)
            }

            if state.showsCrosshair {
                GeometryReader { proxy in
                    CrosshairOverlayView(
                        style: style,
                        position: CGPoint(x: state.pan.x * proxy.size.width,
                                          y: state.pan.y * proxy.size.height),
                        angle: Angle(degrees: state.crosshairAngleDegrees),
                        accessibilityIdentifier: "Clinical2DCrosshair"
                    )
                }
                .padding(8)
                .allowsHitTesting(false)
            }

            Clinical2DROILayer(state: state, style: style)
                .padding(8)
                .allowsHitTesting(false)

            Clinical2DHUDOverlay(state: state, style: style)
        }
        .padding(6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Clinical2DViewportOverlay")
    }
}

private struct Clinical2DROILayer: View {
    let state: Clinical2DViewportOverlayState
    let style: any VolumetricUIStyle

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(state.roiAnnotations) { annotation in
                    annotationView(annotation, size: proxy.size)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Clinical2DROILayer")
    }

    @ViewBuilder
    private func annotationView(_ annotation: ViewerROIAnnotation,
                                size: CGSize) -> some View {
        switch annotation.kind {
        case .distance:
            if annotation.normalizedImagePoints.count >= 2 {
                let start = viewportPoint(for: annotation.normalizedImagePoints[0], size: size)
                let end = viewportPoint(for: annotation.normalizedImagePoints[1], size: size)
                line(from: start, to: end, annotation: annotation)
                pointMarker(at: start, annotation: annotation)
                pointMarker(at: end, annotation: annotation)
                label(annotation.measurement?.displayText ?? annotation.kind.displayName, annotation: annotation)
                    .position(labelPoint(points: [start, end], yOffset: -14))
            }
        case .angle:
            if annotation.normalizedImagePoints.count >= 3 {
                let points = annotation.normalizedImagePoints.prefix(3).map { viewportPoint(for: $0, size: size) }
                polyline(points: points, annotation: annotation)
                label(annotation.measurement?.displayText ?? annotation.kind.displayName, annotation: annotation)
                    .position(labelPoint(points: points, yOffset: -12))
            }
        case .cobbAngle:
            if annotation.normalizedImagePoints.count >= 4 {
                let points = annotation.normalizedImagePoints.prefix(4).map { viewportPoint(for: $0, size: size) }
                line(from: points[0], to: points[1], annotation: annotation)
                line(from: points[2], to: points[3], annotation: annotation)
                label(annotation.measurement?.displayText ?? annotation.kind.displayName, annotation: annotation)
                    .position(labelPoint(points: points, yOffset: -12))
            }
        case .point:
            if let point = annotation.normalizedImagePoints.first {
                pointMarker(at: viewportPoint(for: point, size: size), annotation: annotation)
            }
        case .area, .closedPath:
            if annotation.normalizedImagePoints.count >= 3 {
                let points = annotation.normalizedImagePoints.map { viewportPoint(for: $0, size: size) }
                polygon(points: points, annotation: annotation)
                label(annotation.measurement?.displayText ?? annotation.kind.displayName, annotation: annotation)
                    .position(labelPoint(points: points))
            }
        case .curvedLine, .scribble:
            if annotation.normalizedImagePoints.count >= 2 {
                let points = annotation.normalizedImagePoints.map { viewportPoint(for: $0, size: size) }
                polyline(points: points, annotation: annotation)
                if let measurement = annotation.measurement {
                    label(measurement.displayText, annotation: annotation)
                        .position(labelPoint(points: points, yOffset: -12))
                }
            }
        case .text:
            if let point = annotation.normalizedImagePoints.first {
                label(annotation.text ?? "Annotation", annotation: annotation)
                    .position(viewportPoint(for: point, size: size))
            }
        case .arrow:
            if annotation.normalizedImagePoints.count >= 2 {
                arrow(from: viewportPoint(for: annotation.normalizedImagePoints[0], size: size),
                      to: viewportPoint(for: annotation.normalizedImagePoints[1], size: size),
                      annotation: annotation)
            }
        case .ctr:
            if annotation.normalizedImagePoints.count >= 4 {
                let points = annotation.normalizedImagePoints.prefix(4).map { viewportPoint(for: $0, size: size) }
                line(from: points[0], to: points[1], annotation: annotation)
                line(from: points[2], to: points[3], annotation: annotation)
                label(annotation.measurement?.displayText ?? annotation.kind.displayName, annotation: annotation)
                    .position(labelPoint(points: points, yOffset: -12))
            }
        }
    }

    private func viewportPoint(for point: CGPoint,
                               size: CGSize) -> CGPoint {
        var x = Double(point.x) - 0.5
        var y = Double(point.y) - 0.5

        if state.isFlippedHorizontally { x = -x }
        if state.isFlippedVertically { y = -y }

        let radians = state.angleDegrees * .pi / 180.0
        let cosTheta = cos(radians)
        let sinTheta = sin(radians)
        let rotatedX = x * cosTheta - y * sinTheta
        let rotatedY = x * sinTheta + y * cosTheta
        let zoom = state.zoom.isFinite && state.zoom > 0 ? state.zoom : 1

        x = rotatedX * zoom + state.pan.x + 0.5
        y = rotatedY * zoom + state.pan.y + 0.5
        return CGPoint(x: x * size.width, y: y * size.height)
    }

    private func line(from start: CGPoint,
                      to end: CGPoint,
                      annotation: ViewerROIAnnotation) -> some View {
        Path { path in
            path.move(to: start)
            path.addLine(to: end)
        }
        .stroke(Color(viewerROIColor: annotation.style.strokeColor),
                style: StrokeStyle(lineWidth: annotation.style.lineWidth, lineCap: .round))
    }

    private func polyline(points: [CGPoint],
                          annotation: ViewerROIAnnotation) -> some View {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
        .stroke(Color(viewerROIColor: annotation.style.strokeColor),
                style: StrokeStyle(lineWidth: annotation.style.lineWidth, lineCap: .round, lineJoin: .round))
    }

    private func polygon(points: [CGPoint],
                         annotation: ViewerROIAnnotation) -> some View {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
        }
        .stroke(Color(viewerROIColor: annotation.style.strokeColor),
                style: StrokeStyle(lineWidth: annotation.style.lineWidth, lineCap: .round, lineJoin: .round))
    }

    private func arrow(from start: CGPoint,
                       to end: CGPoint,
                       annotation: ViewerROIAnnotation) -> some View {
        Path { path in
            path.move(to: start)
            path.addLine(to: end)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let arrowLength: CGFloat = 13
            let spread: CGFloat = .pi / 7
            path.move(to: end)
            path.addLine(to: CGPoint(x: end.x - arrowLength * cos(angle - spread),
                                     y: end.y - arrowLength * sin(angle - spread)))
            path.move(to: end)
            path.addLine(to: CGPoint(x: end.x - arrowLength * cos(angle + spread),
                                     y: end.y - arrowLength * sin(angle + spread)))
        }
        .stroke(Color(viewerROIColor: annotation.style.strokeColor),
                style: StrokeStyle(lineWidth: annotation.style.lineWidth, lineCap: .round, lineJoin: .round))
    }

    private func pointMarker(at point: CGPoint,
                             annotation: ViewerROIAnnotation) -> some View {
        Circle()
            .stroke(Color(viewerROIColor: annotation.style.strokeColor),
                    lineWidth: annotation.style.lineWidth)
            .frame(width: 10, height: 10)
            .position(point)
    }

    private func label(_ text: String,
                       annotation: ViewerROIAnnotation) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(Color(viewerROIColor: annotation.style.textColor))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(Color(viewerROIColor: annotation.style.labelBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func labelPoint(points: [CGPoint],
                            yOffset: CGFloat = 0) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let x = points.reduce(0) { $0 + $1.x } / CGFloat(points.count)
        let y = points.reduce(0) { $0 + $1.y } / CGFloat(points.count) + yOffset
        return CGPoint(x: x, y: y)
    }
}

private extension Color {
    init(viewerROIColor color: ViewerROIColor) {
        self.init(red: color.red,
                  green: color.green,
                  blue: color.blue,
                  opacity: color.alpha)
    }
}
