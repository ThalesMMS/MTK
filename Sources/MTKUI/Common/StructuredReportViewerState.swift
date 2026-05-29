import CoreGraphics
import Foundation

public enum StructuredReportGraphicKind: String, Codable, Equatable, Sendable {
    case point
    case polyline
    case circle
    case ellipse
}

public struct StructuredReportGraphicRegion: Codable, Equatable, Sendable {
    public var kind: StructuredReportGraphicKind
    public var normalizedPoints: [CGPoint]
    public var sourceFrameNumbers: [Int]

    public init(kind: StructuredReportGraphicKind,
                normalizedPoints: [CGPoint],
                sourceFrameNumbers: [Int] = []) {
        self.kind = kind
        self.normalizedPoints = normalizedPoints.map(Self.clampedPoint)
        self.sourceFrameNumbers = sourceFrameNumbers.filter { $0 > 0 }
    }

    private static func clampedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: clamp(point.x), y: clamp(point.y))
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public struct StructuredReportMeasurementLine: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var value: Double
    public var unit: String?
    public var displayText: String
    public var sourceFrameNumbers: [Int]

    public init(id: String,
                name: String,
                value: Double,
                unit: String? = nil,
                displayText: String? = nil,
                sourceFrameNumbers: [Int] = []) {
        self.id = id
        self.name = Self.sanitizedText(name, fallback: "Measurement")
        self.value = value.isFinite ? value : 0
        self.unit = unit.flatMap { Self.sanitizedOptionalText($0) }
        self.displayText = displayText.flatMap { Self.sanitizedOptionalText($0) }
            ?? Self.formattedDisplayText(value: self.value, unit: self.unit)
        self.sourceFrameNumbers = sourceFrameNumbers.filter { $0 > 0 }
    }

    private static func formattedDisplayText(value: Double, unit: String?) -> String {
        let valueText = String(format: "%.3g", value)
        guard let unit, !unit.isEmpty else { return valueText }
        return "\(valueText) \(unit)"
    }
}

public struct StructuredReportTreeNode: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var valueType: String
    public var relationshipType: String?
    public var children: [StructuredReportTreeNode]

    public init(id: String,
                title: String,
                subtitle: String? = nil,
                valueType: String,
                relationshipType: String? = nil,
                children: [StructuredReportTreeNode] = []) {
        self.id = id
        self.title = StructuredReportMeasurementLine.sanitizedText(title, fallback: valueType)
        self.subtitle = subtitle.flatMap { StructuredReportMeasurementLine.sanitizedOptionalText($0) }
        self.valueType = StructuredReportMeasurementLine.sanitizedText(valueType, fallback: "ITEM")
        self.relationshipType = relationshipType.flatMap { StructuredReportMeasurementLine.sanitizedOptionalText($0) }
        self.children = children
    }

    public var flattened: [StructuredReportTreeNode] {
        [self] + children.flatMap(\.flattened)
    }
}

public struct CADFindingOverlayItem: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var findingType: String
    public var characteristics: [String]
    public var confidenceScore: Double?
    public var graphicRegion: StructuredReportGraphicRegion
    public var measurements: [StructuredReportMeasurementLine]

    public init(id: String,
                findingType: String,
                characteristics: [String] = [],
                confidenceScore: Double? = nil,
                graphicRegion: StructuredReportGraphicRegion,
                measurements: [StructuredReportMeasurementLine] = []) {
        self.id = StructuredReportMeasurementLine.sanitizedText(id, fallback: UUID().uuidString)
        self.findingType = StructuredReportMeasurementLine.sanitizedText(findingType, fallback: "CAD Finding")
        self.characteristics = characteristics.compactMap(StructuredReportMeasurementLine.sanitizedOptionalText)
        self.confidenceScore = Self.sanitizedConfidence(confidenceScore)
        self.graphicRegion = graphicRegion
        self.measurements = measurements
    }

    public var summaryText: String {
        var parts = [findingType]
        if let confidenceScore {
            parts.append(String(format: "%.0f%%", confidenceScore * 100))
        }
        return parts.joined(separator: " ")
    }

    public var detailLines: [String] {
        var lines = [summaryText]
        if !characteristics.isEmpty {
            lines.append(characteristics.joined(separator: ", "))
        }
        lines.append(contentsOf: measurements.map(\.displayText))
        return lines
    }

    private static func sanitizedConfidence(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }
}

public struct StructuredReportViewerState: Codable, Equatable, Sendable {
    public var title: String
    public var subtitle: String?
    public var treeRoot: StructuredReportTreeNode
    public var measurements: [StructuredReportMeasurementLine]
    public var cadFindings: [CADFindingOverlayItem]
    public private(set) var selectedFindingID: CADFindingOverlayItem.ID?

    public init(title: String,
                subtitle: String? = nil,
                treeRoot: StructuredReportTreeNode,
                measurements: [StructuredReportMeasurementLine] = [],
                cadFindings: [CADFindingOverlayItem] = [],
                selectedFindingID: CADFindingOverlayItem.ID? = nil) {
        self.title = StructuredReportMeasurementLine.sanitizedText(title, fallback: "Structured Report")
        self.subtitle = subtitle.flatMap { StructuredReportMeasurementLine.sanitizedOptionalText($0) }
        self.treeRoot = treeRoot
        self.measurements = measurements
        self.cadFindings = cadFindings
        if let selectedFindingID,
           cadFindings.contains(where: { $0.id == selectedFindingID }) {
            self.selectedFindingID = selectedFindingID
        } else {
            self.selectedFindingID = cadFindings.first?.id
        }
    }

    public var selectedFinding: CADFindingOverlayItem? {
        guard let selectedFindingID else { return nil }
        return cadFindings.first { $0.id == selectedFindingID }
    }

    public mutating func selectFinding(id: CADFindingOverlayItem.ID?) {
        guard let id else {
            selectedFindingID = nil
            return
        }
        guard cadFindings.contains(where: { $0.id == id }) else { return }
        selectedFindingID = id
    }

    public func isSelected(_ finding: CADFindingOverlayItem) -> Bool {
        finding.id == selectedFindingID
    }
}

extension StructuredReportMeasurementLine {
    static func sanitizedOptionalText(_ text: String) -> String? {
        let cleaned = text
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(160))
    }

    static func sanitizedText(_ text: String, fallback: String) -> String {
        sanitizedOptionalText(text) ?? fallback
    }
}
