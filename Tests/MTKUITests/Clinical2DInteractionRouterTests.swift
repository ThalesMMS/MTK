import CoreGraphics
import MTKCore
@testable import MTKUI
import XCTest

@MainActor
final class Clinical2DInteractionRouterTests: XCTestCase {
    private let router = Clinical2DInteractionRouter(scrollDragPixelsPerStep: 10)

    func testRoutesDragByActiveTool() {
        let size = CGSize(width: 200, height: 200)
        let start = CGPoint(x: 100, y: 100)

        XCTAssertEqual(
            router.routeDrag(tool: .scroll,
                             axis: .axial,
                             roiKind: .distance,
                             sliceIndex: 0,
                             viewportSize: size,
                             transform: .identity,
                             delta: CGSize(width: 2, height: 24),
                             startLocation: start,
                             previousLocation: CGPoint(x: 100, y: 100),
                             currentLocation: CGPoint(x: 102, y: 124)),
            .scrollSlices(2)
        )

        XCTAssertEqual(
            router.routeDrag(tool: .windowLevel,
                             axis: .axial,
                             roiKind: .distance,
                             sliceIndex: 0,
                             viewportSize: size,
                             transform: .identity,
                             delta: CGSize(width: 5, height: -4),
                             startLocation: start,
                             previousLocation: CGPoint(x: 100, y: 100),
                             currentLocation: CGPoint(x: 105, y: 96)),
            .adjustWindowLevel(CGSize(width: 5, height: -4))
        )

        let rotation = router.routeDrag(tool: .rotation,
                                        axis: .axial,
                                        roiKind: .distance,
                                        sliceIndex: 0,
                                        viewportSize: size,
                                        transform: .identity,
                                        delta: CGSize(width: -100, height: 100),
                                        startLocation: CGPoint(x: 200, y: 100),
                                        previousLocation: CGPoint(x: 200, y: 100),
                                        currentLocation: CGPoint(x: 100, y: 200))
        if case .rotate(let radians) = rotation {
            XCTAssertEqual(radians, .pi / 2, accuracy: 0.0001)
        } else {
            XCTFail("Expected rotation route, got \(rotation)")
        }

        XCTAssertEqual(
            router.routeDrag(tool: .sync,
                             axis: .axial,
                             roiKind: .distance,
                             sliceIndex: 0,
                             viewportSize: size,
                             transform: .identity,
                             delta: CGSize(width: 50, height: 50),
                             startLocation: start,
                             previousLocation: CGPoint(x: 100, y: 100),
                             currentLocation: CGPoint(x: 150, y: 150)),
            .none
        )
    }

    func testWheelOnlyScrollsWhenScrollToolIsActive() {
        XCTAssertEqual(router.routeWheel(tool: .scroll,
                                         deltaY: 6,
                                         hasPreciseScrollingDeltas: true),
                       .scrollSlices(1))
        XCTAssertEqual(router.routeWheel(tool: .windowLevel,
                                         deltaY: 6,
                                         hasPreciseScrollingDeltas: true),
                       .none)
        XCTAssertEqual(router.routeWheel(tool: .reslice,
                                         deltaY: -6,
                                         hasPreciseScrollingDeltas: true),
                       .none)
    }

    func testPinchRoutesToZoomExceptWhenROICapturesMultiTouch() {
        XCTAssertEqual(router.routeMagnification(factor: 1.25,
                                                 anchor: CGPoint(x: 0.4, y: 0.6),
                                                 tool: .scroll),
                       .zoom(factor: 1.25, anchor: SIMD2<Double>(0.4, 0.6)))
        XCTAssertEqual(router.routeMagnification(factor: 0.8,
                                                 anchor: CGPoint(x: 0.5, y: 0.5),
                                                 tool: .roi,
                                                 roiCapturingMultiTouch: true),
                       .none)
    }

    func testROICompletionConvertsViewportCoordinatesThrough2DTransform() {
        let size = CGSize(width: 100, height: 100)
        let transform = Viewer2DTransform(zoom: 2,
                                          pan: SIMD2<Double>(0.1, -0.1),
                                          rotationRadians: 0,
                                          isFlippedHorizontally: false,
                                          isFlippedVertically: false)

        let route = router.routeCompletedDrag(tool: .roi,
                                              axis: .coronal,
                                              roiKind: .arrow,
                                              sliceIndex: 4,
                                              viewportSize: size,
                                              transform: transform,
                                              startLocation: CGPoint(x: 50, y: 50),
                                              endLocation: CGPoint(x: 90, y: 10))

        guard case .roi(let interaction) = route else {
            XCTFail("Expected ROI route, got \(route)")
            return
        }
        XCTAssertEqual(interaction.kind, .arrow)
        XCTAssertEqual(interaction.axis, .coronal)
        XCTAssertEqual(interaction.sliceIndex, 4)
        XCTAssertEqual(interaction.startImagePoint.x, 0.45, accuracy: 0.0001)
        XCTAssertEqual(interaction.startImagePoint.y, 0.55, accuracy: 0.0001)
        XCTAssertEqual(interaction.endImagePoint.x, 0.65, accuracy: 0.0001)
        XCTAssertEqual(interaction.endImagePoint.y, 0.35, accuracy: 0.0001)
    }

    func testNormalizedImagePointAppliesRotationAndFlips() {
        let size = CGSize(width: 100, height: 100)
        let rotated = Viewer2DTransform(rotationRadians: .pi / 2)
        let rotatedPoint = router.normalizedImagePoint(viewportLocation: CGPoint(x: 50, y: 25),
                                                       viewportSize: size,
                                                       transform: rotated)

        XCTAssertEqual(rotatedPoint?.x ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(rotatedPoint?.y ?? -1, 0.5, accuracy: 0.0001)

        let flipped = Viewer2DTransform(rotationRadians: .pi / 2,
                                        isFlippedHorizontally: true,
                                        isFlippedVertically: false)
        let flippedPoint = router.normalizedImagePoint(viewportLocation: CGPoint(x: 50, y: 25),
                                                       viewportSize: size,
                                                       transform: flipped)

        XCTAssertEqual(flippedPoint?.x ?? -1, 0.75, accuracy: 0.0001)
        XCTAssertEqual(flippedPoint?.y ?? -1, 0.5, accuracy: 0.0001)
    }

    func testTwoFingerPanCanBeRoutedWithoutChangingToolSpecificDragRules() {
        let route = router.routeDrag(tool: .windowLevel,
                                     axis: .axial,
                                     roiKind: .distance,
                                     sliceIndex: 0,
                                     viewportSize: CGSize(width: 200, height: 100),
                                     transform: .identity,
                                     delta: CGSize(width: 20, height: -10),
                                     startLocation: CGPoint(x: 100, y: 50),
                                     previousLocation: CGPoint(x: 100, y: 50),
                                     currentLocation: CGPoint(x: 120, y: 40),
                                     isTwoFingerPan: true)

        XCTAssertEqual(route, .pan(deltaNormalized: SIMD2<Double>(0.1, -0.1)))
    }
}
