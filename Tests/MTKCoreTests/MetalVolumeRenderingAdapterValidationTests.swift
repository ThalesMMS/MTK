import CoreGraphics
import simd
import XCTest

@testable import MTKCore

final class MetalVolumeRenderingAdapterValidationTests: XCTestCase {
    func testRenderFrameThrowsWhenWindowIsNotSpecified() async throws {
        let adapter = try makeTestAdapter()
        let dataset = makeDataset(recommendedWindow: nil)
        let request = makeRequest(dataset: dataset, transferFunction: validTransferFunction())

        do {
            _ = try await adapter.renderFrame(using: request)
            XCTFail("Expected renderFrame to throw when no window is available")
        } catch let error as MetalVolumeRenderingAdapter.AdapterError {
            XCTAssertEqual(error, .windowNotSpecified)
        }
    }

    func testRenderFrameThrowsWhenColourPointsAreEmpty() async throws {
        let adapter = try makeTestAdapter()
        let dataset = makeDataset(recommendedWindow: 0...4095)
        let transfer = VolumeTransferFunction(
            opacityPoints: [VolumeTransferFunction.OpacityControlPoint(intensity: 0, opacity: 1)],
            colourPoints: []
        )

        do {
            _ = try await adapter.renderFrame(using: makeRequest(dataset: dataset, transferFunction: transfer))
            XCTFail("Expected renderFrame to reject empty color control points")
        } catch let error as MetalVolumeRenderingAdapter.AdapterError {
            XCTAssertEqual(error, .emptyColorPoints)
        }
    }

    func testRenderFrameThrowsWhenAlphaPointsAreEmpty() async throws {
        let adapter = try makeTestAdapter()
        let dataset = makeDataset(recommendedWindow: 0...4095)
        let transfer = VolumeTransferFunction(
            opacityPoints: [],
            colourPoints: [VolumeTransferFunction.ColourControlPoint(intensity: 0, colour: SIMD4<Float>(1, 1, 1, 1))]
        )

        do {
            _ = try await adapter.renderFrame(using: makeRequest(dataset: dataset, transferFunction: transfer))
            XCTFail("Expected renderFrame to reject empty alpha control points")
        } catch let error as MetalVolumeRenderingAdapter.AdapterError {
            XCTAssertEqual(error, .emptyAlphaPoints)
        }
    }

    func testRenderFrameThrowsWhenCameraMatrixIsDegenerate() async throws {
        let adapter = try makeTestAdapter()
        let dataset = makeDataset(recommendedWindow: 0...4095)
        let camera = VolumeRenderRequest.Camera(
            position: SIMD3<Float>(0, 0, 0),
            target: SIMD3<Float>(0, 0, 0),
            up: SIMD3<Float>(0, 1, 0),
            fieldOfView: 45
        )

        do {
            _ = try await adapter.renderFrame(using: makeRequest(dataset: dataset,
                                                                 transferFunction: validTransferFunction(),
                                                                 camera: camera))
            XCTFail("Expected renderFrame to reject a degenerate camera matrix")
        } catch let error as MetalVolumeRenderingAdapter.AdapterError {
            XCTAssertEqual(error, .degenerateCameraMatrix)
        }
    }

    func testRefreshHistogramThrowsWhenDatasetReaderCannotBeCreated() async throws {
        let adapter = try makeTestAdapter()
        let dataset = VolumeDataset(
            data: Data(),
            dimensions: VolumeDimensions(width: 2, height: 2, depth: 2),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned,
            recommendedWindow: 0...4095
        )
        let descriptor = VolumeHistogramDescriptor(binCount: 16, intensityRange: 0...4095, normalize: true)

        do {
            _ = try await adapter.refreshHistogram(for: dataset,
                                                   descriptor: descriptor,
                                                   transferFunction: validTransferFunction())
            XCTFail("Expected refreshHistogram to throw when dataset reader construction fails")
        } catch let error as MetalVolumeRenderingAdapter.AdapterError {
            XCTAssertEqual(error, .datasetReadFailed)
        }
    }

    func testExtendedPlaceholderMethodsThrowExplicitErrors() async throws {
        let adapter = try makeTestAdapter()

        do {
            try await adapter.setRenderMethod(1)
            XCTFail("Expected setRenderMethod to throw")
        } catch let error as MetalVolumeRenderingAdapter.AdapterError {
            XCTAssertEqual(error, .notSupported)
        }

        do {
            try await adapter.setMPRBlend(0.5)
            XCTFail("Expected setMPRBlend to throw")
        } catch let error as MetalVolumeRenderingAdapter.AdapterError {
            XCTAssertEqual(error, .notSupported)
        }

        do {
            _ = try await adapter.getHistogram()
            XCTFail("Expected getHistogram to throw")
        } catch let error as MetalVolumeRenderingAdapter.AdapterError {
            XCTAssertEqual(error, .histogramNotAvailable)
        }

        do {
            try await adapter.alignClipBoxToView()
            XCTFail("Expected alignClipBoxToView to throw")
        } catch let error as MetalVolumeRenderingAdapter.AdapterError {
            XCTAssertEqual(error, .notImplemented)
        }

        do {
            try await adapter.alignClipPlaneToView()
            XCTFail("Expected alignClipPlaneToView to throw")
        } catch let error as MetalVolumeRenderingAdapter.AdapterError {
            XCTAssertEqual(error, .notImplemented)
        }
    }

    private func makeDataset(recommendedWindow: ClosedRange<Int32>?) -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 8, height: 8, depth: 8)
        let values: [UInt16] = Array(repeating: 1_000, count: dimensions.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        return VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned,
            recommendedWindow: recommendedWindow
        )
    }

    private func makeRequest(
        dataset: VolumeDataset,
        transferFunction: VolumeTransferFunction,
        camera: VolumeRenderRequest.Camera? = nil
    ) -> VolumeRenderRequest {
        VolumeRenderRequest(
            dataset: dataset,
            transferFunction: transferFunction,
            viewportSize: CGSize(width: 64, height: 64),
            camera: camera ?? VolumeRenderRequest.Camera(
                position: SIMD3<Float>(0, 0, 3),
                target: SIMD3<Float>(0, 0, 0),
                up: SIMD3<Float>(0, 1, 0),
                fieldOfView: 45
            ),
            samplingDistance: 1 / 256,
            compositing: .frontToBack,
            quality: .interactive
        )
    }

    private func validTransferFunction() -> VolumeTransferFunction {
        VolumeTransferFunction(
            opacityPoints: [
                VolumeTransferFunction.OpacityControlPoint(intensity: 0, opacity: 0),
                VolumeTransferFunction.OpacityControlPoint(intensity: 4095, opacity: 1)
            ],
            colourPoints: [
                VolumeTransferFunction.ColourControlPoint(intensity: 0, colour: SIMD4<Float>(0, 0, 0, 1)),
                VolumeTransferFunction.ColourControlPoint(intensity: 4095, colour: SIMD4<Float>(1, 1, 1, 1))
            ]
        )
    }
}

// MARK: - AdapterError LocalizedError conformance

final class AdapterErrorLocalizedErrorTests: XCTestCase {
    private typealias AdapterError = MetalVolumeRenderingAdapter.AdapterError

    func testAllCasesHaveNonEmptyErrorDescription() {
        let allCases: [AdapterError] = [
            .invalidHistogramBinCount,
            .windowNotSpecified,
            .emptyColorPoints,
            .emptyAlphaPoints,
            .degenerateCameraMatrix,
            .datasetReadFailed,
            .notSupported,
            .histogramNotAvailable,
            .notImplemented,
        ]

        for error in allCases {
            let description = error.errorDescription
            XCTAssertNotNil(description, "Expected non-nil errorDescription for \(error)")
            XCTAssertFalse(description?.isEmpty ?? true, "Expected non-empty errorDescription for \(error)")
        }
    }

    func testAllCasesHaveNonEmptyFailureReason() {
        let allCases: [AdapterError] = [
            .invalidHistogramBinCount,
            .windowNotSpecified,
            .emptyColorPoints,
            .emptyAlphaPoints,
            .degenerateCameraMatrix,
            .datasetReadFailed,
            .notSupported,
            .histogramNotAvailable,
            .notImplemented,
        ]

        for error in allCases {
            let reason = error.failureReason
            XCTAssertNotNil(reason, "Expected non-nil failureReason for \(error)")
            XCTAssertFalse(reason?.isEmpty ?? true, "Expected non-empty failureReason for \(error)")
        }
    }

    func testErrorDescriptionContainsExpectedKeywords() {
        XCTAssertEqual(AdapterError.invalidHistogramBinCount.errorDescription, "Invalid histogram bin count")
        XCTAssertEqual(AdapterError.windowNotSpecified.errorDescription, "Window not specified")
        XCTAssertEqual(AdapterError.emptyColorPoints.errorDescription, "Color control points are empty")
        XCTAssertEqual(AdapterError.emptyAlphaPoints.errorDescription, "Alpha control points are empty")
        XCTAssertEqual(AdapterError.degenerateCameraMatrix.errorDescription, "Degenerate camera matrix")
        XCTAssertEqual(AdapterError.datasetReadFailed.errorDescription, "Dataset read failed")
        XCTAssertEqual(AdapterError.notSupported.errorDescription, "Operation not supported")
        XCTAssertEqual(AdapterError.histogramNotAvailable.errorDescription, "Histogram not available")
        XCTAssertEqual(AdapterError.notImplemented.errorDescription, "Operation not implemented")
    }

    func testFailureReasonContainsExpectedInformation() {
        // invalidHistogramBinCount
        let binCountReason = AdapterError.invalidHistogramBinCount.failureReason ?? ""
        XCTAssertTrue(binCountReason.contains("greater than zero"), "failureReason should explain bin count constraint")

        // windowNotSpecified
        let windowReason = AdapterError.windowNotSpecified.failureReason ?? ""
        XCTAssertTrue(windowReason.contains("window"), "failureReason should reference window")

        // emptyColorPoints
        let colorReason = AdapterError.emptyColorPoints.failureReason ?? ""
        XCTAssertTrue(colorReason.contains("color") || colorReason.contains("colour"), "failureReason should reference color points")

        // emptyAlphaPoints
        let alphaReason = AdapterError.emptyAlphaPoints.failureReason ?? ""
        XCTAssertTrue(alphaReason.contains("opacity") || alphaReason.contains("alpha"), "failureReason should reference opacity/alpha")

        // degenerateCameraMatrix
        let cameraReason = AdapterError.degenerateCameraMatrix.failureReason ?? ""
        XCTAssertTrue(cameraReason.contains("finite") || cameraReason.contains("camera"), "failureReason should reference camera/finite")

        // datasetReadFailed
        let datasetReason = AdapterError.datasetReadFailed.failureReason ?? ""
        XCTAssertTrue(datasetReason.contains("reader") || datasetReason.contains("dataset"), "failureReason should reference reader or dataset")

        // notSupported
        let notSupportedReason = AdapterError.notSupported.failureReason ?? ""
        XCTAssertTrue(notSupportedReason.contains("not supported") || notSupportedReason.contains("Metal"), "failureReason should explain the lack of support")

        // histogramNotAvailable
        let histogramReason = AdapterError.histogramNotAvailable.failureReason ?? ""
        XCTAssertTrue(histogramReason.contains("histogram"), "failureReason should reference histogram")

        // notImplemented
        let notImplReason = AdapterError.notImplemented.failureReason ?? ""
        XCTAssertTrue(notImplReason.contains("not been implemented") || notImplReason.contains("implemented"), "failureReason should state the operation is not implemented")
    }

    func testAdapterErrorEquatableConformance() {
        XCTAssertEqual(AdapterError.invalidHistogramBinCount, .invalidHistogramBinCount)
        XCTAssertEqual(AdapterError.windowNotSpecified, .windowNotSpecified)
        XCTAssertEqual(AdapterError.emptyColorPoints, .emptyColorPoints)
        XCTAssertEqual(AdapterError.emptyAlphaPoints, .emptyAlphaPoints)
        XCTAssertEqual(AdapterError.degenerateCameraMatrix, .degenerateCameraMatrix)
        XCTAssertEqual(AdapterError.datasetReadFailed, .datasetReadFailed)
        XCTAssertEqual(AdapterError.notSupported, .notSupported)
        XCTAssertEqual(AdapterError.histogramNotAvailable, .histogramNotAvailable)
        XCTAssertEqual(AdapterError.notImplemented, .notImplemented)

        XCTAssertNotEqual(AdapterError.invalidHistogramBinCount, .windowNotSpecified)
        XCTAssertNotEqual(AdapterError.emptyColorPoints, .emptyAlphaPoints)
        XCTAssertNotEqual(AdapterError.notSupported, .notImplemented)
    }

    func testAdapterErrorCanBeCastFromSwiftError() {
        let error: Error = AdapterError.windowNotSpecified
        XCTAssertNotNil(error as? AdapterError)
        XCTAssertEqual(error as? AdapterError, .windowNotSpecified)
    }
}
