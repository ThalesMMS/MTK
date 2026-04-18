//
//  XCTest+AsyncAssertions.swift
//  MTK
//
//  Shared async XCTest helpers.
//

import Metal
import XCTest

@_spi(Testing) @testable import MTKCore

/// Creates a `MetalVolumeRenderingAdapter` for testing, skipping if Metal or the adapter is unavailable.
func makeTestAdapter() throws -> MetalVolumeRenderingAdapter {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw XCTSkip("Metal device unavailable on this test runner")
    }
    do {
        return try MetalVolumeRenderingAdapter(device: device)
    } catch let error as MetalVolumeRenderingAdapter.InitializationError {
        throw XCTSkip("Adapter unavailable: \(error.localizedDescription)")
    }
}

/// Asserts that the given async throwing expression throws the specified error value.
///
/// Evaluates the provided async throwing expression and records a test failure if it does not throw, if it throws a different error type, or if the thrown error of type `E` is not equal to `expectedError`.
/// - Parameters:
///   - expression: An autoclosure that executes the async throwing expression to test.
///   - expectedError: The specific error value expected to be thrown (must conform to `Error` and `Equatable`).
///   - file: The file name to use in test failure reports. Defaults to the call site.
///   - line: The line number to use in test failure reports. Defaults to the call site.
func XCTAssertThrowsAsync<T, E: Error & Equatable>(
    _ expression: @autoclosure () async throws -> T,
    expecting expectedError: E,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected to throw \(expectedError)", file: file, line: line)
    } catch let error as E {
        XCTAssertEqual(error, expectedError, file: file, line: line)
    } catch {
        XCTFail("Expected \(E.self) but got \(type(of: error)): \(error)", file: file, line: line)
    }
}