import Foundation
import MTKCore

extension ClinicalViewportGridController {
    func mprImageAnnotationsOverlayState(slotIndex: Int,
                                         axis: MTKCore.Axis) -> MPRImageAnnotationsOverlayState {
        let transform = viewportTransform(for: axis)
        return MPRImageAnnotationsOverlayState(
            panelNumber: slotIndex + 1,
            axis: axis,
            imageSize: mprAnnotationImageSize(for: axis),
            windowLevel: windowLevel,
            slabThickness: slabThickness,
            zoom: transform.zoom,
            angleDegrees: crosshairAngles[axis] ?? 0
        )
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
}
