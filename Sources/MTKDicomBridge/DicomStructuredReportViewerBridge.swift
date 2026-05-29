import CoreGraphics
import DicomCore
import Foundation
import MTKUI

public struct DicomStructuredReportViewerBridgeOptions: Equatable, Sendable {
    public var imageWidth: Int
    public var imageHeight: Int

    public init(imageWidth: Int, imageHeight: Int) {
        self.imageWidth = max(imageWidth, 1)
        self.imageHeight = max(imageHeight, 1)
    }
}

public enum DicomStructuredReportViewerBridge {
    public static func makeState(
        from document: DicomSRDocument,
        options: DicomStructuredReportViewerBridgeOptions
    ) -> StructuredReportViewerState {
        StructuredReportViewerState(
            title: title(for: document),
            subtitle: subtitle(for: document),
            treeRoot: treeNode(from: document.root, path: "0"),
            measurements: measurementLines(from: document.measurements),
            cadFindings: cadFindings(from: document.cadFindings, options: options)
        )
    }
}

private extension DicomStructuredReportViewerBridge {
    static func title(for document: DicomSRDocument) -> String {
        document.contentLabel
            ?? document.root.conceptName?.codeMeaning
            ?? document.root.conceptName?.codeValue
            ?? "Structured Report"
    }

    static func subtitle(for document: DicomSRDocument) -> String? {
        document.contentDescription
            ?? document.templateIdentifier.map { "Template \($0)" }
            ?? document.sopClassUID
    }

    static func treeNode(from item: DicomSRContentItem, path: String) -> StructuredReportTreeNode {
        StructuredReportTreeNode(
            id: path,
            title: item.conceptName?.codeMeaning ?? item.conceptName?.codeValue ?? item.valueType,
            subtitle: valueText(for: item),
            valueType: item.valueType,
            relationshipType: item.relationshipType,
            children: item.children.enumerated().map { index, child in
                treeNode(from: child, path: "\(path).\(index)")
            }
        )
    }

    static func measurementLines(from measurements: [DicomSRMeasurement]) -> [StructuredReportMeasurementLine] {
        measurements.enumerated().map { index, measurement in
            measurementLine(from: measurement, fallbackID: "measurement-\(index)")
        }
    }

    static func measurementLine(
        from measurement: DicomSRMeasurement,
        fallbackID: String
    ) -> StructuredReportMeasurementLine {
        let name = measurement.name?.codeMeaning ?? measurement.name?.codeValue ?? "Measurement"
        let unit = measurement.units?.codeMeaning ?? measurement.units?.codeValue
        return StructuredReportMeasurementLine(
            id: measurement.trackingID ?? measurement.trackingUID ?? fallbackID,
            name: name,
            value: measurement.value,
            unit: unit,
            sourceFrameNumbers: measurement.sourceImageReferences.flatMap(\.referencedFrameNumbers)
        )
    }

    static func cadFindings(
        from findings: [DicomSRCADFinding],
        options: DicomStructuredReportViewerBridgeOptions
    ) -> [CADFindingOverlayItem] {
        findings.enumerated().flatMap { findingIndex, finding in
            let regions = graphicRegions(in: finding.contentItem, options: options)
            return regions.enumerated().map { regionIndex, region in
                CADFindingOverlayItem(
                    id: finding.trackingID
                        ?? finding.trackingUID
                        ?? "cad-finding-\(findingIndex)-\(regionIndex)",
                    findingType: findingType(in: finding),
                    characteristics: characteristics(in: finding),
                    confidenceScore: confidenceScore(in: finding),
                    graphicRegion: region,
                    measurements: measurementLines(from: finding.measurements)
                )
            }
        }
    }

    static func graphicRegions(
        in item: DicomSRContentItem,
        options: DicomStructuredReportViewerBridgeOptions
    ) -> [StructuredReportGraphicRegion] {
        var result: [StructuredReportGraphicRegion] = []
        if item.valueType == "SCOORD",
           let kind = StructuredReportGraphicKind(dicomGraphicType: item.graphicType),
           item.graphicData.count >= 2 {
            result.append(StructuredReportGraphicRegion(
                kind: kind,
                normalizedPoints: normalizedPoints(from: item.graphicData, options: options),
                sourceFrameNumbers: item.allSourceImageReferences.flatMap(\.referencedFrameNumbers)
            ))
        }
        result.append(contentsOf: item.children.flatMap { graphicRegions(in: $0, options: options) })
        return result
    }

    static func findingType(in finding: DicomSRCADFinding) -> String {
        if let explicit = finding.contentItem.flattened.first(where: {
            $0.valueType == "CODE" &&
                contains($0.conceptName, "finding type") &&
                $0.codeValue != nil
        })?.codeValue {
            return codedText(explicit)
        }
        return finding.title.map(codedText) ?? "CAD Finding"
    }

    static func characteristics(in finding: DicomSRCADFinding) -> [String] {
        finding.contentItem.flattened.compactMap { item in
            guard item.valueType == "CODE",
                  contains(item.conceptName, "characteristic"),
                  let code = item.codeValue else {
                return nil
            }
            return codedText(code)
        }
    }

    static func confidenceScore(in finding: DicomSRCADFinding) -> Double? {
        finding.contentItem.flattened.first(where: {
            $0.valueType == "NUM" && contains($0.conceptName, "confidence")
        })?.numericValue
    }

    static func normalizedPoints(
        from graphicData: [Double],
        options: DicomStructuredReportViewerBridgeOptions
    ) -> [CGPoint] {
        stride(from: 0, to: graphicData.count - 1, by: 2).map {
            CGPoint(
                x: normalizedCoordinate(graphicData[$0], extent: options.imageWidth),
                y: normalizedCoordinate(graphicData[$0 + 1], extent: options.imageHeight)
            )
        }
    }

    static func normalizedCoordinate(_ value: Double, extent: Int) -> CGFloat {
        guard extent > 1 else { return 0 }
        let normalized = (value.rounded() - 1) / Double(extent - 1)
        guard normalized.isFinite else { return 0 }
        return CGFloat(min(max(normalized, 0), 1))
    }

    static func valueText(for item: DicomSRContentItem) -> String? {
        if let text = item.textValue { return text }
        if let code = item.codeValue { return codedText(code) }
        if let number = item.numericValue {
            if let units = item.measurementUnits {
                return "\(String(format: "%.3g", number)) \(codedText(units))"
            }
            return String(format: "%.3g", number)
        }
        if let uid = item.uidValue { return uid }
        if let dateTime = item.dateTimeValue { return dateTime.rawValue }
        if let date = item.dateValue { return date.rawValue }
        if let time = item.timeValue { return time.rawValue }
        if let personName = item.personNameValue { return personName.alphabetic }
        if let graphicType = item.graphicType { return graphicType }
        return nil
    }

    static func codedText(_ concept: DicomCodedConcept) -> String {
        concept.codeMeaning ?? concept.codeValue
    }

    static func contains(_ concept: DicomCodedConcept?, _ needle: String) -> Bool {
        let lowercasedNeedle = needle.lowercased()
        return [
            concept?.codeMeaning,
            concept?.codeValue
        ].compactMap { $0?.lowercased() }
            .contains { $0.contains(lowercasedNeedle) }
    }
}

private extension StructuredReportGraphicKind {
    init?(dicomGraphicType: String?) {
        switch dicomGraphicType?.uppercased() {
        case "POINT":
            self = .point
        case "POLYLINE":
            self = .polyline
        case "CIRCLE":
            self = .circle
        case "ELLIPSE":
            self = .ellipse
        default:
            return nil
        }
    }
}
