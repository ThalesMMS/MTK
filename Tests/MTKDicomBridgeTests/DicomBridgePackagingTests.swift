import DicomCore
import Foundation
import MTKCore
@testable import MTKDicomBridge
import XCTest
import simd

final class DicomBridgePackagingTests: XCTestCase {
    func testBridgeProvidesDatasetImporter() {
        let importer = DicomVolumeDatasetImporter()
        let typedImporter: VolumeDatasetImporting = importer

        XCTAssertTrue(typedImporter === importer)
    }

    func testDecodedSeriesMapsToVolumeDataset() {
        let modalityVoxels = [Int16]([-1024, 0, 128, 512]).withUnsafeBytes { Data($0) }
        let rawVoxels = [UInt16]([0, 1024, 1152, 1536]).withUnsafeBytes { Data($0) }
        let decoded = DicomDecodedSeries(
            rawVoxels: rawVoxels,
            modalityVoxels: modalityVoxels,
            sourcePixelRepresentation: .unsignedInt16,
            bitsAllocated: 16,
            dimensions: DicomSeriesDimensions(width: 2, height: 2, depth: 1),
            spacing: SIMD3<Double>(0.5, 0.5, 1.25),
            orientation: matrix_identity_double3x3,
            origin: SIMD3<Double>(10, 20, 30),
            modalityIntensityRange: -1024...512,
            recommendedWindow: -160...239,
            patientName: "Sample^Subject",
            modality: "CT",
            seriesDescription: "Bridge fixture",
            studyInstanceUID: "1.2.3",
            seriesInstanceUID: "1.2.3.4",
            frameOfReferenceUID: "1.2.3.4.5",
            rescaleSlope: 1,
            rescaleIntercept: -1024,
            windowCenter: 40,
            windowWidth: 400,
            sourceURL: URL(fileURLWithPath: "/tmp/fixture"),
            warnings: []
        )

        let dataset = DicomVolumeDatasetImporter.makeDataset(from: decoded)

        XCTAssertEqual(dataset.data, modalityVoxels)
        XCTAssertEqual(dataset.dimensions, VolumeDimensions(width: 2, height: 2, depth: 1))
        XCTAssertEqual(dataset.spacing, VolumeSpacing(x: 0.5, y: 0.5, z: 1.25))
        XCTAssertEqual(dataset.imageData.origin, SIMD3<Float>(10, 20, 30))
        XCTAssertEqual(dataset.pixelFormat, .int16Signed)
        XCTAssertEqual(dataset.intensityRange, -1024...512)
        XCTAssertEqual(dataset.recommendedWindow, -160...239)
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.modality, "CT")
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.patientName, "Sample^Subject")
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.seriesDescription, "Bridge fixture")
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.studyInstanceUID, "1.2.3")
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.seriesInstanceUID, "1.2.3.4")
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.frameOfReferenceUID, "1.2.3.4.5")
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.sourcePixelFormat, .int16Unsigned)
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.windowCenter, 40)
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.windowWidth, 400)
    }

    func testImporterPassesDicomCoreErrorsWithoutSemanticRemapping() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let importer = DicomVolumeDatasetImporter()
        let expectation = expectation(description: "DICOM import fails")
        var captured: Error?

        importer.loadDataset(from: directory, progress: { _ in }) { result in
            if case .failure(let error) = result {
                captured = error
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)

        guard case DicomSeriesLoaderError.noDicomFiles = try XCTUnwrap(captured) else {
            XCTFail("Expected DicomSeriesLoaderError.noDicomFiles, got \(String(describing: captured))")
            return
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DicomBridgePackagingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
