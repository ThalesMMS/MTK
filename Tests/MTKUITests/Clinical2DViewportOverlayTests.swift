@testable import MTKUI
import MTKCore
import SwiftUI
import XCTest

final class Clinical2DViewportOverlayTests: XCTestCase {
    func testOverlayStateBuildsPrivacySafeTechnicalLines() {
        let state = Clinical2DViewportOverlayState(
            axis: .axial,
            imageSize: MPRImageAnnotationSize(width: 512, height: 512),
            windowLevel: WindowLevelShift(window: 120, level: 40),
            sliceIndex: 99,
            sliceCount: 211,
            zoom: 0.83,
            pan: SIMD2<Double>(0.1, -0.2),
            angleDegrees: 0,
            slabThicknessMillimeters: 2,
            locationMillimeters: 453,
            activeTool: .scroll,
            roiKind: .distance,
            showsCrosshair: false
        )
        let lines = state.topLeadingLines + state.topTrailingLines + state.bottomLeadingLines

        XCTAssertEqual(state.orientationLabels.leading, "R")
        XCTAssertEqual(state.orientationLabels.trailing, "L")
        XCTAssertEqual(state.orientationLabels.top, "A")
        XCTAssertEqual(state.orientationLabels.bottom, "P")
        XCTAssertEqual(state.pan, SIMD2<Double>(0.1, -0.2))
        XCTAssertTrue(lines.contains("Image size: 512x512"))
        XCTAssertTrue(lines.contains("WW: 120 WL: 40"))
        XCTAssertTrue(lines.contains("Image: 100/211"))
        XCTAssertFalse(lines.contains { ClinicalDisplayTextSanitizer.containsBlockedViewerText($0) })
    }

    func testHUDStateFormatsSubjectAndSeriesSafely() {
        let state = Clinical2DViewportOverlayState(
            axis: .axial,
            subjectName: "Sample^Subject",
            studyTitle: "  CT   Chest  ",
            seriesTitle: "  CT   Abdomen Venous  ",
            windowLevel: WindowLevelShift(window: 400, level: 40),
            sliceIndex: 0,
            sliceCount: 1,
            zoom: 1,
            angleDegrees: 0,
            activeTool: .scroll,
            roiKind: .distance,
            showsCrosshair: false
        )

        XCTAssertTrue(state.topLeadingLines.contains("Sample Subject"))
        XCTAssertTrue(state.topTrailingLines.contains("Study: CT Chest"))
        XCTAssertTrue(state.topTrailingLines.contains("CT Abdomen Venous"))
        XCTAssertFalse((state.topLeadingLines + state.topTrailingLines).contains { ClinicalDisplayTextSanitizer.containsBlockedViewerText($0) })
    }

    func testHUDStateOmitsUnavailableAndUnsafeOptionalText() {
        let state = Clinical2DViewportOverlayState(
            axis: .axial,
            subjectName: nil,
            studyTitle: "0010,0010 Patient Name",
            seriesTitle: "Patient ID 123456",
            windowLevel: WindowLevelShift(window: 400, level: 40),
            sliceIndex: 0,
            sliceCount: 1,
            zoom: 1,
            angleDegrees: 0,
            activeTool: .scroll,
            roiKind: .distance,
            showsCrosshair: false
        )

        XCTAssertFalse(state.topLeadingLines.contains("Unknown"))
        XCTAssertFalse(state.topTrailingLines.contains("0010,0010 Patient Name"))
        XCTAssertFalse(state.topTrailingLines.contains("Patient ID 123456"))
    }

    func testMetadataSampleDisplaysPixelSUVAndDoseWhenPresent() {
        let state = Clinical2DViewportOverlayState(
            axis: .axial,
            windowLevel: WindowLevelShift(window: 400, level: 40),
            sliceIndex: 0,
            sliceCount: 1,
            zoom: 1,
            angleDegrees: 0,
            activeTool: .scroll,
            roiKind: .distance,
            showsCrosshair: false,
            metadataSample: makeMetadataSample()
        )

        XCTAssertEqual(state.bottomTrailingLines, [
            "Pixel: 42",
            "SUV: 4.25 SUV body weight",
            "Dose: 2.00 GY"
        ])
    }

    func testMetadataOverlaySettingsCanHideValuesPerViewportState() {
        let visible = makeState(axis: .axial, metadataSample: makeMetadataSample())
        let hidden = makeState(
            axis: .axial,
            metadataSample: makeMetadataSample(),
            metadataOverlaySettings: ClinicalViewportMetadataOverlaySettings(
                showsPixelValue: false,
                showsQuantitativeValues: false,
                showsDoseValues: false
            )
        )
        let disabled = makeState(
            axis: .axial,
            metadataSample: makeMetadataSample(),
            metadataOverlaySettings: ClinicalViewportMetadataOverlaySettings(isVisible: false)
        )

        XCTAssertTrue(visible.bottomTrailingLines.contains("Pixel: 42"))
        XCTAssertEqual(hidden.bottomTrailingLines, [])
        XCTAssertEqual(disabled.topLeadingLines, [])
        XCTAssertEqual(disabled.topTrailingLines, [])
        XCTAssertEqual(disabled.bottomLeadingLines, [])
        XCTAssertEqual(disabled.bottomTrailingLines, [])
    }

    func testOverlayStateUsesPlaneSpecificOrientationLabels() {
        let coronal = makeState(axis: .coronal)
        let sagittal = makeState(axis: .sagittal)

        XCTAssertEqual(coronal.orientationLabels.leading, "R")
        XCTAssertEqual(coronal.orientationLabels.trailing, "L")
        XCTAssertEqual(coronal.orientationLabels.top, "S")
        XCTAssertEqual(coronal.orientationLabels.bottom, "I")
        XCTAssertEqual(sagittal.orientationLabels.leading, "A")
        XCTAssertEqual(sagittal.orientationLabels.trailing, "P")
        XCTAssertEqual(sagittal.orientationLabels.top, "S")
        XCTAssertEqual(sagittal.orientationLabels.bottom, "I")
    }

    func testCrosshairAngleFollowsImageTransformWithoutChangingHUDAngle() {
        let mirrored = Clinical2DViewportOverlayState(
            axis: .axial,
            windowLevel: WindowLevelShift(window: 400, level: 40),
            sliceIndex: 0,
            sliceCount: 1,
            zoom: 1,
            angleDegrees: 30,
            isFlippedHorizontally: true,
            activeTool: .rotation,
            roiKind: .distance,
            showsCrosshair: true
        )
        let doubleMirrored = Clinical2DViewportOverlayState(
            axis: .axial,
            windowLevel: WindowLevelShift(window: 400, level: 40),
            sliceIndex: 0,
            sliceCount: 1,
            zoom: 1,
            angleDegrees: 30,
            isFlippedHorizontally: true,
            isFlippedVertically: true,
            activeTool: .rotation,
            roiKind: .distance,
            showsCrosshair: true
        )

        XCTAssertEqual(mirrored.angleDegrees, 30)
        XCTAssertEqual(mirrored.crosshairAngleDegrees, -30)
        XCTAssertEqual(doubleMirrored.crosshairAngleDegrees, 30)
    }

#if os(macOS)
    @MainActor
    func testPointROIRendersInFullViewportCoordinateSpace() throws {
        let viewportSize = CGSize(width: 800, height: 600)
        let expectedCenterX = 100.0
        let annotation = ViewerROIAnnotation(
            kind: .point,
            axis: .axial,
            normalizedImagePoints: [CGPoint(x: expectedCenterX / viewportSize.width, y: 0.5)],
            style: ViewerROIStyle(
                strokeColor: ViewerROIColor(red: 1, green: 0, blue: 0),
                textColor: ViewerROIColor(red: 1, green: 0, blue: 0),
                labelBackgroundColor: .black,
                lineWidth: 2
            )
        )
        let state = Clinical2DViewportOverlayState(
            axis: .axial,
            windowLevel: WindowLevelShift(window: 400, level: 40),
            sliceIndex: 0,
            sliceCount: 1,
            zoom: 1,
            angleDegrees: 0,
            activeTool: .scroll,
            roiKind: .point,
            roiAnnotations: [annotation],
            showsCrosshair: false,
            hudSettings: hiddenHUDSettings
        )

        let pixels = try renderRedPixels(
            Clinical2DViewportOverlay(state: state)
                .frame(width: viewportSize.width, height: viewportSize.height)
                .background(Color.black),
            width: Int(viewportSize.width),
            height: Int(viewportSize.height)
        )

        let centerX = try XCTUnwrap(pixels.bounds?.midX)
        XCTAssertEqual(centerX, expectedCenterX, accuracy: 2)
    }

    @MainActor
    func testCrosshairRendersInFullViewportCoordinateSpace() throws {
        let viewportSize = CGSize(width: 800, height: 600)
        let expectedCenterX = 100.0
        let panX = expectedCenterX / viewportSize.width - 0.5
        let state = Clinical2DViewportOverlayState(
            axis: .axial,
            windowLevel: WindowLevelShift(window: 400, level: 40),
            sliceIndex: 0,
            sliceCount: 1,
            zoom: 1,
            pan: SIMD2<Double>(panX, 0),
            angleDegrees: 0,
            activeTool: .scroll,
            roiKind: .point,
            showsCrosshair: true,
            hudSettings: hiddenHUDSettings
        )

        let pixels = try renderRedPixels(
            Clinical2DViewportOverlay(state: state, style: RedOverlayStyle())
                .frame(width: viewportSize.width, height: viewportSize.height)
                .background(Color.black),
            width: Int(viewportSize.width),
            height: Int(viewportSize.height)
        )

        let centerX = try XCTUnwrap(pixels.dominantColumnX)
        XCTAssertEqual(centerX, expectedCenterX, accuracy: 2)
    }
#endif

    private func makeState(axis: MTKCore.Axis,
                           metadataSample: ClinicalViewportMetadataSample? = nil,
                           metadataOverlaySettings: ClinicalViewportMetadataOverlaySettings = .default) -> Clinical2DViewportOverlayState {
        Clinical2DViewportOverlayState(
            axis: axis,
            windowLevel: WindowLevelShift(window: 400, level: 40),
            sliceIndex: 0,
            sliceCount: 0,
            zoom: 1,
            angleDegrees: 0,
            activeTool: .scroll,
            roiKind: .distance,
            showsCrosshair: false,
            metadataSample: metadataSample,
            metadataOverlaySettings: metadataOverlaySettings
        )
    }

    private func makeMetadataSample() -> ClinicalViewportMetadataSample {
        let voxel = VoxelIndex(index: SIMD3<Int32>(0, 0, 0),
                               continuousIndex: SIMD3<Float>(0, 0, 0))
        let intensity = VolumeIntensitySample(storedScalar: 42,
                                              modalityValue: 42,
                                              hounsfieldUnits: 42)
        let quantitativeValue = QuantitativeScalarValue(
            value: 4.25,
            units: QuantitativeCodedConcept(codeValue: "SUVbw",
                                            codingSchemeDesignator: "UCUM",
                                            codeMeaning: "SUV body weight"),
            quantityDefinitions: [],
            physicalRange: 0...15,
            legendTitle: "SUV"
        )
        let scalarSample = VolumeScalarSample(layerID: "pet",
                                              voxel: voxel,
                                              intensity: intensity,
                                              quantitativeValue: quantitativeValue)
        let doseSample = RTDoseSample(layerID: "dose",
                                      doseValue: 2,
                                      doseUnits: "GY",
                                      storedScalar: 200,
                                      voxel: voxel,
                                      baseWorldPoint: SIMD3<Float>(0, 0, 0),
                                      doseWorldPoint: SIMD3<Float>(0, 0, 0))
        return ClinicalViewportMetadataSample(intensity: intensity,
                                              scalarSamples: [scalarSample],
                                              doseSamples: [doseSample])
    }

    private var hiddenHUDSettings: TwoDHUDSettings {
        TwoDHUDSettings(
            showsSubjectName: false,
            showsSeriesTitle: false,
            showsTechnicalText: false,
            showsOrientationMarkers: false,
            showsCenterOrientationMarker: false,
            showsAxisBadge: false
        )
    }
}

#if os(macOS)
private struct RedOverlayStyle: VolumetricUIStyle {
    let lineWidth: CGFloat = 2

    var crosshairColor: Color { .red }
    var scalebarColor: Color { .red }
    var overlayBackground: Color { .black.opacity(0.55) }
    var overlayForeground: Color { .red }
}

private struct RenderedRedPixels {
    var bounds: CGRect?
    var dominantColumnX: Double?
}

@MainActor
private func renderRedPixels<V: View>(_ view: V,
                                      width: Int,
                                      height: Int) throws -> RenderedRedPixels {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    guard let image = renderer.cgImage else {
        XCTFail("Expected SwiftUI renderer to produce a CGImage")
        return RenderedRedPixels()
    }

    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: &rgba,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ) else {
        XCTFail("Expected to create bitmap context")
        return RenderedRedPixels()
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var minX = width
    var maxX = 0
    var minY = height
    var maxY = 0
    var countByColumn = [Int](repeating: 0, count: width)
    for y in 0..<height {
        for x in 0..<width {
            let index = (y * width + x) * 4
            let red = rgba[index]
            let green = rgba[index + 1]
            let blue = rgba[index + 2]
            let alpha = rgba[index + 3]
            guard red > 180, green < 80, blue < 80, alpha > 120 else { continue }
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
            countByColumn[x] += 1
        }
    }

    let bounds: CGRect?
    if minX <= maxX, minY <= maxY {
        bounds = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    } else {
        bounds = nil
    }
    let dominantColumnX = countByColumn.enumerated().max { lhs, rhs in
        lhs.element < rhs.element
    }.flatMap { $0.element > 0 ? Double($0.offset) : nil }
    return RenderedRedPixels(bounds: bounds, dominantColumnX: dominantColumnX)
}
#endif
