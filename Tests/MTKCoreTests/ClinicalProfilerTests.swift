import XCTest
@testable import MTKCore

final class ClinicalProfilerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        clearSharedProfilerSession()
    }

    override func tearDown() {
        clearSharedProfilerSession()
        super.tearDown()
    }

    func testProfilingSessionJSONRoundTripsRequiredFields() throws {
        let environment = makeEnvironment()
        let sample = ProfilingSample(
            timestamp: Date(timeIntervalSince1970: 1_775_000_000),
            stageType: .snapshotReadback,
            cpuTimeMilliseconds: 12.5,
            gpuTimeMilliseconds: nil,
            memoryEstimateBytes: 4_194_304,
            viewportContext: ProfilingViewportContext(
                resolutionWidth: 1024,
                resolutionHeight: 768,
                viewportType: "snapshot",
                quality: "production",
                renderMode: "frontToBack"
            ),
            metadata: ["label": "readback"]
        )
        let session = ProfilingSession(
            sessionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            startTimestamp: Date(timeIntervalSince1970: 1_775_000_000),
            environment: environment,
            samples: [sample]
        )

        let data = try session.jsonData()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProfilingSession.self, from: data)

        XCTAssertEqual(decoded.environment.deviceName, "Unit Test GPU")
        XCTAssertEqual(decoded.environment.osVersion, "Unit Test OS")
        XCTAssertEqual(decoded.environment.architecture, "arm64")
        XCTAssertEqual(decoded.environment.modelIdentifier, "TestMac1,1")
        XCTAssertEqual(decoded.environment.buildConfiguration, "release")
        XCTAssertEqual(decoded.environment.benchmarkMode, "warm-isolated")
        XCTAssertEqual(decoded.environment.fixtureID, "ct-explicit-vr-le-rescale")
        XCTAssertEqual(decoded.environment.tier, "pr-smoke")
        XCTAssertFalse(decoded.environment.commandLineStartupIncluded)
        XCTAssertEqual(decoded.samples.first?.stageType, .snapshotReadback)
        XCTAssertEqual(decoded.samples.first?.viewportContext.resolutionWidth, 1024)
        XCTAssertEqual(decoded.samples.first?.viewportContext.resolutionHeight, 768)
        XCTAssertEqual(decoded.samples.first?.viewportContext.quality, "production")
        XCTAssertEqual(decoded.samples.first?.memoryEstimateBytes, 4_194_304)
    }

    func testCSVExportIncludesEnvironmentContextAndReadbackStage() {
        let session = ProfilingSession(
            environment: makeEnvironment(),
            samples: [
                ProfilingSample(
                    stageType: .textureUpload,
                    cpuTimeMilliseconds: 3.25,
                    gpuTimeMilliseconds: 2.5,
                    memoryEstimateBytes: 2048,
                    viewportContext: ProfilingViewportContext(
                        resolutionWidth: 512,
                        resolutionHeight: 512,
                        viewportType: "volume3D",
                        quality: "interactive",
                        renderMode: "frontToBack"
                    )
                ),
                ProfilingSample(
                    stageType: .snapshotReadback,
                    cpuTimeMilliseconds: 9.75,
                    memoryEstimateBytes: 4096,
                    viewportContext: ProfilingViewportContext(
                        resolutionWidth: 512,
                        resolutionHeight: 512,
                        viewportType: "snapshot",
                        quality: "production",
                        renderMode: "readback"
                    )
                )
            ]
        )

        let csv = session.csvString()

        for header in ProfilingSession.csvHeaders {
            XCTAssertTrue(csv.contains(header), "Missing CSV header \(header)")
        }
        XCTAssertTrue(csv.contains("Unit Test GPU"))
        XCTAssertTrue(csv.contains("Unit Test OS"))
        XCTAssertTrue(csv.contains("ct-explicit-vr-le-rescale"))
        XCTAssertTrue(csv.contains("warm-isolated"))
        XCTAssertTrue(csv.contains("pr-smoke"))
        XCTAssertTrue(csv.contains("512"))
        XCTAssertTrue(csv.contains("interactive"))
        XCTAssertTrue(csv.contains("production"))
        XCTAssertTrue(csv.contains("textureUpload"))
        XCTAssertTrue(csv.contains("snapshotReadback"))
        XCTAssertTrue(csv.contains("readback"))
    }

    func testRequiredClinicalProfilingStagesAreRepresented() {
        let required: Set<ProfilingStage> = [
            .dicomParse,
            .huConversion,
            .renderGraphRoute,
            .textureUpload,
            .texturePreparation,
            .mprReslice,
            .volumeRaycast,
            .presentationPass,
            .snapshotReadback,
            .memorySnapshot
        ]

        XCTAssertEqual(Set(ProfilingStage.allCases), required)
    }

    func testSharedProfilerRecordsAndEndsSession() {
        let profiler = ClinicalProfiler.shared
        profiler.startSession(environment: makeEnvironment())

        profiler.recordSample(
            stage: .volumeRaycast,
            cpuTime: 4.5,
            gpuTime: 3.0,
            memory: 8192,
            viewport: ProfilingViewportContext(
                resolutionWidth: 640,
                resolutionHeight: 480,
                viewportType: "volume3D",
                quality: "interactive",
                renderMode: "frontToBack"
            ),
            routeName: "volume3D.frontToBack",
            metadata: ["path": "unit-test"]
        )

        let session = profiler.endSession()

        XCTAssertNotNil(session.endTimestamp)
        XCTAssertEqual(session.samples.count, 1)
        XCTAssertEqual(session.samples.first?.stageType, .volumeRaycast)
        XCTAssertEqual(session.samples.first?.gpuTimeMilliseconds, 3.0)
        XCTAssertEqual(session.samples.first?.metadata?["routeName"], "volume3D.frontToBack")
    }

    func testSharedProfilerClearsActiveSessionWhenEnded() {
        let profiler = ClinicalProfiler.shared
        profiler.startSession(environment: makeEnvironment())
        profiler.recordSample(stage: .presentationPass,
                              cpuTime: 1.0,
                              viewport: ProfilingViewportContext(
                                  resolutionWidth: 640,
                                  resolutionHeight: 480,
                                  viewportType: "presentation",
                                  quality: "interactive",
                                  renderMode: "drawableBlit"
                              ))

        let session = profiler.endSession()

        XCTAssertEqual(session.samples.count, 1)
        XCTAssertNil(profiler.sessionSnapshot())
    }

    func test_recordSampleWithoutActiveSession_doesNotCreateSession() {
        let profiler = ClinicalProfiler.shared

        profiler.recordSample(stage: .volumeRaycast, cpuTime: 1)

        XCTAssertNil(profiler.sessionSnapshot())
    }

    func test_activeSession_stopsRecordingAtSampleLimit() {
        let profiler = ClinicalProfiler.shared
        profiler.startSession(environment: makeEnvironment())

        for _ in 0...ClinicalProfiler.maximumSampleCount {
            profiler.recordSample(stage: .volumeRaycast, cpuTime: 1)
        }

        XCTAssertEqual(profiler.sessionSnapshot()?.samples.count,
                       ClinicalProfiler.maximumSampleCount)
        XCTAssertFalse(profiler.isRecordingEnabled)
    }

    private func makeEnvironment() -> ProfilingEnvironment {
        ProfilingEnvironment(
            deviceName: "Unit Test GPU",
            osVersion: "Unit Test OS",
            gpuFamily: "common3",
            maxThreadsPerThreadgroupDimensions: ProfilingThreadgroupDimensions(width: 1024, height: 1024, depth: 64),
            recommendedMaxWorkingSetSize: 8_589_934_592,
            appVersion: "1.0",
            buildNumber: "100",
            architecture: "arm64",
            modelIdentifier: "TestMac1,1",
            buildConfiguration: "release",
            benchmarkMode: "warm-isolated",
            fixtureID: "ct-explicit-vr-le-rescale",
            tier: "pr-smoke",
            commandLineStartupIncluded: false
        )
    }

    private func clearSharedProfilerSession() {
        if ClinicalProfiler.shared.sessionSnapshot() != nil {
            _ = ClinicalProfiler.shared.endSession()
        }
    }
}
