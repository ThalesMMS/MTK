//
//  DicomVolumeTypesTests.swift
//  MTKCoreTests
//
//  Tests for DicomVolumeTypes.swift: error descriptions, structs, enums.
//

import Foundation
import simd
import XCTest
@testable import MTKCore

final class DicomVolumeTypesTests: XCTestCase {

    // MARK: - DicomVolumeLoaderError.errorDescription

    func testSecurityScopeUnavailableHasCorrectDescription() {
        let error = DicomVolumeLoaderError.securityScopeUnavailable
        XCTAssertEqual(error.errorDescription, "Could not access the selected files.")
    }

    func testUnsupportedBitDepthHasCorrectDescription() {
        let error = DicomVolumeLoaderError.unsupportedBitDepth
        XCTAssertEqual(error.errorDescription, "Only 16-bit scalar DICOM series are supported at this time.")
    }

    func testMissingResultHasCorrectDescription() {
        let error = DicomVolumeLoaderError.missingResult
        XCTAssertEqual(error.errorDescription, "The DICOM series conversion returned no data.")
    }

    func testPathTraversalHasCorrectDescription() {
        let error = DicomVolumeLoaderError.pathTraversal
        XCTAssertEqual(error.errorDescription, "The file contains invalid paths that attempt to access external directories.")
    }

    func testBridgeErrorWithNonEmptyDescriptionReturnsFallback() {
        let nsError = NSError(domain: "TestDomain", code: 42,
                              userInfo: [NSLocalizedDescriptionKey: "Underlying parse failure"])
        let error = DicomVolumeLoaderError.bridgeError(nsError)
        XCTAssertEqual(error.errorDescription, "Failed to process the DICOM series.")
    }

    func testBridgeErrorWhitespaceFallbacks() {
        for description in ["  \n\t  ", "   "] {
            let nsError = NSError(domain: "TestDomain", code: 0,
                                  userInfo: [NSLocalizedDescriptionKey: description])
            let error = DicomVolumeLoaderError.bridgeError(nsError)
            XCTAssertEqual(error.errorDescription, "Failed to process the DICOM series.")
        }
    }

    // MARK: - DicomVolumeLoaderError conforms to Error

    func testDicomVolumeLoaderErrorConformsToError() {
        let error: Error = DicomVolumeLoaderError.missingResult
        XCTAssertEqual(error.localizedDescription, "The DICOM series conversion returned no data.")
    }

    func testDicomVolumeLoaderErrorConformsToLocalizedError() {
        let error: LocalizedError = DicomVolumeLoaderError.unsupportedBitDepth
        XCTAssertEqual(error.errorDescription, "Only 16-bit scalar DICOM series are supported at this time.")
    }

    // MARK: - DicomImportResult

    func testDicomImportResultStoresDatasetAndMetadata() {
        let dimensions = VolumeDimensions(width: 8, height: 8, depth: 8)
        let data = Data(count: dimensions.voxelCount * VolumePixelFormat.int16Signed.bytesPerVoxel)
        let dataset = VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: (-1024)...3071
        )
        let url = URL(fileURLWithPath: "/tmp/test.dcm")
        let description = "CT Head"

        let result = DicomImportResult(dataset: dataset, sourceURL: url, seriesDescription: description)

        XCTAssertEqual(result.dataset, dataset)
        XCTAssertEqual(result.sourceURL, url)
        XCTAssertEqual(result.seriesDescription, description)
    }

    func testDicomImportResultAllowsEmptySeriesDescription() {
        let dimensions = VolumeDimensions(width: 2, height: 2, depth: 2)
        let data = Data(count: dimensions.voxelCount * VolumePixelFormat.int16Signed.bytesPerVoxel)
        let dataset = VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: (-1024)...3071
        )
        let url = URL(fileURLWithPath: "/tmp/study")

        let result = DicomImportResult(dataset: dataset, sourceURL: url, seriesDescription: "")

        XCTAssertEqual(result.seriesDescription, "")
    }

    // MARK: - DicomStreamingImportResult

    func testDicomStreamingImportResultStoresMetadataAndURL() {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        let descriptor = VolumeUploadDescriptor(
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 0.5, y: 0.5, z: 1.0),
            sourcePixelFormat: .int16Signed,
            intensityRange: (-1000)...2000
        )
        let url = URL(fileURLWithPath: "/tmp/series")
        let description = "MR T2 FLAIR"

        let result = DicomStreamingImportResult(metadata: descriptor,
                                                sourceURL: url,
                                                seriesDescription: description)

        XCTAssertEqual(result.metadata, descriptor)
        XCTAssertEqual(result.sourceURL, url)
        XCTAssertEqual(result.seriesDescription, description)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testDicomStreamingImportResultAllowsEmptySeriesDescription() {
        let dimensions = VolumeDimensions(width: 2, height: 2, depth: 2)
        let descriptor = VolumeUploadDescriptor(
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            sourcePixelFormat: .int16Signed,
            intensityRange: 0...100
        )
        let url = URL(fileURLWithPath: "/tmp/test")

        let result = DicomStreamingImportResult(metadata: descriptor, sourceURL: url, seriesDescription: "")

        XCTAssertEqual(result.seriesDescription, "")
    }

    func testDicomStreamingImportResultStoresWarnings() {
        let dimensions = VolumeDimensions(width: 2, height: 2, depth: 2)
        let descriptor = VolumeUploadDescriptor(
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            sourcePixelFormat: .int16Signed,
            intensityRange: 0...100
        )
        let warning = DicomImportWarning(code: .usedFallbackWindow,
                                         message: "Fallback window",
                                         context: "MR")

        let result = DicomStreamingImportResult(metadata: descriptor,
                                                sourceURL: URL(fileURLWithPath: "/tmp/test"),
                                                seriesDescription: "",
                                                warnings: [warning])

        XCTAssertEqual(result.warnings, [warning])
    }

    // MARK: - DicomVolumeProgress

    func testDicomVolumeProgressStartedCaseCarriesTotalSlices() {
        let progress = DicomVolumeProgress.started(totalSlices: 256)
        if case .started(let count) = progress {
            XCTAssertEqual(count, 256)
        } else {
            XCTFail("Expected .started case")
        }
    }

    func testDicomVolumeProgressReadingCaseCarriesFraction() {
        let fraction = 0.42
        let progress = DicomVolumeProgress.reading(fraction)
        if case .reading(let value) = progress {
            XCTAssertEqual(value, fraction, accuracy: 0.000_01)
        } else {
            XCTFail("Expected .reading case")
        }
    }

    func testDicomVolumeProgressReadingZeroFraction() {
        let progress = DicomVolumeProgress.reading(0.0)
        if case .reading(let value) = progress {
            XCTAssertEqual(value, 0.0, accuracy: 0.000_01)
        } else {
            XCTFail("Expected .reading case with zero")
        }
    }

    func testDicomVolumeProgressReadingOneFraction() {
        let progress = DicomVolumeProgress.reading(1.0)
        if case .reading(let value) = progress {
            XCTAssertEqual(value, 1.0, accuracy: 0.000_01)
        } else {
            XCTFail("Expected .reading case with 1.0")
        }
    }

    // MARK: - DicomVolumeUIProgress

    func testDicomVolumeUIProgressStartedCaseCarriesTotalSlices() {
        let progress = DicomVolumeUIProgress.started(totalSlices: 100)
        if case .started(let count) = progress {
            XCTAssertEqual(count, 100)
        } else {
            XCTFail("Expected .started case")
        }
    }

    func testDicomVolumeUIProgressReadingCaseCarriesFraction() {
        let fraction = 0.75
        let progress = DicomVolumeUIProgress.reading(fraction)
        if case .reading(let value) = progress {
            XCTAssertEqual(value, fraction, accuracy: 0.000_01)
        } else {
            XCTFail("Expected .reading case")
        }
    }

    func testDicomVolumeUIProgressStartedZeroSlices() {
        // Boundary: total slices of 0 is unusual but should not crash
        let progress = DicomVolumeUIProgress.started(totalSlices: 0)
        if case .started(let count) = progress {
            XCTAssertEqual(count, 0)
        } else {
            XCTFail("Expected .started(totalSlices: 0)")
        }
    }

    // MARK: - DICOMSeriesVolumeProtocol conformance

    func testMockDICOMVolumeConformsToProtocol() {
        // Verify the protocol contract can be satisfied with a concrete type
        let mock = MockDICOMSeriesVolume()
        let volume: any DICOMSeriesVolumeProtocol = mock
        XCTAssertEqual(volume.bitsAllocated, 16)
        XCTAssertEqual(volume.width, 512)
        XCTAssertEqual(volume.height, 512)
        XCTAssertEqual(volume.depth, 100)
        XCTAssertEqual(volume.spacingX, 0.5)
        XCTAssertEqual(volume.spacingY, 0.5)
        XCTAssertEqual(volume.spacingZ, 1.0)
        XCTAssertEqual(volume.rescaleSlope, 1.0)
        XCTAssertEqual(volume.rescaleIntercept, -1024.0)
        XCTAssertTrue(volume.isSignedPixel)
        XCTAssertEqual(volume.seriesDescription, "Test CT")
    }

    func testDICOMSeriesVolumeProtocolDefaultsModalityForExistingConformers() {
        let volume: any DICOMSeriesVolumeProtocol = MinimalDICOMSeriesVolume()
        XCTAssertEqual(volume.modality, "")
    }

    // MARK: - DicomSeriesLoading protocol

    func testMockDicomSeriesLoaderConformsToProtocol() throws {
        let loader: any DicomSeriesLoading = MockDicomSeriesLoader()
        let url = URL(fileURLWithPath: "/tmp/empty")
        XCTAssertThrowsError(try loader.loadSeries(at: url, progress: nil))
    }

    func testDicomSeriesLoaderProgressCallbackSignature() throws {
        let loader = ProgressCapturingLoader()
        let url = URL(fileURLWithPath: "/tmp/empty")
        var fractions: [Double] = []
        XCTAssertThrowsError(
            try loader.loadSeries(at: url) { fraction, _, _, _ in
                fractions.append(fraction)
            }
        )
        XCTAssertFalse(fractions.isEmpty, "Progress callback should have been called")
    }
}

// MARK: - Test Helpers

private struct MockDICOMSeriesVolume: DICOMSeriesVolumeProtocol {
    var bitsAllocated: Int { 16 }
    var width: Int { 512 }
    var height: Int { 512 }
    var depth: Int { 100 }
    var spacingX: Double { 0.5 }
    var spacingY: Double { 0.5 }
    var spacingZ: Double { 1.0 }
    var orientation: simd_float3x3 { matrix_identity_float3x3 }
    var origin: SIMD3<Float> { .zero }
    var rescaleSlope: Double { 1.0 }
    var rescaleIntercept: Double { -1024.0 }
    var isSignedPixel: Bool { true }
    var seriesDescription: String { "Test CT" }
    var modality: String { "CT" }
}

private struct MinimalDICOMSeriesVolume: DICOMSeriesVolumeProtocol {
    var bitsAllocated: Int { 16 }
    var width: Int { 1 }
    var height: Int { 1 }
    var depth: Int { 1 }
    var spacingX: Double { 1 }
    var spacingY: Double { 1 }
    var spacingZ: Double { 1 }
    var orientation: simd_float3x3 { matrix_identity_float3x3 }
    var origin: SIMD3<Float> { .zero }
    var rescaleSlope: Double { 1 }
    var rescaleIntercept: Double { 0 }
    var isSignedPixel: Bool { true }
    var seriesDescription: String { "" }
}

private class MockDicomSeriesLoader: DicomSeriesLoading {
    func loadSeries(at url: URL, progress: ((Double, UInt, Data?, Any) -> Void)?) throws -> Any {
        throw NSError(domain: "MockLoader", code: 999,
                      userInfo: [NSLocalizedDescriptionKey: "Mock loader error"])
    }
}

private class ProgressCapturingLoader: DicomSeriesLoading {
    func loadSeries(at url: URL, progress: ((Double, UInt, Data?, Any) -> Void)?) throws -> Any {
        progress?(0.5, 1, nil, NSObject())
        progress?(1.0, 2, nil, NSObject())
        throw NSError(domain: "ProgressLoader", code: 1, userInfo: nil)
    }
}
