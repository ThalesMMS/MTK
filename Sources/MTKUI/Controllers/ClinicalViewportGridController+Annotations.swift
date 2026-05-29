import Foundation
import MTKCore

extension ClinicalViewportGridController {
    func mprImageAnnotationsOverlayState(slotIndex: Int,
                                         axis: MTKCore.Axis) -> MPRImageAnnotationsOverlayState {
        let transform = viewportTransform(for: axis)
        let metadata = currentDataset?.imageData.clinicalMetadata
        let viewportID = viewportID(for: axis)
        return MPRImageAnnotationsOverlayState(
            panelNumber: slotIndex + 1,
            axis: axis,
            subjectName: metadata?.patientName,
            studyTitle: metadata?.studyDescription,
            seriesTitle: metadata?.seriesDescription,
            imageSize: mprAnnotationImageSize(for: axis),
            windowLevel: windowLevel,
            slabThickness: slabThickness,
            zoom: transform.zoom,
            angleDegrees: crosshairAngles[axis] ?? 0,
            metadataSample: mprMetadataSample(),
            metadataOverlaySettings: metadataOverlaySettings(for: viewportID)
        )
    }

    public func setMetadataOverlaySettings(_ settings: ClinicalViewportMetadataOverlaySettings,
                                           for viewport: ViewportID) {
        guard allViewportIDs.contains(viewport) else { return }
        metadataOverlaySettingsByViewport[viewport] = settings
    }

    public func setMetadataOverlaySettings(_ settings: ClinicalViewportMetadataOverlaySettings,
                                           for axis: MTKCore.Axis) {
        setMetadataOverlaySettings(settings, for: viewportID(for: axis))
    }

    public func metadataOverlaySettings(for viewport: ViewportID) -> ClinicalViewportMetadataOverlaySettings {
        metadataOverlaySettingsByViewport[viewport] ?? .default
    }

    private func mprAnnotationImageSize(for axis: MTKCore.Axis) -> MPRImageAnnotationSize? {
        if let plane = currentMPRPlane(for: axis),
           let width = plane.outputWidth,
           let height = plane.outputHeight {
            return MPRImageAnnotationSize(width: width, height: height)
        }

        guard let dimensions = currentDataset?.dimensions else { return nil }
        switch axis {
        case .axial:
            return MPRImageAnnotationSize(width: dimensions.width, height: dimensions.height)
        case .coronal:
            return MPRImageAnnotationSize(width: dimensions.width, height: dimensions.depth)
        case .sagittal:
            return MPRImageAnnotationSize(width: dimensions.height, height: dimensions.depth)
        }
    }

    private func mprMetadataSample() -> ClinicalViewportMetadataSample? {
        guard let dataset = currentDataset,
              let worldPoint = mprCursorWorldPoint,
              let intensity = try? VolumePicking.sampleIntensity(in: dataset,
                                                                 atWorldPoint: worldPoint) else {
            return nil
        }
        let scalarSamples = (try? VolumePicking.sampleScalarVolumes(in: volumeLayers,
                                                                    atBaseWorldPoint: worldPoint)) ?? []
        let doseSamples = rtDoseOverlays.compactMap { overlay -> RTDoseSample? in
            guard overlay.volumeLayer.isVisible,
                  overlay.volumeLayer.clampedOpacity > 0 else {
                return nil
            }
            return try? overlay.sampleDose(atBaseWorldPoint: worldPoint)
        }
        return ClinicalViewportMetadataSample(intensity: intensity,
                                              scalarSamples: scalarSamples,
                                              doseSamples: doseSamples)
    }
}
