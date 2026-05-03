import simd
import XCTest

import DicomCore
@testable import MTKCore

final class DicomImportFailureSurfacingTests: XCTestCase {
    func test_loadVolume_failsWithUnsupportedTransferSyntaxError() throws {
        let loader = DicomVolumeLoader(seriesLoader: ErrorSeriesLoader(error: DicomSeriesLoaderError.unsupportedTransferSyntax("1.2.840.10008.1.2.4.90")))

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectation = expectation(description: "DICOM load")
        var outcome: Result<DicomImportResult, Error>?

        loader.loadVolume(from: directory, progress: { _ in }, completion: { result in
            outcome = result
            expectation.fulfill()
        })

        wait(for: [expectation], timeout: 5)

        let error = try XCTUnwrap(outcome?.failure)
        guard case let DicomVolumeLoaderError.unsupportedTransferSyntax(uid) = error else {
            return XCTFail("Expected unsupportedTransferSyntax error, got: \(error)")
        }
        XCTAssertEqual(uid, "1.2.840.10008.1.2.4.90")
    }

    func test_loadVolume_failsWithUnsupportedPixelDataError() throws {
        let loader = DicomVolumeLoader(seriesLoader: ErrorSeriesLoader(error: DicomSeriesLoaderError.unsupportedSamplesPerPixel(3)))

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectation = expectation(description: "DICOM load")
        var outcome: Result<DicomImportResult, Error>?

        loader.loadVolume(from: directory, progress: { _ in }, completion: { result in
            outcome = result
            expectation.fulfill()
        })

        wait(for: [expectation], timeout: 5)

        let error = try XCTUnwrap(outcome?.failure)
        guard case let DicomVolumeLoaderError.unsupportedPixelData(reason) = error else {
            return XCTFail("Expected unsupportedPixelData error, got: \(error)")
        }
        XCTAssertTrue(reason.contains("samples"))
    }

    func test_loadVolume_failsWithDuplicateSlicePositionError() throws {
        let loader = DicomVolumeLoader(seriesLoader: ErrorSeriesLoader(error: DicomSeriesLoaderError.duplicateSlicePosition))

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectation = expectation(description: "DICOM load")
        var outcome: Result<DicomImportResult, Error>?

        loader.loadVolume(from: directory, progress: { _ in }, completion: { result in
            outcome = result
            expectation.fulfill()
        })

        wait(for: [expectation], timeout: 5)

        let error = try XCTUnwrap(outcome?.failure)
        guard case DicomVolumeLoaderError.duplicateSlicePosition = error else {
            return XCTFail("Expected duplicateSlicePosition error, got: \(error)")
        }
    }

    func test_loadVolume_failsWithVariableSliceSpacingError() throws {
        let loader = DicomVolumeLoader(seriesLoader: ErrorSeriesLoader(error: DicomSeriesLoaderError.variableSliceSpacing(median: 1.0, maxDeviation: 0.35)))

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectation = expectation(description: "DICOM load")
        var outcome: Result<DicomImportResult, Error>?

        loader.loadVolume(from: directory, progress: { _ in }, completion: { result in
            outcome = result
            expectation.fulfill()
        })

        wait(for: [expectation], timeout: 5)

        let error = try XCTUnwrap(outcome?.failure)
        guard case let DicomVolumeLoaderError.variableSliceSpacing(median, maxDeviation) = error else {
            return XCTFail("Expected variableSliceSpacing error, got: \(error)")
        }
        XCTAssertEqual(median, 1.0, accuracy: 1e-6)
        XCTAssertEqual(maxDeviation, 0.35, accuracy: 1e-6)
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DicomImportFailureSurfacingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class ErrorSeriesLoader: DicomSeriesLoading {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func loadSeries(at url: URL,
                    progress: ((Double, UInt, Data?, Any) -> Void)?) throws -> Any {
        throw error
    }
}

private extension Result {
    var failure: Failure? {
        if case let .failure(error) = self {
            return error
        }
        return nil
    }
}
