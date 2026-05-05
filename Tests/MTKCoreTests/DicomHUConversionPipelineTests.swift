import Foundation
import Metal
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

    func test_loadVolume_populatesImageDataGeometryAndClinicalMetadata_forUnsignedSource() throws {
        let direction = simd_float3x3(columns: (
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0, 0, 1),
            SIMD3<Float>(1, 0, 0)
        ))
        let loader = DicomVolumeLoader(seriesLoader: SyntheticSeriesLoader(
            slope: 2.0,
            intercept: -1024.0,
            isSigned: false,
            unsignedSlices: [[0, 1, 2, 3]],
            spacing: SIMD3<Double>(0.7, 0.8, 2.5),
            orientation: direction,
            origin: SIMD3<Float>(10, 20, 30),
            modality: "MR",
            seriesDescription: "Oblique MR",
            studyInstanceUID: "1.2.3.4.5",
            seriesInstanceUID: "1.2.3.4.5.6",
            frameOfReferenceUID: "1.2.3.4.5.7",
            windowCenter: 100,
            windowWidth: 200
        ))

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectation = expectation(description: "DICOM load")
        var outcome: Result<VolumeDataset, Error>?

        loader.loadVolume(from: directory, progress: { _ in }, completion: { result in
            outcome = result.map(\.dataset)
            expectation.fulfill()
        })

        wait(for: [expectation], timeout: 5)

        let dataset = try XCTUnwrap(outcome?.get())
        XCTAssertEqual(dataset.pixelFormat, .int16Signed)
        XCTAssertEqual(dataset.imageData.pixelFormat, .int16Signed)
        XCTAssertEqual(dataset.imageData.spacing.x, 0.7, accuracy: 1e-6)
        XCTAssertEqual(dataset.imageData.spacing.y, 0.8, accuracy: 1e-6)
        XCTAssertEqual(dataset.imageData.spacing.z, 2.5, accuracy: 1e-6)
        XCTAssertEqual(dataset.imageData.origin, SIMD3<Float>(10, 20, 30))
        XCTAssertEqual(dataset.imageData.rowDirection, SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(dataset.imageData.columnDirection, SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(dataset.imageData.sliceDirection, SIMD3<Float>(1, 0, 0))

        let metadata = try XCTUnwrap(dataset.imageData.clinicalMetadata)
        XCTAssertEqual(metadata.modality, "MR")
        XCTAssertEqual(metadata.seriesDescription, "Oblique MR")
        XCTAssertEqual(metadata.studyInstanceUID, "1.2.3.4.5")
        XCTAssertEqual(metadata.seriesInstanceUID, "1.2.3.4.5.6")
        XCTAssertEqual(metadata.frameOfReferenceUID, "1.2.3.4.5.7")
        XCTAssertEqual(metadata.rescaleSlope, 2.0)
        XCTAssertEqual(metadata.rescaleIntercept, -1024.0)
        XCTAssertEqual(metadata.sourcePixelFormat, .int16Unsigned)
        XCTAssertEqual(metadata.windowCenter, 100)
        XCTAssertEqual(metadata.windowWidth, 200)
    }

    func test_loadVolumeFeedsSlopeInterceptHUIntoMPR() async throws {
        let loader = DicomVolumeLoader(seriesLoader: SyntheticSeriesLoader(
            slope: 2.0,
            intercept: -1024.0,
            isSigned: false,
            unsignedSlices: [
                [0, 2, 4, 8],
                [0, 2, 4, 8]
            ],
            spacing: SIMD3<Double>(0.8, 1.2, 2.4),
            orientation: matrix_identity_float3x3,
            origin: SIMD3<Float>(5, 10, 15),
            modality: "CT",
            seriesDescription: "Synthetic CT HU MPR"
        ))

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let dataset = try await loadDataset(using: loader, from: directory)
        XCTAssertEqual(dataset.pixelFormat, .int16Signed)
        XCTAssertEqual(dataset.intensityRange, -1024 ... -1008)
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.sourcePixelFormat, .int16Unsigned)
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.rescaleSlope, 2.0)
        XCTAssertEqual(dataset.imageData.clinicalMetadata?.rescaleIntercept, -1024.0)

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Failed to create Metal command queue")
        }
        let adapter = MetalMPRComputeAdapter(
            device: device,
            commandQueue: commandQueue,
            library: try ShaderLibraryLoader.loadLibrary(for: device),
            featureFlags: FeatureFlags.evaluate(for: device),
            debugOptions: VolumeRenderingDebugOptions()
        )
        let volumeTexture = try await VolumeTextureFactory(dataset: dataset)
            .generateAsync(device: device, commandQueue: commandQueue)
        let plane = MPRPlaneGeometryFactory.makePlane(for: dataset,
                                                      axis: .z,
                                                      slicePosition: 0)

        let frame = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        let actual = try MPRTextureReadbackHelper.readValues(Int16.self,
                                                             from: frame,
                                                             device: device,
                                                             commandQueue: commandQueue)
        XCTAssertEqual(actual, [-1024, -1020, -1016, -1008])
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DicomHUConversionPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func loadDataset(using loader: DicomVolumeLoader,
                             from directory: URL) async throws -> VolumeDataset {
        try await withCheckedThrowingContinuation { continuation in
            loader.loadVolume(from: directory, progress: { _ in }, completion: { result in
                continuation.resume(with: result.map(\.dataset))
            })
        }
    }
}

private final class SyntheticSeriesLoader: DicomSeriesLoading {
    private let volume: any DICOMSeriesVolumeProtocol

    init(slope: Double,
         intercept: Double,
         isSigned: Bool,
         slices: [[Int16]],
         spacing: SIMD3<Double> = SIMD3<Double>(1, 1, 1),
         orientation: simd_float3x3 = matrix_identity_float3x3,
         origin: SIMD3<Float> = .zero,
         modality: String = "CT",
         seriesDescription: String = "Synthetic HU Series",
         studyInstanceUID: String? = nil,
         seriesInstanceUID: String? = nil,
         frameOfReferenceUID: String? = nil,
         windowCenter: Double? = nil,
         windowWidth: Double? = nil) {
        self.volume = SyntheticVolume(
            slices: slices.map { $0.withUnsafeBytes { Data($0) } },
            isSigned: isSigned,
            slope: slope,
            intercept: intercept,
            spacing: spacing,
            orientation: orientation,
            origin: origin,
            modality: modality,
            seriesDescription: seriesDescription,
            studyInstanceUID: studyInstanceUID,
            seriesInstanceUID: seriesInstanceUID,
            frameOfReferenceUID: frameOfReferenceUID,
            windowCenter: windowCenter,
            windowWidth: windowWidth
        )
    }

    init(slope: Double,
         intercept: Double,
         isSigned: Bool,
         unsignedSlices: [[UInt16]],
         spacing: SIMD3<Double> = SIMD3<Double>(1, 1, 1),
         orientation: simd_float3x3 = matrix_identity_float3x3,
         origin: SIMD3<Float> = .zero,
         modality: String = "CT",
         seriesDescription: String = "Synthetic HU Series",
         studyInstanceUID: String? = nil,
         seriesInstanceUID: String? = nil,
         frameOfReferenceUID: String? = nil,
         windowCenter: Double? = nil,
         windowWidth: Double? = nil) {
        self.volume = SyntheticVolume(
            slices: unsignedSlices.map { $0.withUnsafeBytes { Data($0) } },
            isSigned: isSigned,
            slope: slope,
            intercept: intercept,
            spacing: spacing,
            orientation: orientation,
            origin: origin,
            modality: modality,
            seriesDescription: seriesDescription,
            studyInstanceUID: studyInstanceUID,
            seriesInstanceUID: seriesInstanceUID,
            frameOfReferenceUID: frameOfReferenceUID,
            windowCenter: windowCenter,
            windowWidth: windowWidth
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
    let spacingX: Double
    let spacingY: Double
    let spacingZ: Double
    let orientation: simd_float3x3
    let origin: SIMD3<Float>
    let rescaleSlope: Double
    let rescaleIntercept: Double
    let isSignedPixel: Bool
    let seriesDescription: String
    let modality: String
    let studyInstanceUID: String?
    let seriesInstanceUID: String?
    let frameOfReferenceUID: String?
    let windowCenter: Double?
    let windowWidth: Double?

    let slices: [Data]

    init(slices: [Data],
         isSigned: Bool,
         slope: Double,
         intercept: Double,
         spacing: SIMD3<Double>,
         orientation: simd_float3x3,
         origin: SIMD3<Float>,
         modality: String,
         seriesDescription: String,
         studyInstanceUID: String?,
         seriesInstanceUID: String?,
         frameOfReferenceUID: String?,
         windowCenter: Double?,
         windowWidth: Double?) {
        self.slices = slices
        self.isSignedPixel = isSigned
        self.rescaleSlope = slope
        self.rescaleIntercept = intercept
        self.spacingX = spacing.x
        self.spacingY = spacing.y
        self.spacingZ = spacing.z
        self.orientation = orientation
        self.origin = origin
        self.modality = modality
        self.seriesDescription = seriesDescription
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.frameOfReferenceUID = frameOfReferenceUID
        self.windowCenter = windowCenter
        self.windowWidth = windowWidth

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
