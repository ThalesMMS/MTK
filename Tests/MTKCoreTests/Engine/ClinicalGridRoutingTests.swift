import CoreGraphics
import XCTest

@_spi(Testing) @testable import MTKCore

final class ClinicalGridRoutingTests: MTKRenderingEngineTestCase {
    private typealias ClinicalViewportSet = (
        axial: ViewportID,
        coronal: ViewportID,
        sagittal: ViewportID,
        fourth: ViewportID
    )

    override func setUp() async throws {
        try await super.setUp()
        ClinicalProfiler.shared.reset()
    }

    override func tearDown() async throws {
        _ = ClinicalProfiler.shared.endSession()
        try await super.tearDown()
    }

    func testClinicalGridWithDVRInFourthViewportResolvesFrontToBack() async throws {
        try await assertClinicalGridFourthViewport(type: .volume3D,
                                                   expectedCompositing: .frontToBack)
    }

    func testClinicalGridWithMIPInFourthViewportResolvesMaximumIntensity() async throws {
        try await assertClinicalGridFourthViewport(type: .projection(mode: .mip),
                                                   expectedCompositing: .maximumIntensity)
    }

    func testClinicalGridWithAIPInFourthViewportResolvesAverageIntensity() async throws {
        try await assertClinicalGridFourthViewport(type: .projection(mode: .aip),
                                                   expectedCompositing: .averageIntensity)
    }

    func testClinicalGridWithMinIPInFourthViewportResolvesMinimumIntensity() async throws {
        try await assertClinicalGridFourthViewport(type: .projection(mode: .minip),
                                                   expectedCompositing: .minimumIntensity)
    }

    func testClinicalGridProducesFramesForAllFourViewportsWhenDatasetIsLoaded() async throws {
        let viewports = try await createClinicalGridViewports(fourthType: .volume3D)
        try await engine.setVolume(testDataset, for: viewportIDs(for: viewports))

        let frames = try await renderAllViewports(viewports)

        XCTAssertEqual(frames.count, 4)
        XCTAssertTrue(frames.allSatisfy { $0.texture.width > 0 && $0.texture.height > 0 })
        XCTAssertEqual(frames.filter { $0.route.primaryPass?.kind == .volumeRaycast }.count, 1)
        XCTAssertEqual(frames.filter { $0.route.primaryPass?.kind == .mprReslice }.count, 3)
        releaseLeases(from: frames)
    }

    func testClinicalGridMissingDatasetOnFourthViewportThrowsExplicitError() async throws {
        let viewports = try await createClinicalGridViewports(fourthType: .projection(mode: .mip))
        try await engine.setVolume(testDataset, for: [viewports.axial, viewports.coronal, viewports.sagittal])

        do {
            _ = try await engine.render(viewports.fourth)
            XCTFail("Expected volumeNotSet for viewport \(viewports.fourth)")
        } catch MTKRenderingEngine.EngineError.volumeNotSet(let viewportID) {
            XCTAssertEqual(viewportID, viewports.fourth)
        } catch {
            XCTFail("Expected volumeNotSet, got \(error)")
        }
    }

    func testClinicalGridRenderRecordsRenderGraphRouteSample() async throws {
        let viewports = try await createClinicalGridViewports(fourthType: .projection(mode: .aip))
        try await engine.setVolume(testDataset, for: viewportIDs(for: viewports))
        await engine.setProfilingOptions(.init(measureRenderTime: true))

        let frame = try await engine.render(viewports.fourth)
        defer { frame.outputTextureLease?.release() }
        let session = ClinicalProfiler.shared.endSession()
        let routeSample = try XCTUnwrap(
            session.samples.first {
                $0.stageType == .renderGraphRoute &&
                $0.metadata?["viewportID"] == String(describing: viewports.fourth)
            }
        )

        XCTAssertEqual(routeSample.viewportContext.viewportType, "projection.aip")
        XCTAssertEqual(routeSample.metadata?["routeName"], "projection.aip")
        XCTAssertEqual(routeSample.metadata?["viewportID"], String(describing: viewports.fourth))
    }
}

private extension ClinicalGridRoutingTests {
    func assertClinicalGridFourthViewport(type: ViewportType,
                                          expectedCompositing: VolumeRenderRequest.Compositing,
                                          file: StaticString = #filePath,
                                          line: UInt = #line) async throws {
        let viewports = try await createClinicalGridViewports(fourthType: type)
        try await engine.setVolume(testDataset, for: viewportIDs(for: viewports))

        let frames = try await renderAllViewports(viewports)
        let fourthFrame = try XCTUnwrap(frames.first { $0.viewportID == viewports.fourth },
                                        file: file,
                                        line: line)

        XCTAssertEqual(fourthFrame.route.primaryPass?.kind, .volumeRaycast, file: file, line: line)
        XCTAssertEqual(fourthFrame.route.primaryPass?.compositing, expectedCompositing, file: file, line: line)
        XCTAssertEqual(fourthFrame.metadata.renderGraphRoute, fourthFrame.route.profilingName, file: file, line: line)
        XCTAssertGreaterThan(fourthFrame.texture.width, 0, file: file, line: line)
        XCTAssertGreaterThan(fourthFrame.texture.height, 0, file: file, line: line)
        releaseLeases(from: frames)
    }

    private func createClinicalGridViewports(fourthType: ViewportType) async throws -> ClinicalViewportSet {
        (
            axial: try await engine.createViewport(
                ViewportDescriptor(type: .mpr(axis: .axial),
                                   initialSize: CGSize(width: 32, height: 32))
            ),
            coronal: try await engine.createViewport(
                ViewportDescriptor(type: .mpr(axis: .coronal),
                                   initialSize: CGSize(width: 32, height: 32))
            ),
            sagittal: try await engine.createViewport(
                ViewportDescriptor(type: .mpr(axis: .sagittal),
                                   initialSize: CGSize(width: 32, height: 32))
            ),
            fourth: try await engine.createViewport(
                ViewportDescriptor(type: fourthType,
                                   initialSize: CGSize(width: 32, height: 32))
            )
        )
    }

    private func viewportIDs(for viewports: ClinicalViewportSet) -> [ViewportID] {
        [viewports.axial, viewports.coronal, viewports.sagittal, viewports.fourth]
    }

    private func renderAllViewports(_ viewports: ClinicalViewportSet) async throws -> [RenderFrame] {
        async let axial = engine.render(viewports.axial)
        async let coronal = engine.render(viewports.coronal)
        async let sagittal = engine.render(viewports.sagittal)
        async let fourth = engine.render(viewports.fourth)

        return try await [axial, coronal, sagittal, fourth]
    }

    func releaseLeases(from frames: [RenderFrame]) {
        frames.forEach { $0.outputTextureLease?.release() }
    }
}
