import XCTest

@testable import MTKCore

final class ClinicalBenchmarkReportTests: XCTestCase {
    func testRepresentativeBenchmarkSuiteCoversClinicalRoadmapScenarios() throws {
        let scenarios = ClinicalBenchmarkSuite.representativeScenarios
        let ids = Set(scenarios.map(\.id))
        let requiredIDs: Set<String> = [
            "ct-multi-viewport",
            "mip-slab-thick",
            "dvr-1d-transfer",
            "dvr-2d-gradient",
            "ct-pet-overlay",
            "volume-surface-segmentation",
            "dataset-swap",
            "continuous-resize",
            "snapshot-readback",
            "empty-space-skipping-toggle"
        ]

        XCTAssertEqual(ids, requiredIDs)
        XCTAssertEqual(scenarios.count, requiredIDs.count)

        for scenario in scenarios {
            XCTAssertFalse(scenario.name.isEmpty, scenario.id)
            XCTAssertFalse(scenario.volumeDescription.isEmpty, scenario.id)
            XCTAssertFalse(scenario.viewportLayout.isEmpty, scenario.id)
            XCTAssertFalse(scenario.benchmarkMode.isEmpty, scenario.id)
            XCTAssertFalse(scenario.expectedLimit.isEmpty, scenario.id)
            XCTAssertFalse(scenario.requiredStages.isEmpty, scenario.id)
        }

        let ctScenario = try XCTUnwrap(scenarios.first { $0.id == "ct-multi-viewport" })
        XCTAssertTrue(ctScenario.volumeDescription.contains("CT 512x512x300"))
        XCTAssertTrue(ctScenario.expectedLimit.contains("one shared volume texture"))

        let overlayScenario = try XCTUnwrap(scenarios.first { $0.id == "ct-pet-overlay" })
        XCTAssertTrue(overlayScenario.expectedLimit.contains("volumeLayerCount"))

        let surfaceScenario = try XCTUnwrap(scenarios.first { $0.id == "volume-surface-segmentation" })
        XCTAssertTrue(surfaceScenario.expectedLimit.contains("surfaceLayerCount"))
    }

    func testBenchmarkReportAggregatesSamplesAndExportsJSONAndCSV() throws {
        let scenarios = ClinicalBenchmarkSuite.representativeScenarios.filter {
            ["ct-multi-viewport", "ct-pet-overlay", "volume-surface-segmentation", "continuous-resize"].contains($0.id)
        }
        let session = ProfilingSession(
            sessionID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            startTimestamp: fixedDate(0),
            endTimestamp: fixedDate(5),
            environment: makeEnvironment(),
            samples: [
                makeSample(scenarioID: "ct-multi-viewport",
                           stage: .textureUpload,
                           cpuTime: 7.5,
                           gpuTime: 3.0,
                           memory: 524_288,
                           viewportType: "volume3D",
                           renderMode: "frontToBack",
                           metadata: ["volumeTextureCount": "1", "outputTexturePoolSize": "1"]),
                makeSample(scenarioID: "ct-multi-viewport",
                           stage: .mprReslice,
                           cpuTime: 2.5,
                           memory: 131_072,
                           viewportType: "mpr.axial",
                           renderMode: "single",
                           metadata: ["volumeTextureCount": "1", "outputTexturePoolSize": "1"]),
                makeSample(scenarioID: "ct-pet-overlay",
                           stage: .volumeRaycast,
                           cpuTime: 4.0,
                           gpuTime: 2.0,
                           memory: 700_000,
                           viewportType: "volume3D",
                           renderMode: "frontToBack",
                           metadata: ["volumeTextureCount": "2", "volumeLayerCount": "1"]),
                makeSample(scenarioID: "volume-surface-segmentation",
                           stage: .presentationPass,
                           cpuTime: 1.0,
                           memory: 710_000,
                           viewportType: "volume3D",
                           renderMode: "surfaceComposite",
                           metadata: ["volumeTextureCount": "1", "surfaceLayerCount": "1"])
            ]
        )

        let report = ClinicalBenchmarkSuite.makeReport(from: session,
                                                       scenarios: scenarios,
                                                       generatedAt: fixedDate(10),
                                                       metadata: ["mode": "ci-scaled", "fixture": "synthetic"])
        let measurements = Dictionary(uniqueKeysWithValues: report.measurements.map { ($0.scenarioID, $0) })
        let ct = try XCTUnwrap(measurements["ct-multi-viewport"])
        let overlay = try XCTUnwrap(measurements["ct-pet-overlay"])
        let surface = try XCTUnwrap(measurements["volume-surface-segmentation"])
        let resize = try XCTUnwrap(measurements["continuous-resize"])

        XCTAssertEqual(ct.status, .measured)
        XCTAssertEqual(ct.sampleCount, 2)
        XCTAssertEqual(ct.totalCPUTimeMilliseconds, 10.0, accuracy: 0.0001)
        XCTAssertEqual(ct.totalGPUTimeMilliseconds, 3.0)
        XCTAssertEqual(ct.peakMemoryBytes, 524_288)
        XCTAssertEqual(ct.stageMeasurements.map(\.stage), [.mprReslice, .textureUpload])
        XCTAssertEqual(ct.stageMeasurements.first { $0.stage == .textureUpload }?.sampleCount, 1)
        XCTAssertEqual(ct.stageMeasurements.first { $0.stage == .textureUpload }?.cpuTimeMilliseconds, 7.5)
        XCTAssertEqual(ct.stageMeasurements.first { $0.stage == .textureUpload }?.gpuTimeMilliseconds, 3.0)
        XCTAssertEqual(ct.stageMeasurements.first { $0.stage == .textureUpload }?.peakMemoryBytes, 524_288)
        XCTAssertEqual(ct.stageMeasurements.first { $0.stage == .mprReslice }?.cpuTimeMilliseconds, 2.5)
        XCTAssertEqual(ct.peakVolumeTextureCount, 1)
        XCTAssertEqual(ct.peakOutputTexturePoolSize, 1)
        XCTAssertEqual(ct.observedViewportTypes, ["mpr.axial", "volume3D"])
        XCTAssertEqual(ct.observedRenderModes, ["frontToBack", "single"])

        XCTAssertEqual(overlay.volumeLayerCount, 1)
        XCTAssertEqual(overlay.peakVolumeTextureCount, 2)
        XCTAssertEqual(surface.surfaceLayerCount, 1)
        XCTAssertEqual(resize.status, .notRun)

        let json = try report.jsonString()
        XCTAssertTrue(json.contains("Unit Test GPU"))
        XCTAssertTrue(json.contains("ci-scaled"))
        XCTAssertTrue(json.contains("ct-multi-viewport"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ClinicalBenchmarkReport.self, from: try report.jsonData())
        XCTAssertEqual(decoded, report)

        let csv = report.csvString()
        for header in ClinicalBenchmarkReport.csvHeaders {
            XCTAssertTrue(csv.contains(header), "Missing CSV header \(header)")
        }
        XCTAssertTrue(csv.contains("ct-multi-viewport"))
        XCTAssertTrue(csv.contains("volume-surface-segmentation"))
        XCTAssertTrue(csv.contains("Unit Test GPU"))
        XCTAssertTrue(csv.contains("one shared volume texture"))
        XCTAssertTrue(csv.contains("stageBreakdown"))
        XCTAssertTrue(csv.contains("textureUpload:samples=1"))
        XCTAssertTrue(csv.contains("ci-scaled"))
    }

    func testPerformanceBudgetManifestCoversClinicalRenderingStages() throws {
        let manifest = try loadPerformanceBudgetManifest()
        let stages = Set(manifest.scenarios.flatMap { scenario in
            scenario.budgets.map(\.stage)
        })
        let requiredStages: Set<String> = [
            "decode",
            "volumeAssembly",
            "gpuUpload",
            "mprRender",
            "volumeRender",
            "snapshot",
            "peakMemory"
        ]

        XCTAssertEqual(Set(manifest.requiredStages), requiredStages)
        XCTAssertTrue(stages.isSuperset(of: requiredStages))
        XCTAssertEqual(Set(manifest.buildConfigurations), ["debug", "release"])

        let mtkScenario = try XCTUnwrap(manifest.scenarios.first { $0.component == "MTK" })
        let mtkStages = Set(mtkScenario.budgets.map(\.stage))
        XCTAssertTrue(mtkStages.isSuperset(of: ["gpuUpload", "mprRender", "volumeRender", "snapshot", "peakMemory"]))
        XCTAssertEqual(mtkScenario.benchmarkMode, "clinical-render")
        XCTAssertTrue(mtkScenario.fixturePolicy.contains("local"))

        let environmentFields = Set(manifest.comparisonProfile.requiredResultEnvironmentFields)
        XCTAssertTrue(environmentFields.isSuperset(of: [
            "deviceName",
            "osVersion",
            "architecture",
            "modelIdentifier",
            "buildConfiguration",
            "benchmarkMode",
            "fixtureID"
        ]))
    }

    func testProfilingStagesMapToPerformanceBudgetStages() {
        let mapping: [ProfilingStage: String] = [
            .dicomParse: "decode",
            .huConversion: "volumeAssembly",
            .textureUpload: "gpuUpload",
            .mprReslice: "mprRender",
            .volumeRaycast: "volumeRender",
            .snapshotReadback: "snapshot",
            .memorySnapshot: "peakMemory"
        ]

        for stage in [
            ProfilingStage.dicomParse,
            .huConversion,
            .textureUpload,
            .mprReslice,
            .volumeRaycast,
            .snapshotReadback,
            .memorySnapshot
        ] {
            XCTAssertNotNil(mapping[stage], "Missing performance budget mapping for \(stage.rawValue)")
        }
    }

    private func makeEnvironment() -> ProfilingEnvironment {
        ProfilingEnvironment(
            deviceName: "Unit Test GPU",
            osVersion: "Unit Test OS",
            gpuFamily: "common3",
            maxThreadsPerThreadgroupDimensions: ProfilingThreadgroupDimensions(width: 1024, height: 1024, depth: 64),
            recommendedMaxWorkingSetSize: 8_589_934_592,
            appVersion: "1.0",
            buildNumber: "100"
        )
    }

    private func makeSample(scenarioID: String,
                            stage: ProfilingStage,
                            cpuTime: Double,
                            gpuTime: Double? = nil,
                            memory: Int? = nil,
                            viewportType: String,
                            renderMode: String,
                            metadata: [String: String] = [:]) -> ProfilingSample {
        var mergedMetadata = metadata
        mergedMetadata["scenarioID"] = scenarioID
        return ProfilingSample(
            timestamp: fixedDate(TimeInterval(mergedMetadata.count)),
            stageType: stage,
            cpuTimeMilliseconds: cpuTime,
            gpuTimeMilliseconds: gpuTime,
            memoryEstimateBytes: memory,
            viewportContext: ProfilingViewportContext(
                resolutionWidth: 512,
                resolutionHeight: 512,
                viewportType: viewportType,
                quality: "interactive",
                renderMode: renderMode
            ),
            metadata: mergedMetadata
        )
    }

    private func fixedDate(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + offset)
    }

    private func loadPerformanceBudgetManifest(callerFile: String = #filePath) throws -> TestPerformanceBudgetManifest {
        let root = try findRepositoryRoot(callerFile: callerFile)
        let url = root.appendingPathComponent("Roadmap/ClinicalPerformanceBudgetManifest.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(TestPerformanceBudgetManifest.self, from: data)
    }

    private func findRepositoryRoot(callerFile: String) throws -> URL {
        var directory = URL(fileURLWithPath: callerFile).deletingLastPathComponent()
        let fileManager = FileManager.default

        while directory.path != "/" {
            if fileManager.fileExists(atPath: directory.appendingPathComponent("ISSUE-ORDER.txt").path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }

        throw NSError(domain: "ClinicalBenchmarkReportTests",
                      code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not locate repository root"])
    }
}

private struct TestPerformanceBudgetManifest: Decodable {
    var requiredStages: [String]
    var buildConfigurations: [String]
    var comparisonProfile: TestPerformanceBudgetComparisonProfile
    var scenarios: [TestPerformanceBudgetScenario]
}

private struct TestPerformanceBudgetComparisonProfile: Decodable {
    var requiredResultEnvironmentFields: [String]
}

private struct TestPerformanceBudgetScenario: Decodable {
    var component: String
    var fixturePolicy: String
    var benchmarkMode: String
    var budgets: [TestPerformanceBudgetEntry]
}

private struct TestPerformanceBudgetEntry: Decodable {
    var stage: String
}
