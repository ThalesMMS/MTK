import CoreGraphics
import Foundation
import MTKCore
import simd

@MainActor
extension ClinicalViewportGridController {
    public func setMPRROIKind(_ kind: ViewerROIKind, activateTool: Bool = true) {
        guard kind.isImplementedInMPRFirstDelivery else { return }
        mprROIKind = kind
        if activateTool {
            setMPRInteractionTool(.roi)
        }
    }

    @discardableResult
    public func addMPRROIFromGesture(axis: MTKCore.Axis,
                                     startImagePoint: CGPoint,
                                     endImagePoint: CGPoint) -> ViewerROIAnnotation? {
        let kind = mprROIKind
        guard kind.isImplementedInMPRFirstDelivery else { return nil }

        let points = ViewerROIPointFactory.points(kind: kind,
                                                  start: startImagePoint,
                                                  end: endImagePoint)
        let text = kind == .text ? "Annotation" : nil

        let annotation = ViewerROIAnnotation(
            kind: kind,
            axis: axis,
            sliceIndex: currentMPRSliceIndex(for: axis),
            normalizedImagePoints: points,
            text: sanitizedROIText(text),
            measurement: measurement(for: kind, axis: axis, points: points)
        )
        mprROIStore.add(annotation)
        publishMPRROIAnnotations()
        return annotation
    }

    public func labelmapVolumeSummary(layerID: String,
                                      label: UInt16? = nil) throws -> ViewerROILabelmapVolumeSummary {
        guard let layer = volumeLayers.first(where: { $0.id == layerID }) else {
            throw ViewerROILabelmapVolumeError.missingLabelmap(layerID)
        }
        return try ViewerROILabelmapVolumeCalculator.summary(in: layer, label: label)
    }

    @discardableResult
    public func addMPRROIAnnotation(kind: ViewerROIKind,
                                    axis: MTKCore.Axis,
                                    normalizedImagePoints: [CGPoint],
                                    text: String? = nil) -> ViewerROIAnnotation? {
        guard kind.isImplementedInMPRFirstDelivery else { return nil }
        let annotation = ViewerROIAnnotation(
            kind: kind,
            axis: axis,
            sliceIndex: currentMPRSliceIndex(for: axis),
            normalizedImagePoints: normalizedImagePoints,
            text: sanitizedROIText(text),
            measurement: measurement(for: kind, axis: axis, points: normalizedImagePoints)
        )
        mprROIStore.add(annotation)
        publishMPRROIAnnotations()
        return annotation
    }

    public func mprROIAnnotations(for axis: MTKCore.Axis) -> [ViewerROIAnnotation] {
        mprROIStore.annotations(axis: axis, sliceIndex: currentMPRSliceIndex(for: axis))
            + rtStructureROIAnnotations(for: axis)
    }

    public func deleteMPRROIsInActiveView() {
        deleteMPRROIs(axis: activeMPRAxis)
    }

    public func deleteMPRROIs(axis: MTKCore.Axis) {
        mprROIStore.deleteAnnotations(axis: axis, sliceIndex: currentMPRSliceIndex(for: axis))
        publishMPRROIAnnotations()
    }

    public func deleteAllMPRROIs() {
        mprROIStore.deleteAll()
        publishMPRROIAnnotations()
    }

    public func setRTStructureContourOverlays(_ overlays: [RTStructureContourOverlay]) {
        rtStructureContourOverlays = overlays
        publishMPRROIAnnotations()
    }

    public func setRTStructureContourConfiguration(_ configuration: RTStructureContourOverlayConfiguration) {
        rtStructureContourConfiguration = configuration
        publishMPRROIAnnotations()
    }

    public func setRTStructureContourSliceTolerance(_ tolerance: Double) {
        var configuration = rtStructureContourConfiguration
        configuration.sliceToleranceMillimeters = tolerance.isFinite ? max(tolerance, 0) : 1
        setRTStructureContourConfiguration(configuration)
    }

    public func normalizedMPRImagePoint(for axis: MTKCore.Axis,
                                        viewportLocation: CGPoint,
                                        viewportSize: CGSize) -> CGPoint? {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        let viewportPoint = SIMD2<Float>(
            Float(viewportLocation.x / viewportSize.width),
            Float(viewportLocation.y / viewportSize.height)
        )
        let layout = outputAspect(for: axis).layout(destinationSize: viewportSize)
        guard let imagePoint = layout.imagePoint(fromViewportPoint: viewportPoint) else { return nil }
        let imageScreenPoint = viewportTransform(for: axis)
            .imageScreenCoordinates(forViewportScreen: imagePoint)
        let texturePoint = displayTransform(for: axis)
            .textureCoordinates(forScreen: imageScreenPoint)
        return CGPoint(x: CGFloat(clampNormalized(texturePoint.x)),
                       y: CGFloat(clampNormalized(texturePoint.y)))
    }

    public func viewportPoint(forMPRROIImagePoint point: CGPoint,
                              axis: MTKCore.Axis,
                              viewportSize: CGSize) -> CGPoint {
        let texturePoint = SIMD2<Float>(Float(point.x), Float(point.y))
        let imageScreenPoint = displayTransform(for: axis)
            .screenCoordinates(forTexture: texturePoint)
        let viewportImagePoint = viewportTransform(for: axis)
            .screenCoordinates(forImageScreen: imageScreenPoint)
        let layout = outputAspect(for: axis).layout(destinationSize: viewportSize)
        let viewportPoint = layout.viewportPoint(fromImagePoint: viewportImagePoint)
        return CGPoint(x: CGFloat(viewportPoint.x) * viewportSize.width,
                       y: CGFloat(viewportPoint.y) * viewportSize.height)
    }

    func resetMPRROIAnnotations() {
        mprROIStore.deleteAll()
        publishMPRROIAnnotations()
    }

    func currentMPRSliceIndex(for axis: MTKCore.Axis) -> Int? {
        guard let count = sliceCount(for: axis), count > 0 else { return nil }
        let normalized = normalizedPositions[axis] ?? 0.5
        return Int((clampNormalized(normalized) * Float(max(count - 1, 0))).rounded())
    }

    private func measurement(for kind: ViewerROIKind,
                             axis: MTKCore.Axis,
                             points: [CGPoint]) -> ViewerROIMeasurement? {
        if kind == .distance,
           let plane = currentMPRPlane(for: axis),
           let millimeters = ViewerROIMeasurementCalculator.distanceMillimeters(
            normalizedImagePoints: points,
            plane: plane
           ) {
            return .distanceMillimeters(millimeters)
        }
        guard let dataset = currentDataset else {
            return nil
        }
        if kind == .distance,
           let millimeters = ViewerROIMeasurementCalculator.distanceMillimeters(
                axis: axis,
                normalizedImagePoints: points,
                dimensions: dataset.dimensions,
                spacing: dataset.spacing
              ) {
            return .distanceMillimeters(millimeters)
        }
        return ViewerROIMeasurementCalculator.measurement(kind: kind,
                                                          axis: axis,
                                                          normalizedImagePoints: points,
                                                          dimensions: dataset.dimensions,
                                                          spacing: dataset.spacing)
    }

    private func sanitizedROIText(_ text: String?) -> String? {
        guard let text else { return nil }
        return ClinicalDisplayTextSanitizer.safeSeriesTitle(text) ?? "Annotation"
    }

    func publishMPRROIAnnotations() {
        mprROIAnnotations = mprROIStore.annotations
            + MTKCore.Axis.allCases.flatMap { rtStructureROIAnnotations(for: $0) }
    }

    private func rtStructureROIAnnotations(for axis: MTKCore.Axis) -> [ViewerROIAnnotation] {
        guard let sliceIndex = currentMPRSliceIndex(for: axis),
              let plane = currentMPRPlane(for: axis) else {
            return []
        }
        return RTStructureContourOverlayProjector.annotations(
            for: rtStructureContourOverlays,
            axis: axis,
            sliceIndex: sliceIndex,
            plane: plane,
            configuration: rtStructureContourConfiguration
        )
    }
}
