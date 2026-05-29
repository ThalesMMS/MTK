import CoreGraphics
import Foundation
import MTKCore

@MainActor
extension ClinicalViewportGridController {
    public func applyMPRPresentationState(_ presentationState: MPRPresentationState,
                                          to axis: MTKCore.Axis) async {
        mprPresentationStates[axis] = presentationState
        displayTransformsByAxis.removeValue(forKey: axis)

        if let window = presentationState.window {
            let width = Double(window.upperBound - window.lowerBound)
            let level = Double(window.lowerBound) + width / 2.0
            await setMPRWindowLevel(window: max(width, 1), level: level)
        }

        if let invert = presentationState.invert {
            setMPRWindowInverted(invert)
        }

        setMPRViewportTransform(presentationState.viewportTransform, for: axis)
        applyPresentationAnnotations(presentationState.graphicAnnotations,
                                     stateID: presentationState.id)
        scheduleRender(for: viewportID(for: axis))
    }

    public func clearMPRPresentationState(for axis: MTKCore.Axis) {
        guard let removed = mprPresentationStates.removeValue(forKey: axis) else { return }
        displayTransformsByAxis.removeValue(forKey: axis)
        mprROIStore.deleteAll(seriesIdentifier: removed.id)
        publishMPRROIAnnotations()
        scheduleRender(for: viewportID(for: axis))
    }

    private func applyPresentationAnnotations(_ annotations: [MPRPresentationGraphicAnnotation],
                                              stateID: String) {
        mprROIStore.deleteAll(seriesIdentifier: stateID)
        for annotation in annotations {
            guard let roiKind = ViewerROIKind(presentationKind: annotation.kind),
                  !annotation.normalizedImagePoints.isEmpty else {
                continue
            }
            let points = annotation.normalizedImagePoints.map {
                CGPoint(x: CGFloat($0.x), y: CGFloat($0.y))
            }
            mprROIStore.add(ViewerROIAnnotation(
                kind: roiKind,
                axis: annotation.axis,
                sliceIndex: annotation.sliceIndex,
                seriesIdentifier: stateID,
                normalizedImagePoints: points,
                text: ClinicalDisplayTextSanitizer.safeSeriesTitle(annotation.text),
                style: ViewerROIStyle(presentationStyle: annotation.style)
            ))
        }
        publishMPRROIAnnotations()
    }
}

private extension ViewerROIKind {
    init?(presentationKind: MPRPresentationGraphicKind) {
        switch presentationKind {
        case .point:
            self = .point
        case .polyline:
            self = .curvedLine
        case .polygon:
            self = .closedPath
        case .text:
            self = .text
        case .arrow:
            self = .arrow
        }
    }
}

private extension ViewerROIStyle {
    init(presentationStyle: MPRPresentationGraphicStyle) {
        self.init(
            strokeColor: ViewerROIColor(presentationColor: presentationStyle.strokeColor),
            textColor: ViewerROIColor(presentationColor: presentationStyle.textColor),
            labelBackgroundColor: .black,
            lineWidth: Double(presentationStyle.lineWidth)
        )
    }
}

private extension ViewerROIColor {
    init(presentationColor color: SIMD4<Float>) {
        self.init(red: Double(color.x),
                  green: Double(color.y),
                  blue: Double(color.z),
                  alpha: Double(color.w))
    }
}
