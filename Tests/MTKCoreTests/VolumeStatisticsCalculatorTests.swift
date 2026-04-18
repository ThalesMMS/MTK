//
//  VolumeStatisticsCalculatorTests.swift
//  MTK
//
//  Unit tests for VolumeStatisticsCalculator error and forced-failure equatability.
//
//  Thales Matheus Mendonca Santos - February 2026

import XCTest
@_spi(Testing) import MTKCore

// MARK: - StatisticsError Equatable and case coverage

final class StatisticsErrorEquatableTests: XCTestCase {
    private typealias StatisticsError = VolumeStatisticsCalculator.StatisticsError

    func testEachCaseEqualsItself() {
        let allCases: [StatisticsError] = [
            .pipelineUnavailable,
            .bufferAllocationFailed,
            .commandQueueUnavailable,
            .commandBufferCreationFailed,
            .encoderCreationFailed,
            .emptyHistogram,
            .invalidPercentiles,
        ]
        for error in allCases {
            XCTAssertEqual(error, error, "\(error) should equal itself")
        }
    }

    func testDistinctCasesAreNotEqual() {
        XCTAssertNotEqual(StatisticsError.pipelineUnavailable, .bufferAllocationFailed)
        XCTAssertNotEqual(StatisticsError.commandQueueUnavailable, .commandBufferCreationFailed)
        XCTAssertNotEqual(StatisticsError.commandBufferCreationFailed, .encoderCreationFailed)
        XCTAssertNotEqual(StatisticsError.emptyHistogram, .invalidPercentiles)
        XCTAssertNotEqual(StatisticsError.pipelineUnavailable, .emptyHistogram)
    }

    func testCanBeCastFromSwiftError() {
        let error: Error = StatisticsError.commandBufferCreationFailed
        XCTAssertEqual(error as? StatisticsError, .commandBufferCreationFailed,
                       "StatisticsError should round-trip through the Error protocol")
    }

    func testCommandQueueUnavailableExists() {
        let error = StatisticsError.commandQueueUnavailable
        XCTAssertNotNil(error as Error)
    }

    func testCommandBufferCreationFailedExists() {
        let error = StatisticsError.commandBufferCreationFailed
        // Casting confirms the new case compiles and is the right type
        XCTAssertNotNil(error as Error)
    }

    func testEncoderCreationFailedExists() {
        let error = StatisticsError.encoderCreationFailed
        XCTAssertNotNil(error as Error)
    }
}

// MARK: - ForcedFailure Equatable

final class ForcedFailureEquatableTests: XCTestCase {
    // ForcedFailure is accessible because the file already imports @_spi(Testing) MTKCore
    typealias ForcedFailure = VolumeStatisticsCalculator.ForcedFailure

    func testEachCaseEqualsItself() {
        let allCases: [ForcedFailure] = [
            .bufferAllocationFailed,
            .pipelineUnavailable,
            .commandBufferCreationFailed,
            .encoderCreationFailed,
        ]
        for failure in allCases {
            XCTAssertEqual(failure, failure, "\(failure) should equal itself")
        }
    }

    func testDistinctCasesAreNotEqual() {
        XCTAssertNotEqual(ForcedFailure.bufferAllocationFailed, .pipelineUnavailable)
        XCTAssertNotEqual(ForcedFailure.commandBufferCreationFailed, .encoderCreationFailed)
        XCTAssertNotEqual(ForcedFailure.bufferAllocationFailed, .encoderCreationFailed)
    }
}
