import XCTest

import MTKCore
import simd
@testable import MTKDicomBridge

final class DicomBridgePackagingTests: XCTestCase {
    func testBridgeProvidesDefaultDecoderBackedLoaderWithoutChangingCoreInitializer() {
        let bridgeLoader: any DicomSeriesLoading = DicomDecoderSeriesLoader()
        let volumeLoader = DicomVolumeLoader()

        XCTAssertEqual(String(describing: type(of: bridgeLoader)), "DicomDecoderSeriesLoader")
        _ = volumeLoader
    }

    func testLoaderMetadataDrivesDicomVolumeLoaderWindow() throws {
        let loader = DicomVolumeLoader(seriesLoader: BridgedMetadataSeriesLoader())
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectation = expectation(description: "DICOM bridge import")
        var outcome: Result<DicomImportResult, Error>?

        loader.loadVolume(from: directory, progress: { _ in }, completion: { result in
            outcome = result
            expectation.fulfill()
        })

        wait(for: [expectation], timeout: 5)

        let result = try XCTUnwrap(outcome?.get())
        XCTAssertEqual(result.dataset.recommendedWindow, 91...468)
        XCTAssertEqual(result.dataset.imageData.clinicalMetadata?.modality, "CT")
        XCTAssertFalse(result.warnings.contains { $0.code == .usedFallbackWindow })
    }

    func testBridgeMetadataParserReadsExplicitVRWindowTags() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("slice.dcm")
        try makeMinimalDICOMHeader(modality: "CT", windowCenter: "280", windowWidth: "378").write(to: fileURL)

        let metadata = DicomDecoderSeriesLoader.readMetadata(from: directory)

        XCTAssertEqual(metadata.modality, "CT")
        XCTAssertEqual(metadata.windowCenter, 280)
        XCTAssertEqual(metadata.windowWidth, 378)
    }

    func testBridgeMetadataParserSkipsUndefinedLengthSequenceBeforeWindowTags() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("slice.dcm")
        try makeMinimalDICOMHeader(
            modality: "CT",
            windowCenter: "280",
            windowWidth: "378",
            includeUndefinedSequenceBeforeWindow: true
        ).write(to: fileURL)

        let metadata = DicomDecoderSeriesLoader.readMetadata(from: directory)

        XCTAssertEqual(metadata.modality, "CT")
        XCTAssertEqual(metadata.windowCenter, 280)
        XCTAssertEqual(metadata.windowWidth, 378)
    }

    func testBridgeMetadataParserUsesIPPSpacingWhenSliceThicknessDiffers() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 0..<3 {
            let fileURL = directory.appendingPathComponent("slice-\(index).dcm")
            try makeMinimalDICOMHeader(
                modality: "CT",
                windowCenter: "280",
                windowWidth: "378",
                imageOrientation: "1\\0\\0\\0\\1\\0",
                imagePosition: "0\\0\\\(30.5 + Double(index))",
                sliceThickness: "2",
                instanceNumber: "\(index + 1)"
            ).write(to: fileURL)
        }

        let metadata = DicomDecoderSeriesLoader.readMetadata(from: directory)

        XCTAssertEqual(metadata.modality, "CT")
        XCTAssertEqual(try XCTUnwrap(metadata.spacingZ), 1.0, accuracy: 1e-6)
    }

    func testBridgeMetadataParserReadsDemoFixtureWindowAndIPPSpacingWhenAvailable() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = repositoryRoot
            .appendingPathComponent("MTK-Demo/DICOM_Example/dicom_series_example", isDirectory: true)
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("Demo DICOM fixture is not available.")
        }

        let metadata = DicomDecoderSeriesLoader.readMetadata(from: fixture)

        XCTAssertEqual(metadata.modality, "CT")
        XCTAssertEqual(metadata.windowCenter, 35)
        XCTAssertEqual(metadata.windowWidth, 80)
        XCTAssertEqual(try XCTUnwrap(metadata.spacingZ), 1.0, accuracy: 1e-6)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DicomBridgePackagingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeMinimalDICOMHeader(modality: String,
                                        windowCenter: String,
                                        windowWidth: String,
                                        imageOrientation: String? = nil,
                                        imagePosition: String? = nil,
                                        sliceThickness: String? = nil,
                                        instanceNumber: String? = nil,
                                        includeUndefinedSequenceBeforeWindow: Bool = false) -> Data {
        var data = Data(repeating: 0, count: 128)
        data.append(contentsOf: [0x44, 0x49, 0x43, 0x4D])
        appendExplicitTag(group: 0x0008, element: 0x0060, vr: "CS", value: modality, to: &data)
        if includeUndefinedSequenceBeforeWindow {
            appendUndefinedLengthSequence(to: &data)
        }
        if let instanceNumber {
            appendExplicitTag(group: 0x0020, element: 0x0013, vr: "IS", value: instanceNumber, to: &data)
        }
        if let sliceThickness {
            appendExplicitTag(group: 0x0018, element: 0x0050, vr: "DS", value: sliceThickness, to: &data)
        }
        if let imageOrientation {
            appendExplicitTag(group: 0x0020, element: 0x0037, vr: "DS", value: imageOrientation, to: &data)
        }
        if let imagePosition {
            appendExplicitTag(group: 0x0020, element: 0x0032, vr: "DS", value: imagePosition, to: &data)
        }
        appendExplicitTag(group: 0x0028, element: 0x1050, vr: "DS", value: windowCenter, to: &data)
        appendExplicitTag(group: 0x0028, element: 0x1051, vr: "DS", value: windowWidth, to: &data)
        appendExplicitTag(group: 0x7FE0, element: 0x0010, vr: "OW", value: "", to: &data)
        return data
    }

    private func appendExplicitTag(group: UInt16,
                                   element: UInt16,
                                   vr: String,
                                   value: String,
                                   to data: inout Data) {
        appendUInt16LE(group, to: &data)
        appendUInt16LE(element, to: &data)
        data.append(contentsOf: vr.utf8)
        var valueData = Data(value.utf8)
        if valueData.count % 2 != 0 {
            valueData.append(0x20)
        }

        if ["OB", "OD", "OF", "OL", "OW", "SQ", "UC", "UR", "UT", "UN"].contains(vr) {
            data.append(contentsOf: [0x00, 0x00])
            appendUInt32LE(UInt32(valueData.count), to: &data)
        } else {
            appendUInt16LE(UInt16(valueData.count), to: &data)
        }
        data.append(valueData)
    }

    private func appendUndefinedLengthSequence(to data: inout Data) {
        appendUInt16LE(0x0008, to: &data)
        appendUInt16LE(0x1032, to: &data)
        data.append(contentsOf: "SQ".utf8)
        data.append(contentsOf: [0x00, 0x00])
        appendUInt32LE(UInt32.max, to: &data)
        appendUInt16LE(0xFFFE, to: &data)
        appendUInt16LE(0xE000, to: &data)
        appendUInt32LE(0, to: &data)
        appendUInt16LE(0xFFFE, to: &data)
        appendUInt16LE(0xE0DD, to: &data)
        appendUInt32LE(0, to: &data)
    }

    private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0x00FF))
        data.append(UInt8((value >> 8) & 0x00FF))
    }

    private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0x000000FF))
        data.append(UInt8((value >> 8) & 0x000000FF))
        data.append(UInt8((value >> 16) & 0x000000FF))
        data.append(UInt8((value >> 24) & 0x000000FF))
    }
}

private final class BridgedMetadataSeriesLoader: DicomSeriesLoading {
    func loadSeries(at url: URL,
                    progress: ((Double, UInt, Data?, Any) -> Void)?) throws -> Any {
        let volume = MetadataVolume()
        let sliceVoxelCount = volume.width * volume.height
        let voxels = [Int16](repeating: 280, count: sliceVoxelCount * volume.depth)

        for z in 0..<volume.depth {
            let start = z * sliceVoxelCount
            let end = start + sliceVoxelCount
            let sliceValues = Array(voxels[start..<end])
            let sliceData = sliceValues.withUnsafeBytes { Data($0) }
            progress?(Double(z + 1) / Double(volume.depth), UInt(z + 1), sliceData, volume)
        }

        return volume
    }
}

private struct MetadataVolume: DICOMSeriesVolumeProtocol {
    let bitsAllocated = 16
    let width = 2
    let height = 2
    let depth = 2
    let spacingX = 1.0
    let spacingY = 1.0
    let spacingZ = 1.0
    let orientation = matrix_identity_float3x3
    let origin = SIMD3<Float>(0, 0, 0)
    let rescaleSlope = 1.0
    let rescaleIntercept = 0.0
    let isSignedPixel = true
    let seriesDescription = "Falcon metadata fixture"
    let modality = "CT"
    let windowCenter: Double? = 280
    let windowWidth: Double? = 378
}
