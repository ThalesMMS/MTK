import SwiftUI

public struct CADFindingOverlayView: View {
    private let findings: [CADFindingOverlayItem]
    private let selectedFindingID: CADFindingOverlayItem.ID?

    public init(findings: [CADFindingOverlayItem],
                selectedFindingID: CADFindingOverlayItem.ID? = nil) {
        self.findings = findings
        self.selectedFindingID = selectedFindingID
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(findings) { finding in
                    findingView(finding, size: proxy.size)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CADFindingOverlay")
    }

    @ViewBuilder
    private func findingView(_ finding: CADFindingOverlayItem,
                             size: CGSize) -> some View {
        let points = finding.graphicRegion.normalizedPoints.map { viewportPoint($0, size: size) }
        switch finding.graphicRegion.kind {
        case .point:
            if let point = points.first {
                pointMarker(at: point, finding: finding)
                label(finding.summaryText, finding: finding)
                    .position(CGPoint(x: point.x, y: max(point.y - 16, 8)))
            }
        case .polyline:
            if points.count >= 2 {
                polyline(points: points, finding: finding)
                label(finding.summaryText, finding: finding)
                    .position(labelPoint(points: points, yOffset: -12))
            }
        case .circle:
            if points.count >= 2 {
                circle(points: points, finding: finding)
                label(finding.summaryText, finding: finding)
                    .position(labelPoint(points: points, yOffset: -12))
            }
        case .ellipse:
            if points.count >= 2 {
                ellipse(points: points, finding: finding)
                label(finding.summaryText, finding: finding)
                    .position(labelPoint(points: points, yOffset: -12))
            }
        }
    }

    private func viewportPoint(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    private func pointMarker(at point: CGPoint,
                             finding: CADFindingOverlayItem) -> some View {
        Circle()
            .stroke(strokeColor(for: finding), lineWidth: strokeWidth(for: finding))
            .frame(width: isSelected(finding) ? 14 : 10, height: isSelected(finding) ? 14 : 10)
            .position(point)
    }

    private func polyline(points: [CGPoint],
                          finding: CADFindingOverlayItem) -> some View {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
        .stroke(strokeColor(for: finding),
                style: StrokeStyle(lineWidth: strokeWidth(for: finding), lineCap: .round, lineJoin: .round))
    }

    private func circle(points: [CGPoint],
                        finding: CADFindingOverlayItem) -> some View {
        let center = points[0]
        let edge = points[1]
        let radius = max(hypot(edge.x - center.x, edge.y - center.y), 1)
        return Circle()
            .stroke(strokeColor(for: finding),
                    style: StrokeStyle(lineWidth: strokeWidth(for: finding), lineCap: .round, lineJoin: .round))
            .frame(width: radius * 2, height: radius * 2)
            .position(center)
    }

    private func ellipse(points: [CGPoint],
                         finding: CADFindingOverlayItem) -> some View {
        let rect = boundingRect(points: points)
        return Ellipse()
            .stroke(strokeColor(for: finding),
                    style: StrokeStyle(lineWidth: strokeWidth(for: finding), lineCap: .round, lineJoin: .round))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    private func label(_ text: String,
                       finding: CADFindingOverlayItem) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(strokeColor(for: finding))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(.black.opacity(isSelected(finding) ? 0.82 : 0.64),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func strokeColor(for finding: CADFindingOverlayItem) -> Color {
        isSelected(finding) ? .orange : .yellow
    }

    private func strokeWidth(for finding: CADFindingOverlayItem) -> CGFloat {
        isSelected(finding) ? 3 : 2
    }

    private func isSelected(_ finding: CADFindingOverlayItem) -> Bool {
        finding.id == selectedFindingID
    }

    private func labelPoint(points: [CGPoint],
                            yOffset: CGFloat = 0) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let x = points.reduce(0) { $0 + $1.x } / CGFloat(points.count)
        let y = points.reduce(0) { $0 + $1.y } / CGFloat(points.count) + yOffset
        return CGPoint(x: x, y: y)
    }

    private func boundingRect(points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
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
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    }
}
