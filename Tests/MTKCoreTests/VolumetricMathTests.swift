//
//  VolumetricMathTests.swift
//  MTKCoreTests
//
//  Comprehensive tests for VolumetricMath utilities including
//  clamping and sanitization functions.
//

import XCTest
import simd
@testable import MTKCore

final class VolumetricMathTests: XCTestCase {

    // MARK: - Generic Clamp Tests

    func testClampWithValueInRange() {
        let result = VolumetricMath.clamp(5, min: 0, max: 10)
        XCTAssertEqual(result, 5)
    }

    func testClampWithValueBelowMin() {
        let result = VolumetricMath.clamp(-5, min: 0, max: 10)
        XCTAssertEqual(result, 0)
    }

    func testClampWithValueAboveMax() {
        let result = VolumetricMath.clamp(15, min: 0, max: 10)
        XCTAssertEqual(result, 10)
    }

    func testClampWithEqualMinMax() {
        let result = VolumetricMath.clamp(5, min: 3, max: 3)
        XCTAssertEqual(result, 3)
    }

    func testClampWorksWithFloats() {
        let result = VolumetricMath.clamp(5.5, min: 0.0, max: 10.0)
        XCTAssertEqual(result, 5.5, accuracy: 0.001)
    }

    // MARK: - ClampFloat Tests

    func testClampFloatWithValueInRange() {
        let result = VolumetricMath.clampFloat(0.5, lower: 0.0, upper: 1.0)
        XCTAssertEqual(result, 0.5, accuracy: 0.001)
    }

    func testClampFloatWithValueBelowLower() {
        let result = VolumetricMath.clampFloat(-2.0, lower: 0.0, upper: 1.0)
        XCTAssertEqual(result, 0.0, accuracy: 0.001)
    }

    func testClampFloatWithValueAboveUpper() {
        let result = VolumetricMath.clampFloat(3.0, lower: 0.0, upper: 1.0)
        XCTAssertEqual(result, 1.0, accuracy: 0.001)
    }

    func testClampFloatWithNegativeRange() {
        let result = VolumetricMath.clampFloat(-5.0, lower: -10.0, upper: -1.0)
        XCTAssertEqual(result, -5.0, accuracy: 0.001)
    }

    // MARK: - ClampSIMD3 Tests

    func testClampSIMD3WithValueInRange() {
        let value = SIMD3<Float>(0.5, 0.5, 0.5)
        let lower = SIMD3<Float>(0.0, 0.0, 0.0)
        let upper = SIMD3<Float>(1.0, 1.0, 1.0)

        let result = VolumetricMath.clampSIMD3(value, min: lower, max: upper)

        XCTAssertEqual(result.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(result.y, 0.5, accuracy: 0.001)
        XCTAssertEqual(result.z, 0.5, accuracy: 0.001)
    }

    func testClampSIMD3WithValueBelowMin() {
        let value = SIMD3<Float>(-1.0, -2.0, -3.0)
        let lower = SIMD3<Float>(0.0, 0.0, 0.0)
        let upper = SIMD3<Float>(1.0, 1.0, 1.0)

        let result = VolumetricMath.clampSIMD3(value, min: lower, max: upper)

        XCTAssertEqual(result.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(result.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(result.z, 0.0, accuracy: 0.001)
    }

    func testClampSIMD3WithValueAboveMax() {
        let value = SIMD3<Float>(2.0, 3.0, 4.0)
        let lower = SIMD3<Float>(0.0, 0.0, 0.0)
        let upper = SIMD3<Float>(1.0, 1.0, 1.0)

        let result = VolumetricMath.clampSIMD3(value, min: lower, max: upper)

        XCTAssertEqual(result.x, 1.0, accuracy: 0.001)
        XCTAssertEqual(result.y, 1.0, accuracy: 0.001)
        XCTAssertEqual(result.z, 1.0, accuracy: 0.001)
    }

    func testClampSIMD3WithMixedValues() {
        let value = SIMD3<Float>(-1.0, 0.5, 2.0)
        let lower = SIMD3<Float>(0.0, 0.0, 0.0)
        let upper = SIMD3<Float>(1.0, 1.0, 1.0)

        let result = VolumetricMath.clampSIMD3(value, min: lower, max: upper)

        XCTAssertEqual(result.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(result.y, 0.5, accuracy: 0.001)
        XCTAssertEqual(result.z, 1.0, accuracy: 0.001)
    }

    func testClampSIMD3WithDifferentBoundsPerAxis() {
        let value = SIMD3<Float>(5.0, 15.0, 25.0)
        let lower = SIMD3<Float>(0.0, 10.0, 20.0)
        let upper = SIMD3<Float>(10.0, 20.0, 30.0)

        let result = VolumetricMath.clampSIMD3(value, min: lower, max: upper)

        XCTAssertEqual(result.x, 5.0, accuracy: 0.001)
        XCTAssertEqual(result.y, 15.0, accuracy: 0.001)
        XCTAssertEqual(result.z, 25.0, accuracy: 0.001)
    }

    // MARK: - ClampViewportSize Tests

    func testClampViewportSizeWithValidSize() {
        let size = CGSize(width: 1920, height: 1080)
        let result = VolumetricMath.clampViewportSize(size)

        XCTAssertEqual(result.width, 1920)
        XCTAssertEqual(result.height, 1080)
    }

    func testClampViewportSizeWithZeroSize() {
        let size = CGSize(width: 0, height: 0)
        let result = VolumetricMath.clampViewportSize(size)

        XCTAssertEqual(result.width, 1)
        XCTAssertEqual(result.height, 1)
    }

    func testClampViewportSizeWithNegativeSize() {
        let size = CGSize(width: -10, height: -20)
        let result = VolumetricMath.clampViewportSize(size)

        XCTAssertEqual(result.width, 1)
        XCTAssertEqual(result.height, 1)
    }

    func testClampViewportSizeWithFractionalValues() {
        let size = CGSize(width: 100.7, height: 200.3)
        let result = VolumetricMath.clampViewportSize(size)

        XCTAssertEqual(result.width, 101)
        XCTAssertEqual(result.height, 200)
    }

    func testClampViewportSizeWithHalfRounding() {
        let size = CGSize(width: 100.5, height: 200.5)
        let result = VolumetricMath.clampViewportSize(size)

        // toNearestOrEven: 100.5 rounds to 100 (even), 200.5 rounds to 200 (even)
        XCTAssertEqual(result.width, 100)
        XCTAssertEqual(result.height, 200)
    }

    // MARK: - ClampBinCount Tests

    func testClampBinCountWithValidValue() {
        let result = VolumetricMath.clampBinCount(256)
        XCTAssertEqual(result, 256)
    }

    func testClampBinCountWithMinBoundary() {
        let result = VolumetricMath.clampBinCount(64)
        XCTAssertEqual(result, 64)
    }

    func testClampBinCountWithMaxBoundary() {
        let result = VolumetricMath.clampBinCount(4096)
        XCTAssertEqual(result, 4096)
    }

    func testClampBinCountBelowMin() {
        let result = VolumetricMath.clampBinCount(32)
        XCTAssertEqual(result, 64)
    }

    func testClampBinCountAboveMax() {
        let result = VolumetricMath.clampBinCount(8192)
        XCTAssertEqual(result, 4096)
    }

    func testClampBinCountWithZero() {
        let result = VolumetricMath.clampBinCount(0)
        XCTAssertEqual(result, 64)
    }

    func testClampBinCountWithNegative() {
        let result = VolumetricMath.clampBinCount(-100)
        XCTAssertEqual(result, 64)
    }

    // MARK: - ClampHU Tests

    func testClampHUWithValueInRange() {
        let result = VolumetricMath.clampHU(0)
        XCTAssertEqual(result, 0)
    }

    func testClampHUWithMinBoundary() {
        let result = VolumetricMath.clampHU(-1024)
        XCTAssertEqual(result, -1024)
    }

    func testClampHUWithMaxBoundary() {
        let result = VolumetricMath.clampHU(3071)
        XCTAssertEqual(result, 3071)
    }

    func testClampHUBelowMin() {
        let result = VolumetricMath.clampHU(-2000)
        XCTAssertEqual(result, -1024)
    }

    func testClampHUAboveMax() {
        let result = VolumetricMath.clampHU(5000)
        XCTAssertEqual(result, 3071)
    }

    func testClampHUWithTypicalCTBoneValue() {
        let result = VolumetricMath.clampHU(1000)
        XCTAssertEqual(result, 1000)
    }

    func testClampHUWithTypicalCTSoftTissueValue() {
        let result = VolumetricMath.clampHU(40)
        XCTAssertEqual(result, 40)
    }

    func testClampHUWithTypicalCTAirValue() {
        let result = VolumetricMath.clampHU(-1000)
        XCTAssertEqual(result, -1000)
    }

    // MARK: - SanitizeThickness Tests

    func testSanitizeThicknessWithPositiveValue() {
        let result = VolumetricMath.sanitizeThickness(10)
        XCTAssertEqual(result, 10)
    }

    func testSanitizeThicknessWithZero() {
        let result = VolumetricMath.sanitizeThickness(0)
        XCTAssertEqual(result, 0)
    }

    func testSanitizeThicknessWithNegativeValue() {
        let result = VolumetricMath.sanitizeThickness(-5)
        XCTAssertEqual(result, 0)
    }

    func testSanitizeThicknessWithLargeValue() {
        let result = VolumetricMath.sanitizeThickness(1000)
        XCTAssertEqual(result, 1000)
    }

    // MARK: - SanitizeSteps Tests

    func testSanitizeStepsWithValidValue() {
        let result = VolumetricMath.sanitizeSteps(100)
        XCTAssertEqual(result, 100)
    }

    func testSanitizeStepsWithMinimum() {
        let result = VolumetricMath.sanitizeSteps(1)
        XCTAssertEqual(result, 1)
    }

    func testSanitizeStepsWithZero() {
        let result = VolumetricMath.sanitizeSteps(0)
        XCTAssertEqual(result, 1)
    }

    func testSanitizeStepsWithNegativeValue() {
        let result = VolumetricMath.sanitizeSteps(-10)
        XCTAssertEqual(result, 1)
    }

    // MARK: - SanitizeViewportSize Tests

    func testSanitizeViewportSizeMatchesClampViewportSize() {
        let size = CGSize(width: 800, height: 600)

        let sanitizeResult = VolumetricMath.sanitizeViewportSize(size)
        let clampResult = VolumetricMath.clampViewportSize(size)

        XCTAssertEqual(sanitizeResult.width, clampResult.width)
        XCTAssertEqual(sanitizeResult.height, clampResult.height)
    }

    func testSanitizeViewportSizeWithInvalidSize() {
        let size = CGSize(width: -10, height: 0)
        let result = VolumetricMath.sanitizeViewportSize(size)

        XCTAssertEqual(result.width, 1)
        XCTAssertEqual(result.height, 1)
    }

    // MARK: - Smoothstep Tests

    func testSmoothstepAtEdge0() {
        let result = VolumetricMath.smoothstep(0.0, 1.0, 0.0)
        XCTAssertEqual(result, 0.0, accuracy: 0.001)
    }

    func testSmoothstepAtEdge1() {
        let result = VolumetricMath.smoothstep(0.0, 1.0, 1.0)
        XCTAssertEqual(result, 1.0, accuracy: 0.001)
    }

    func testSmoothstepAtMidpoint() {
        let result = VolumetricMath.smoothstep(0.0, 1.0, 0.5)
        XCTAssertEqual(result, 0.5, accuracy: 0.001)
    }

    func testSmoothstepBelowEdge0() {
        let result = VolumetricMath.smoothstep(0.0, 1.0, -0.5)
        XCTAssertEqual(result, 0.0, accuracy: 0.001)
    }

    func testSmoothstepAboveEdge1() {
        let result = VolumetricMath.smoothstep(0.0, 1.0, 1.5)
        XCTAssertEqual(result, 1.0, accuracy: 0.001)
    }

    // MARK: - Mix Tests

    func testMixAtZero() {
        let result = VolumetricMath.mix(0.0, 1.0, 0.0)
        XCTAssertEqual(result, 0.0, accuracy: 0.001)
    }

    func testMixAtOne() {
        let result = VolumetricMath.mix(0.0, 1.0, 1.0)
        XCTAssertEqual(result, 1.0, accuracy: 0.001)
    }

    func testMixAtHalf() {
        let result = VolumetricMath.mix(0.0, 1.0, 0.5)
        XCTAssertEqual(result, 0.5, accuracy: 0.001)
    }

    func testMixWithNonZeroStart() {
        let result = VolumetricMath.mix(10.0, 20.0, 0.5)
        XCTAssertEqual(result, 15.0, accuracy: 0.001)
    }

    // MARK: - Axis Constants Tests

    func testXAxisConstant() {
        let axis = VolumetricMath.X_AXIS
        XCTAssertEqual(axis.x, 1.0, accuracy: 0.001)
        XCTAssertEqual(axis.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(axis.z, 0.0, accuracy: 0.001)
    }

    func testYAxisConstant() {
        let axis = VolumetricMath.Y_AXIS
        XCTAssertEqual(axis.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(axis.y, 1.0, accuracy: 0.001)
        XCTAssertEqual(axis.z, 0.0, accuracy: 0.001)
    }

    func testZAxisConstant() {
        let axis = VolumetricMath.Z_AXIS
        XCTAssertEqual(axis.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(axis.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(axis.z, 1.0, accuracy: 0.001)
    }
}
