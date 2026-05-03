import simd
import XCTest

@testable import MTKCore

final class DicomWindowingExtractionTests: XCTestCase {
    func test_recommendedWindow_usesWindowCenterWidthSingleValues_whenPresent() throws {
        let loader = DicomVolumeLoader(seriesLoader: SyntheticSeriesLoader(
            modality: "CT",
            windowCenter: 40,
            windowWidth: 400,
            slices: [
                [0, 0, 0, 0],
                [0, 0, 0, 0]
            ]
        ))

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectation = expectation(description: "DICOM load")
        var outcome: Result<DicomImportResult, Error>?

        loader.loadVolume(from: directory, progress: { _ in }, completion: { result in
            outcome = result
            expectation.fulfill()
        })

        wait(for: [expectation], timeout: 5)

        let result = try XCTUnwrap(outcome?.get())
        XCTAssertEqual(result.dataset.recommendedWindow, -160...239, "WC=40 WW=400 should yield [-160, 239]")
        XCTAssertFalse(result.warnings.contains { $0.code == .usedFallbackWindow })
    }

    func test_recommendedWindow_fallsBackToCTSoftTissue_whenWindowMetadataMissing() throws {
        let loader = DicomVolumeLoader(seriesLoader: SyntheticSeriesLoader(
            modality: "CT",
            windowCenter: nil,
            windowWidth: nil,
            slices: [
                [0, 0, 0, 0]
            ]
        ))

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectation = expectation(description: "DICOM load")
        var outcome: Result<DicomImportResult, Error>?

        loader.loadVolume(from: directory, progress: { _ in }, completion: { result in
            outcome = result
            expectation.fulfill()
        })

        wait(for: [expectation], timeout: 5)

        let result = try XCTUnwrap(outcome?.get())
        XCTAssertEqual(result.dataset.recommendedWindow, WindowLevelPresetLibrary.softTissue.windowRange)
        XCTAssertEqual(result.warnings.first?.code, .usedFallbackWindow)
    }

    func test_recommendedWindow_fallsBackToFullRange_forMR_whenWindowMetadataMissing() throws {
        let loader = DicomVolumeLoader(seriesLoader: SyntheticSeriesLoader(
            modality: "MR",
            windowCenter: nil,
            windowWidth: nil,
            slices: [
                [0, 100, 200, 300]
            ]
        ))

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectation = expectation(description: "DICOM load")
        var outcome: Result<DicomImportResult, Error>?

        loader.loadVolume(from: directory, progress: { _ in }, completion: { result in
            outcome = result
            expectation.fulfill()
        })

        wait(for: [expectation], timeout: 5)

        let result = try XCTUnwrap(outcome?.get())
        XCTAssertEqual(result.dataset.recommendedWindow, result.dataset.intensityRange)
        XCTAssertEqual(result.warnings.first?.code, .usedFallbackWindow)
    }

    func test_recommendedWindow_warnsWhenFinalVolumeDoesNotExposeMetadata() throws {
        let loader = DicomVolumeLoader(seriesLoader: NonProtocolFinalSeriesLoader())
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectation = expectation(description: "DICOM load")
        var outcome: Result<DicomImportResult, Error>?

        loader.loadVolume(from: directory, progress: { _ in }, completion: { result in
            outcome = result
            expectation.fulfill()
        })

        wait(for: [expectation], timeout: 5)

        let result = try XCTUnwrap(outcome?.get())
        XCTAssertEqual(result.dataset.recommendedWindow, WindowLevelPresetLibrary.softTissue.windowRange)
        XCTAssertEqual(result.warnings.first?.code, .usedFallbackWindow)
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DicomWindowingExtractionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class SyntheticSeriesLoader: DicomSeriesLoading {
    private let volume: any DICOMSeriesVolumeProtocol

    init(modality: String,
         windowCenter: Double?,
         windowWidth: Double?,
         slices: [[Int16]]) {
        self.volume = SyntheticVolume(
            modality: modality,
            windowCenter: windowCenter,
            windowWidth: windowWidth,
            slices: slices.map { $0.withUnsafeBytes { Data($0) } }
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

private final class NonProtocolFinalSeriesLoader: DicomSeriesLoading {
    private let volume = SyntheticVolume(
        modality: "CT",
        windowCenter: nil,
        windowWidth: nil,
        slices: [[Int16(0), 0, 0, 0].withUnsafeBytes { Data($0) }]
    )

    func loadSeries(at url: URL,
                    progress: ((Double, UInt, Data?, Any) -> Void)?) throws -> Any {
        progress?(1.0, 1, volume.slices[0], volume)
        return "non-protocol final volume"
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
    let rescaleSlope: Double = 1.0
    let rescaleIntercept: Double = 0.0
    let isSignedPixel: Bool = true
    let seriesDescription = "Synthetic Windowing Series"
    let modality: String

    let windowCenter: Double?
    let windowWidth: Double?

    let slices: [Data]

    init(modality: String,
         windowCenter: Double?,
         windowWidth: Double?,
         slices: [Data]) {
        self.modality = modality
        self.windowCenter = windowCenter
        self.windowWidth = windowWidth
        self.slices = slices
        self.depth = slices.count
        let computedWidth = 2
        let computedHeight = max(1, slices.first.map { $0.count / 2 / computedWidth } ?? 1)
        self.width = computedWidth
        self.height = computedHeight
    }
}
