import DicomCore
import Foundation
import MTKCore
import simd

public struct DicomRTStructureContourOverlayOptions: Equatable, Sendable {
    public var overlayID: String?
    public var isVisible: Bool
    public var defaultDisplayColor: SIMD4<Float>

    public init(overlayID: String? = nil,
                isVisible: Bool = true,
                defaultDisplayColor: SIMD4<Float> = SIMD4<Float>(1, 0.86, 0.18, 1)) {
        self.overlayID = overlayID
        self.isVisible = isVisible
        self.defaultDisplayColor = defaultDisplayColor
    }
}

public struct DicomRTStructureSurfaceMeshLayerOptions: Equatable, Sendable {
    public var layerIDPrefix: String?
    public var opacity: Float
    public var isVisible: Bool

    public init(layerIDPrefix: String? = nil,
                opacity: Float = 0.65,
                isVisible: Bool = true) {
        self.layerIDPrefix = layerIDPrefix
        self.opacity = opacity
        self.isVisible = isVisible
    }
}

public enum DicomRTStructureContourOverlayBuilder {
    public static func makeOverlay(
        from structureSet: DicomRTStructureSet,
        options: DicomRTStructureContourOverlayOptions = DicomRTStructureContourOverlayOptions()
    ) -> RTStructureContourOverlay {
        let roisByNumber = Dictionary(uniqueKeysWithValues: structureSet.rois.map { ($0.number, $0) })
        var contours: [RTStructureContour] = []

        for roiContour in structureSet.roiContours {
            let roi = roisByNumber[roiContour.referencedROINumber]
            let color = displayColor(from: roiContour.displayColor,
                                     defaultColor: options.defaultDisplayColor)
            for (index, contour) in roiContour.contours.enumerated() where contour.points.count >= 2 {
                contours.append(RTStructureContour(
                    id: contourID(structureSet: structureSet,
                                  roiNumber: roiContour.referencedROINumber,
                                  contour: contour,
                                  index: index),
                    roiNumber: roiContour.referencedROINumber,
                    label: label(for: roi, roiNumber: roiContour.referencedROINumber),
                    geometricType: contour.geometricType,
                    displayColor: color,
                    patientPoints: contour.points
                ))
            }
        }

        return RTStructureContourOverlay(
            id: options.overlayID ?? structureSet.sopInstanceUID ?? UUID().uuidString,
            label: structureSet.label ?? structureSet.name,
            isVisible: options.isVisible,
            contours: contours
        )
    }

    public static func makeSurfaceMeshLayers(
        from structureSet: DicomRTStructureSet,
        contourOptions: DicomRTStructureContourOverlayOptions = DicomRTStructureContourOverlayOptions(),
        surfaceOptions: DicomRTStructureSurfaceMeshLayerOptions = DicomRTStructureSurfaceMeshLayerOptions()
    ) -> [SurfaceMeshLayer] {
        let overlay = makeOverlay(from: structureSet, options: contourOptions)
        return RTStructureSurfaceMeshExtractor().extractSurfaceMeshLayers(
            from: overlay,
            options: RTStructureSurfaceMeshOptions(
                layerIDPrefix: surfaceOptions.layerIDPrefix,
                opacity: surfaceOptions.opacity,
                isVisible: surfaceOptions.isVisible
            )
        )
    }

    private static func label(for roi: DicomRTROI?, roiNumber: Int) -> String {
        roi?.observationLabel ?? roi?.name ?? "ROI \(roiNumber)"
    }

    private static func contourID(structureSet: DicomRTStructureSet,
                                  roiNumber: Int,
                                  contour: DicomRTContour,
                                  index: Int) -> String {
        let baseID = structureSet.sopInstanceUID ?? "rtstruct"
        let contourNumber = contour.number ?? index + 1
        return "\(baseID).roi-\(roiNumber).contour-\(contourNumber)"
    }

    private static func displayColor(from value: [Int],
                                     defaultColor: SIMD4<Float>) -> SIMD4<Float> {
        guard value.count >= 3 else { return clampedColor(defaultColor) }
        return SIMD4<Float>(
            Float(clampColorComponent(value[0])) / 255,
            Float(clampColorComponent(value[1])) / 255,
            Float(clampColorComponent(value[2])) / 255,
            1
        )
    }

    private static func clampColorComponent(_ value: Int) -> Int {
        min(max(value, 0), 255)
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
