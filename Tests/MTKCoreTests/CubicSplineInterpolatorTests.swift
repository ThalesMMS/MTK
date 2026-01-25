import XCTest
@testable import MTKCore

final class CubicSplineInterpolatorTests: XCTestCase {
    func testLinearInterpolationClampsToExtents() {
        let interpolator = CubicSplineInterpolator(xPoints: [0, 1], yPoints: [0, 10])
        interpolator.mode = .linear

        XCTAssertEqual(interpolator.interpolate(-1), 0)
        XCTAssertEqual(interpolator.interpolate(2), 10)
        XCTAssertEqual(interpolator.interpolate(0.5), 5, accuracy: 0.0001)
    }

    func testUpdatingSplineProducesSmoothCurve() {
        let interpolator = CubicSplineInterpolator(xPoints: [0, 1, 2], yPoints: [0, 1, 0])

        let midValue = interpolator.interpolate(0.5)
        XCTAssertGreaterThan(midValue, 0)
        XCTAssertLessThan(midValue, 1)

        interpolator.updateSpline(xPoints: [0, 2, 4], yPoints: [0, 4, 0])

        XCTAssertEqual(interpolator.interpolate(2), 4, accuracy: 0.0001)
        XCTAssertLessThan(interpolator.interpolate(3), 4)
    }
}
