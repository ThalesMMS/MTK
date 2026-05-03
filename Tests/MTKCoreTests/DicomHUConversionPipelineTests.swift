import Foundation
import simd
import XCTest

@testable import MTKCore

final class DicomHUConversionPipelineTests: XCTestCase {
    func test_loadVolume_appliesSlopeInterceptAndClamp_forSignedSeries() throws {
        let loader = DicomVolumeLoader(seriesLoader: SyntheticSeriesLoader(
            slope: 2.0,
            intercept: -10.0,
            isSigned: true,
            slices: [
                [1, 2, 3, 4],
                [5, 6, 7, 8]
            ]
        ))

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectation = expectation(description: "DICOM load")
        var outcome: Result<([Int16], ClosedRange<Int32>), Error>?

        loader.loadVolume(from: directory, progress: { _ in }, completion: { result in
            outcome = result.map { importResult in
                let values = readInt16Values(from: importResult.dataset.data)
                return (values, importResult.dataset.intensityRange)
            }
            expectation.fulfill()
        })

        wait(for: [expectation], timeout: 5)

        let (loadedValues, loadedRange) = try XCTUnwrap(outcome?.get())
        XCTAssertEqual(loadedValues, [-8, -6, -4, -2, 0, 2, 4, 6])
        XCTAssertEqual(loadedRange, -8...6)
    }

    func test_loadVolume_appliesSlopeInterceptAndClamp_forUnsignedSeries() throws {
        // Includes values that will clamp below -1024 and above 3071.
        let loader = DicomVolumeLoader(seriesLoader: SyntheticSeriesLoader(
            slope: 1.0,
            intercept: -2048.0,
            isSigned: false,
            unsignedSlices: [
                [0, 1, 4095, 6000],
                [2048, 3071, 4096, 65535]
            ]
        ))

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectation = expectation(description: "DICOM load")
        var outcome: Result<([Int16], ClosedRange<Int32>), Error>?

        loader.loadVolume(from: directory, progress: { _ in }, completion: { result in
            outcome = result.map { importResult in
                let values = readInt16Values(from: importResult.dataset.data)
                return (values, importResult.dataset.intensityRange)
            }
            expectation.fulfill()
        })

        wait(for: [expectation], timeout: 5)

        let (loadedValues, loadedRange) = try XCTUnwrap(outcome?.get())
        XCTAssertEqual(loadedValues, [-1024, -1024, 2047, 3071, 0, 1023, 2048, 3071])
        XCTAssertEqual(loadedRange, -1024...3071)
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DicomHUConversionPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class SyntheticSeriesLoader: DicomSeriesLoading {
    private let volume: any DICOMSeriesVolumeProtocol

    init(slope: Double,
         intercept: Double,
         isSigned: Bool,
         slices: [[Int16]]) {
        self.volume = SyntheticVolume(
            slices: slices.map { $0.withUnsafeBytes { Data($0) } },
            isSigned: isSigned,
            slope: slope,
            intercept: intercept
        )
    }

    init(slope: Double,
         intercept: Double,
         isSigned: Bool,
         unsignedSlices: [[UInt16]]) {
        self.volume = SyntheticVolume(
            slices: unsignedSlices.map { $0.withUnsafeBytes { Data($0) } },
            isSigned: isSigned,
            slope: slope,
            intercept: intercept
        )
    }

    func loadSeries(at url: URL,
                    progress: ((Double, UInt, Data?, Any) -> Void)?) throws -> Any {
        guard let volume = volume as? SyntheticVolume else {
            return volume
        }

        for index in 0..<volume.depth {
            let fraction = Double(index + 1) / Double(volume.depth)
            progress?(fraction, UInt(index + 1), volume.slices[index], volume)
        }
        return volume
    }
}

private struct SyntheticVolume: DICOMSeriesVolumeProtocol {
    let bitsAllocated = 16
    let width: Int
    let height: Int
    let depth: Int
    let spacingX = 1.0
    let spacingY = 1.0
    let spacingZ = 1.0
    let orientation = matrix_identity_float3x3
    let origin = SIMD3<Float>(repeating: 0)
    let rescaleSlope: Double
    let rescaleIntercept: Double
    let isSignedPixel: Bool
    let seriesDescription = "Synthetic HU Series"
    let modality = "CT"

    let slices: [Data]

    init(slices: [Data], isSigned: Bool, slope: Double, intercept: Double) {
        self.slices = slices
        self.isSignedPixel = isSigned
        self.rescaleSlope = slope
        self.rescaleIntercept = intercept

        // Each slice is 2x2.
        self.width = 2
        self.height = 2
        self.depth = slices.count
    }
}

private func readInt16Values(from data: Data) -> [Int16] {
    data.withUnsafeBytes { rawBuffer in
        let values = rawBuffer.bindMemory(to: Int16.self)
        return Array(values)
    }
}
