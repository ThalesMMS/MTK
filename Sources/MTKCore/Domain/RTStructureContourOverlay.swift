import Foundation
import simd

public struct RTStructureContourOverlay: Equatable, Sendable {
    public var id: String
    public var label: String?
    public var isVisible: Bool
    public var contours: [RTStructureContour]

    public init(id: String = UUID().uuidString,
                label: String? = nil,
                isVisible: Bool = true,
                contours: [RTStructureContour]) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? UUID().uuidString
        self.label = label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.isVisible = isVisible
        self.contours = contours
    }
}

public struct RTStructureContour: Equatable, Sendable {
    public var id: String
    public var roiNumber: Int
    public var label: String
    public var geometricType: String
    public var displayColor: SIMD4<Float>
    public var patientPoints: [SIMD3<Double>]

    public init(id: String = UUID().uuidString,
                roiNumber: Int,
                label: String,
                geometricType: String,
                displayColor: SIMD4<Float> = SIMD4<Float>(1, 0.86, 0.18, 1),
                patientPoints: [SIMD3<Double>]) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? UUID().uuidString
        self.roiNumber = roiNumber
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "ROI \(roiNumber)"
        self.geometricType = geometricType.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "UNKNOWN"
        self.displayColor = Self.clampedColor(displayColor)
        self.patientPoints = patientPoints
    }

    public var isClosedPlanar: Bool {
        geometricType.uppercased().contains("CLOSED")
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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
