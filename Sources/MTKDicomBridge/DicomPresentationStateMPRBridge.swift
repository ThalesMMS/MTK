import DicomCore
import Foundation
import MTKCore
import simd

public struct DicomPresentationStateMPRBridgeOptions: Equatable, Sendable {
    public var axis: MTKCore.Axis
    public var imageWidth: Int
    public var imageHeight: Int

    public init(axis: MTKCore.Axis = .axial,
                imageWidth: Int,
                imageHeight: Int) {
        self.axis = axis
        self.imageWidth = max(imageWidth, 1)
        self.imageHeight = max(imageHeight, 1)
    }
}

public enum DicomPresentationStateMPRBridge {
    public static func makePresentationState(
        from presentationState: DicomGrayscalePresentationState,
        options: DicomPresentationStateMPRBridgeOptions
    ) -> MPRPresentationState {
        let baseTransform = viewportTransform(
            displayedArea: presentationState.displayedAreas.first,
            spatialTransform: presentationState.spatialTransform,
            imageWidth: options.imageWidth,
            imageHeight: options.imageHeight
        )
        return MPRPresentationState(
            id: presentationState.sopInstanceUID ?? UUID().uuidString,
            window: windowRange(from: presentationState.displayTransformProfile),
            invert: presentationState.displayTransformProfile.isPresentationInverted,
            viewportTransform: baseTransform,
            flipHorizontal: presentationState.spatialTransform.isHorizontallyFlipped,
            flipVertical: false,
            shutter: shutter(from: presentationState.shutters,
                             imageWidth: options.imageWidth,
                             imageHeight: options.imageHeight),
            graphicAnnotations: graphicAnnotations(
                from: presentationState,
                axis: options.axis,
                imageWidth: options.imageWidth,
                imageHeight: options.imageHeight
            ),
            iccProfile: presentationState.iccProfile
        )
    }

    private static func windowRange(from profile: DicomDisplayTransformProfile) -> ClosedRange<Int32>? {
        guard let window = profile.windows.first?.settings else { return nil }
        let lower = clampedInt32(window.center - window.width / 2.0)
        let upper = clampedInt32(window.center + window.width / 2.0)
        return min(lower, upper)...max(lower, upper)
    }

    private static func viewportTransform(displayedArea: DicomPresentationDisplayedArea?,
                                          spatialTransform: DicomPresentationSpatialTransform,
                                          imageWidth: Int,
                                          imageHeight: Int) -> MPRViewportTransform {
        let rotationRadians = Float(spatialTransform.rotationDegrees) * .pi / 180.0
        guard let displayedArea else {
            return MPRViewportTransform(rotationRadians: rotationRadians)
        }

        let left = normalizedPixelCoordinate(displayedArea.topLeft.x, extent: imageWidth)
        let top = normalizedPixelCoordinate(displayedArea.topLeft.y, extent: imageHeight)
        let right = normalizedPixelCoordinate(displayedArea.bottomRight.x, extent: imageWidth)
        let bottom = normalizedPixelCoordinate(displayedArea.bottomRight.y, extent: imageHeight)
        let minPoint = SIMD2<Float>(min(left, right), min(top, bottom))
        let maxPoint = SIMD2<Float>(max(left, right), max(top, bottom))
        let size = maxPoint - minPoint
        guard size.x > 0, size.y > 0 else {
            return MPRViewportTransform(rotationRadians: rotationRadians)
        }

        let zoom = max(1.0 / size.x, 1.0 / size.y)
        let center = (minPoint + maxPoint) * 0.5
        let pan = -(center - SIMD2<Float>(repeating: 0.5)) * zoom
        return MPRViewportTransform(zoom: zoom,
                                    pan: pan,
                                    rotationRadians: rotationRadians)
    }

    private static func shutter(from shutters: [DicomPresentationShutter],
                                imageWidth: Int,
                                imageHeight: Int) -> MPRPresentationShutter? {
        for shutter in shutters {
            switch shutter {
            case let .rectangular(left, right, upper, lower):
                let minPoint = normalizedPixelPoint(x: min(left, right),
                                                    y: min(upper, lower),
                                                    imageWidth: imageWidth,
                                                    imageHeight: imageHeight)
                let maxPoint = normalizedPixelPoint(x: max(left, right),
                                                    y: max(upper, lower),
                                                    imageWidth: imageWidth,
                                                    imageHeight: imageHeight)
                return .rectangular(min: minPoint, max: maxPoint)
            case let .circular(center, radius):
                let normalizedCenter = normalizedPixelPoint(x: center.x,
                                                            y: center.y,
                                                            imageWidth: imageWidth,
                                                            imageHeight: imageHeight)
                let normalizedRadius = Float(max(radius, 0)) / Float(max(max(imageWidth, imageHeight) - 1, 1))
                return .circular(center: normalizedCenter, radius: normalizedRadius)
            case .polygonal:
                continue
            }
        }
        return nil
    }

    private static func graphicAnnotations(from presentationState: DicomGrayscalePresentationState,
                                           axis: MTKCore.Axis,
                                           imageWidth: Int,
                                           imageHeight: Int) -> [MPRPresentationGraphicAnnotation] {
        let layersByName = Dictionary(uniqueKeysWithValues: presentationState.graphicLayers.map { ($0.name, $0) })
        var annotations: [MPRPresentationGraphicAnnotation] = []
        for group in presentationState.graphicAnnotations {
            let style = style(for: layersByName[group.graphicLayer])
            let sliceIndex = group.referencedImages.first?.referencedFrameNumbers.first.map { max($0 - 1, 0) }
            for (index, object) in group.graphicObjects.enumerated() {
                guard let kind = MPRPresentationGraphicKind(graphicType: object.graphicType,
                                                            filled: object.graphicFilled),
                      let points = normalizedPoints(from: object.graphicData,
                                                    units: object.annotationUnits,
                                                    imageWidth: imageWidth,
                                                    imageHeight: imageHeight),
                      !points.isEmpty else {
                    continue
                }
                annotations.append(MPRPresentationGraphicAnnotation(
                    id: object.trackingUID ?? object.trackingID ?? "\(group.graphicLayer)-graphic-\(index)",
                    kind: kind,
                    axis: axis,
                    sliceIndex: sliceIndex,
                    normalizedImagePoints: points,
                    layerName: group.graphicLayer,
                    style: style
                ))
            }
            for (index, object) in group.textObjects.enumerated() {
                let anchor = object.anchorPoint
                    ?? object.boundingBoxTopLeft
                    ?? object.boundingBoxBottomRight
                    ?? SIMD2<Double>(0.5, 0.5)
                annotations.append(MPRPresentationGraphicAnnotation(
                    id: "\(group.graphicLayer)-text-\(index)",
                    kind: .text,
                    axis: axis,
                    sliceIndex: sliceIndex,
                    normalizedImagePoints: [normalizedPoint(x: anchor.x,
                                                            y: anchor.y,
                                                            units: "PIXEL",
                                                            imageWidth: imageWidth,
                                                            imageHeight: imageHeight)],
                    text: object.text,
                    layerName: group.graphicLayer,
                    style: style
                ))
            }
        }
        return annotations
    }

    private static func normalizedPoints(from graphicData: [Double],
                                         units: String,
                                         imageWidth: Int,
                                         imageHeight: Int) -> [SIMD2<Float>]? {
        guard graphicData.count >= 2 else { return nil }
        return stride(from: 0, to: graphicData.count - 1, by: 2).map {
            normalizedPoint(x: graphicData[$0],
                            y: graphicData[$0 + 1],
                            units: units,
                            imageWidth: imageWidth,
                            imageHeight: imageHeight)
        }
    }

    private static func normalizedPoint(x: Double,
                                        y: Double,
                                        units: String,
                                        imageWidth: Int,
                                        imageHeight: Int) -> SIMD2<Float> {
        if units.uppercased() == "DISPLAY" {
            return SIMD2<Float>(clamp01(Float(x)), clamp01(Float(y)))
        }
        return normalizedPixelPoint(x: clampedInt32(x),
                                    y: clampedInt32(y),
                                    imageWidth: imageWidth,
                                    imageHeight: imageHeight)
    }

    private static func normalizedPixelPoint(x: Int32,
                                             y: Int32,
                                             imageWidth: Int,
                                             imageHeight: Int) -> SIMD2<Float> {
        SIMD2<Float>(
            normalizedPixelCoordinate(x, extent: imageWidth),
            normalizedPixelCoordinate(y, extent: imageHeight)
        )
    }

    private static func normalizedPixelCoordinate(_ value: Int32, extent: Int) -> Float {
        guard extent > 1 else { return 0 }
        return clamp01(Float(value - 1) / Float(extent - 1))
    }

    private static func style(for layer: DicomPresentationGraphicLayer?) -> MPRPresentationGraphicStyle {
        guard let layer,
              let grayscale = layer.recommendedDisplayGrayscaleValue else {
            return MPRPresentationGraphicStyle()
        }
        let value = Float(min(grayscale, 65_535)) / 65_535.0
        let color = SIMD4<Float>(value, value, value, 1)
        return MPRPresentationGraphicStyle(strokeColor: color, textColor: color)
    }

    private static func clampedInt32(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        return Int32(min(max(value.rounded(), Double(Int32.min)), Double(Int32.max)))
    }

    private static func clamp01(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

private extension MPRPresentationGraphicKind {
    init?(graphicType: String, filled: Bool?) {
        switch graphicType.uppercased() {
        case "POINT":
            self = .point
        case "POLYLINE", "INTERPOLATED":
            self = filled == true ? .polygon : .polyline
        case "CIRCLE", "ELLIPSE":
            self = .polygon
        default:
            return nil
        }
    }
}
