import Foundation
import Metal
import XCTest

@testable import MTKCore

final class ClinicalProfilerGoldenExportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        clearSharedProfilerSession()
    }

    override func tearDown() {
        clearSharedProfilerSession()
        super.tearDown()
    }

    func testGoldenJSONExportMatchesFixture() throws {
        let session = makeClinicalSession()
        let json = try session.jsonString()

        XCTAssertEqual(json, Self.goldenJSONOutput)
        XCTAssertFalse(json.contains("snapshotReadback"))
        XCTAssertFalse(json.contains("SceneKit"))
    }

    func testJSONExportRoundTripsAllFields() throws {
        let session = makeClinicalSession()
        let data = try session.jsonData()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(ProfilingSession.self, from: data)

        XCTAssertEqual(decoded.sessionID, session.sessionID)
        XCTAssertEqual(decoded.startTimestamp, session.startTimestamp)
        XCTAssertEqual(decoded.endTimestamp, session.endTimestamp)
        XCTAssertEqual(decoded.environment, session.environment)
        XCTAssertEqual(decoded.samples.count, session.samples.count)

        for (decodedSample, expectedSample) in zip(decoded.samples, session.samples) {
            XCTAssertEqual(decodedSample, expectedSample)
        }
    }

    func testGoldenCSVExportMatchesFixture() {
        let session = makeClinicalSession()
        let csv = ProfilingCSVExporter().export(session: session)

        XCTAssertEqual(csv, Self.goldenCSVOutput)
        XCTAssertFalse(csv.contains("snapshotReadback"))
        XCTAssertFalse(csv.contains("SceneKit"))
    }

    func testCSVExportContainsAllExpectedHeaders() throws {
        let session = makeClinicalSession()
        let csv = session.csvString()
        let headerLine = try XCTUnwrap(csv.split(separator: "\n", omittingEmptySubsequences: false).first)
        let headers = headerLine.split(separator: ",").map(String.init)

        XCTAssertEqual(headers, ProfilingSession.csvHeaders)
        for header in [
            "timestamp",
            "stage",
            "cpuTimeMs",
            "gpuTimeMs",
            "memoryBytes",
            "resolution",
            "viewportType",
            "quality",
            "renderMode",
            "deviceName",
            "osVersion",
            "gpuFamily",
            "maxThreadsPerThreadgroupWidth",
            "maxThreadsPerThreadgroupHeight",
            "maxThreadsPerThreadgroupDepth",
            "recommendedMaxWorkingSetSize",
            "appVersion",
            "buildNumber"
        ] {
            XCTAssertTrue(headers.contains(header), "Missing CSV header \(header)")
        }
    }

    func testEnvironmentContainsAllRequiredFields() throws {
        let session = makeClinicalSession()
        let environment = session.environment
        let json = try session.jsonString()
        let csv = session.csvString()

        XCTAssertFalse(environment.deviceName.isEmpty)
        XCTAssertFalse(environment.osVersion.isEmpty)
        XCTAssertFalse(environment.gpuFamily.isEmpty)
        XCTAssertFalse(environment.appVersion.isEmpty)
        XCTAssertFalse(environment.buildNumber.isEmpty)
        XCTAssertGreaterThan(environment.maxThreadsPerThreadgroupDimensions.width, 0)
        XCTAssertGreaterThan(environment.maxThreadsPerThreadgroupDimensions.height, 0)
        XCTAssertGreaterThan(environment.maxThreadsPerThreadgroupDimensions.depth, 0)
        XCTAssertGreaterThan(environment.recommendedMaxWorkingSetSize, 0)

        XCTAssertTrue(json.contains(environment.deviceName))
        XCTAssertTrue(json.contains(environment.osVersion))
        XCTAssertTrue(json.contains(environment.gpuFamily))
        XCTAssertTrue(json.contains(environment.appVersion))
        XCTAssertTrue(json.contains(environment.buildNumber))
        XCTAssertTrue(json.contains(String(environment.maxThreadsPerThreadgroupDimensions.width)))
        XCTAssertTrue(json.contains(String(environment.maxThreadsPerThreadgroupDimensions.height)))
        XCTAssertTrue(json.contains(String(environment.maxThreadsPerThreadgroupDimensions.depth)))
        XCTAssertTrue(json.contains(String(environment.recommendedMaxWorkingSetSize)))

        XCTAssertTrue(csv.contains(environment.deviceName))
        XCTAssertTrue(csv.contains(environment.osVersion))
        XCTAssertTrue(csv.contains(environment.gpuFamily))
        XCTAssertTrue(csv.contains(environment.appVersion))
        XCTAssertTrue(csv.contains(environment.buildNumber))
        XCTAssertTrue(csv.contains(String(environment.maxThreadsPerThreadgroupDimensions.width)))
        XCTAssertTrue(csv.contains(String(environment.maxThreadsPerThreadgroupDimensions.height)))
        XCTAssertTrue(csv.contains(String(environment.maxThreadsPerThreadgroupDimensions.depth)))
        XCTAssertTrue(csv.contains(String(environment.recommendedMaxWorkingSetSize)))
    }

    func testViewportContextContainsAllRequiredFields() throws {
        let session = makeClinicalSession()
        let csv = session.csvString()
        let rows = csv.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        let resolutionPattern = try NSRegularExpression(pattern: #"^\d+x\d+$"#)

        XCTAssertEqual(rows.count, session.samples.count)

        for sample in session.samples {
            let viewport = sample.viewportContext
            XCTAssertGreaterThan(viewport.resolutionWidth, 0)
            XCTAssertGreaterThan(viewport.resolutionHeight, 0)
            XCTAssertFalse(viewport.viewportType.isEmpty)
            XCTAssertFalse(viewport.quality.isEmpty)
            XCTAssertFalse(viewport.renderMode.isEmpty)
        }

        for row in rows {
            let columns = row.split(separator: ",", omittingEmptySubsequences: false)
            XCTAssertGreaterThanOrEqual(columns.count, 6)

            let resolution = String(columns[5])
            let range = NSRange(location: 0, length: resolution.utf16.count)
            XCTAssertNotNil(
                resolutionPattern.firstMatch(in: resolution, range: range),
                "Resolution column must be in WxH format, got \(resolution)"
            )
        }
    }

    func testInteractiveSessionDoesNotContainSnapshotReadback() throws {
        let session = makeInteractiveSession()
        let snapshotReadbacks = session.samples.filter { $0.stageType == .snapshotReadback }

        XCTAssertEqual(snapshotReadbacks, [])
        XCTAssertFalse(try session.jsonString().contains("snapshotReadback"))
        XCTAssertFalse(session.csvString().contains("snapshotReadback"))
    }

    func testExplicitSnapshotSessionContainsSnapshotReadback() throws {
        let session = try makeExplicitSnapshotSession()
        let stages = Set(session.samples.map(\.stageType))
        let readbacks = session.samples.filter { $0.stageType == .snapshotReadback }
        let sample = try XCTUnwrap(readbacks.only)

        XCTAssertEqual(readbacks.count, 1)
        XCTAssertGreaterThan(sample.memoryEstimateBytes ?? 0, 0)
        XCTAssertGreaterThan(sample.viewportContext.resolutionWidth, 0)
        XCTAssertGreaterThan(sample.viewportContext.resolutionHeight, 0)
        XCTAssertFalse(sample.metadata?["pixelFormat"]?.isEmpty ?? true)
        XCTAssertTrue(stages.contains(.presentationPass))
        XCTAssertTrue(stages.contains(.volumeRaycast))
        XCTAssertTrue(stages.contains(.mprReslice))
    }

    func testMemorySnapshotContainsResourceBreakdown() throws {
        let session = makeClinicalSession()
        let sample = try XCTUnwrap(session.samples.first { $0.stageType == .memorySnapshot })
        let metadata = try XCTUnwrap(sample.metadata)
        let volumeTextureBytes = try XCTUnwrap(Int(metadata["volumeTextureBytes"] ?? ""))
        let transferTextureBytes = try XCTUnwrap(Int(metadata["transferTextureBytes"] ?? ""))
        let outputTextureBytes = try XCTUnwrap(Int(metadata["outputTextureBytes"] ?? ""))
        let totalBytes = volumeTextureBytes + transferTextureBytes + outputTextureBytes

        XCTAssertEqual(sample.memoryEstimateBytes, totalBytes)
        XCTAssertNotNil(metadata["volumeTextureBytes"])
        XCTAssertNotNil(metadata["transferTextureBytes"])
        XCTAssertNotNil(metadata["outputTextureBytes"])
        XCTAssertNotNil(metadata["volumeTextureCount"])
        XCTAssertNotNil(metadata["transferTextureCount"])
        XCTAssertNotNil(metadata["outputTexturePoolSize"])
    }

    func testNoSceneKitReferencesInFixtures() {
        let session = makeClinicalSession()
        let forbiddenTerms = ["SceneKit", "scenekit", "scene kit"]

        for term in forbiddenTerms {
            XCTAssertFalse(Self.goldenJSONOutput.localizedCaseInsensitiveContains(term))
            XCTAssertFalse(Self.goldenCSVOutput.localizedCaseInsensitiveContains(term))
        }

        for sample in session.samples {
            for (key, value) in sample.metadata ?? [:] {
                for term in forbiddenTerms {
                    XCTAssertFalse(key.localizedCaseInsensitiveContains(term))
                    XCTAssertFalse(value.localizedCaseInsensitiveContains(term))
                }
            }
        }
    }

    func testExplicitSnapshotSessionRecordsExpectedSnapshotReadbackMetadata() throws {
        let session = try makeExplicitSnapshotSession()
        let readbacks = session.samples.filter { $0.stageType == .snapshotReadback }
        let sample = try XCTUnwrap(readbacks.only)

        XCTAssertEqual(readbacks.count, 1)
        XCTAssertEqual(sample.memoryEstimateBytes, 8 * 4 * 4)
        XCTAssertEqual(sample.viewportContext.resolutionWidth, 8)
        XCTAssertEqual(sample.viewportContext.resolutionHeight, 4)
        XCTAssertEqual(sample.metadata?["byteCount"], "128")
        XCTAssertEqual(sample.metadata?["pixelFormat"], "bgra8Unorm")
        XCTAssertEqual(sample.metadata?["width"], "8")
        XCTAssertEqual(sample.metadata?["height"], "4")
    }

    @MainActor
    func testMemorySnapshotFromVolumeResourceManagerIncludesBreakdown() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable on this test runner")
        }

        let manager = VolumeResourceManager(device: device, commandQueue: commandQueue)
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 4, height: 4, depth: 4),
            pixelFormat: .int16Signed
        )

        _ = try await manager.acquire(dataset: dataset, device: device, commandQueue: commandQueue)
        _ = try XCTUnwrap(manager.transferTexture(for: .ctBone, device: device))
        _ = try manager.acquireOutputTexture(width: 16, height: 8, pixelFormat: .bgra8Unorm)

        let expectedBreakdown = manager.memoryBreakdown()

        ClinicalProfiler.shared.reset(environment: makeTestEnvironment())
        ClinicalProfiler.shared.recordMemorySnapshot(from: manager, viewport: makeTestViewportContext())

        let session = try XCTUnwrap(ClinicalProfiler.shared.sessionSnapshot())
        let sample = try XCTUnwrap(session.samples.last)

        XCTAssertEqual(sample.stageType, .memorySnapshot)
        XCTAssertEqual(sample.memoryEstimateBytes, expectedBreakdown.total)
        XCTAssertEqual(sample.metadata?["volumeTextureBytes"], String(expectedBreakdown.volumeTextures))
        XCTAssertEqual(sample.metadata?["transferTextureBytes"], String(expectedBreakdown.transferTextures))
        XCTAssertEqual(sample.metadata?["outputTextureBytes"], String(expectedBreakdown.outputTextures))
        XCTAssertEqual(sample.metadata?["totalBytes"], String(expectedBreakdown.total))
    }

    private func makeClinicalSession() -> ProfilingSession {
        let environment = makeTestEnvironment()
        let volumeViewport = makeTestViewportContext()
        let mprViewport = ProfilingViewportContext(
            resolutionWidth: 512,
            resolutionHeight: 512,
            viewportType: "mpr.axial",
            quality: "interactive",
            renderMode: "single"
        )

        return ProfilingSession(
            sessionID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            startTimestamp: fixedDate(0),
            endTimestamp: fixedDate(12),
            environment: environment,
            samples: [
                ProfilingSample(
                    timestamp: fixedDate(1),
                    stageType: .textureUpload,
                    cpuTimeMilliseconds: 14.125,
                    gpuTimeMilliseconds: 8.25,
                    memoryEstimateBytes: 268_435_456,
                    viewportContext: volumeViewport
                ),
                ProfilingSample(
                    timestamp: fixedDate(2),
                    stageType: .texturePreparation,
                    cpuTimeMilliseconds: 6.5,
                    gpuTimeMilliseconds: 2.125,
                    memoryEstimateBytes: 268_500_992,
                    viewportContext: volumeViewport
                ),
                ProfilingSample(
                    timestamp: fixedDate(3),
                    stageType: .volumeRaycast,
                    cpuTimeMilliseconds: 12.375,
                    gpuTimeMilliseconds: 9.875,
                    viewportContext: volumeViewport
                ),
                ProfilingSample(
                    timestamp: fixedDate(4),
                    stageType: .mprReslice,
                    cpuTimeMilliseconds: 4.625,
                    gpuTimeMilliseconds: 3.5,
                    memoryEstimateBytes: 16_777_216,
                    viewportContext: mprViewport
                ),
                ProfilingSample(
                    timestamp: fixedDate(5),
                    stageType: .presentationPass,
                    cpuTimeMilliseconds: 1.75,
                    gpuTimeMilliseconds: 0.95,
                    memoryEstimateBytes: 16_777_216,
                    viewportContext: volumeViewport
                ),
                ProfilingSample(
                    timestamp: fixedDate(6),
                    stageType: .memorySnapshot,
                    cpuTimeMilliseconds: 0,
                    memoryEstimateBytes: 285_278_208,
                    viewportContext: volumeViewport,
                    metadata: [
                        "outputTextureBytes": "16777216",
                        "outputTexturePoolSize": "2",
                        "totalBytes": "285278208",
                        "transferTextureBytes": "65536",
                        "transferTextureCount": "1",
                        "volumeTextureBytes": "268435456",
                        "volumeTextureCount": "1"
                    ]
                )
            ]
        )
    }

    private func makeInteractiveSession() -> ProfilingSession {
        let viewport = makeTestViewportContext()
        return ProfilingSession(
            sessionID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            startTimestamp: fixedDate(20),
            endTimestamp: fixedDate(24),
            environment: makeTestEnvironment(),
            samples: [
                ProfilingSample(
                    timestamp: fixedDate(21),
                    stageType: .texturePreparation,
                    cpuTimeMilliseconds: 5.0,
                    gpuTimeMilliseconds: 1.5,
                    memoryEstimateBytes: 268_500_992,
                    viewportContext: viewport
                ),
                ProfilingSample(
                    timestamp: fixedDate(22),
                    stageType: .volumeRaycast,
                    cpuTimeMilliseconds: 11.25,
                    gpuTimeMilliseconds: 8.5,
                    viewportContext: viewport
                ),
                ProfilingSample(
                    timestamp: fixedDate(23),
                    stageType: .presentationPass,
                    cpuTimeMilliseconds: 1.2,
                    gpuTimeMilliseconds: 0.8,
                    memoryEstimateBytes: 16_777_216,
                    viewportContext: viewport
                )
            ]
        )
    }

    private func makeExplicitSnapshotSession() throws -> ProfilingSession {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        let texture = try makeSnapshotTexture(device: device, width: 8, height: 4)
        let frame = VolumeRenderFrame(
            texture: texture,
            metadata: VolumeRenderFrame.Metadata(
                viewportSize: .init(width: 8, height: 4),
                samplingDistance: 1 / 256,
                compositing: .frontToBack,
                quality: .production,
                pixelFormat: .bgra8Unorm
            )
        )

        ClinicalProfiler.shared.reset(environment: makeTestEnvironment())
        _ = try TextureSnapshotExporter().makeCGImageSynchronously(from: frame)

        var session = try XCTUnwrap(ClinicalProfiler.shared.sessionSnapshot())
        session.samples.insert(
            ProfilingSample(
                timestamp: fixedDate(30),
                stageType: .volumeRaycast,
                cpuTimeMilliseconds: 10.5,
                gpuTimeMilliseconds: 8.0,
                viewportContext: makeTestViewportContext()
            ),
            at: 0
        )
        session.samples.insert(
            ProfilingSample(
                timestamp: fixedDate(31),
                stageType: .mprReslice,
                cpuTimeMilliseconds: 4.0,
                gpuTimeMilliseconds: 3.25,
                viewportContext: ProfilingViewportContext(
                    resolutionWidth: 512,
                    resolutionHeight: 512,
                    viewportType: "mpr.axial",
                    quality: "interactive",
                    renderMode: "single"
                )
            ),
            at: 1
        )
        session.samples.insert(
            ProfilingSample(
                timestamp: fixedDate(32),
                stageType: .presentationPass,
                cpuTimeMilliseconds: 1.0,
                gpuTimeMilliseconds: 0.6,
                memoryEstimateBytes: 128,
                viewportContext: makeTestViewportContext()
            ),
            at: 2
        )
        return session
    }

    private func makeTestEnvironment() -> ProfilingEnvironment {
        ProfilingEnvironment(
            deviceName: "Clinical Test GPU",
            osVersion: "iOS 17.4",
            gpuFamily: "apple9",
            maxThreadsPerThreadgroupDimensions: ProfilingThreadgroupDimensions(width: 1024, height: 1024, depth: 64),
            recommendedMaxWorkingSetSize: 8_589_934_592,
            appVersion: "5.4.3",
            buildNumber: "5430"
        )
    }

    private func makeTestViewportContext() -> ProfilingViewportContext {
        ProfilingViewportContext(
            resolutionWidth: 1024,
            resolutionHeight: 768,
            viewportType: "volume3D",
            quality: "interactive",
            renderMode: "frontToBack"
        )
    }

    private func fixedDate(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + offset)
    }

    private func clearSharedProfilerSession() {
        if ClinicalProfiler.shared.sessionSnapshot() != nil {
            _ = ClinicalProfiler.shared.endSession()
        }
    }

    private func makeSnapshotTexture(device: any MTLDevice,
                                     width: Int,
                                     height: Int) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("Unable to allocate snapshot test texture")
        }

        let bytesPerRow = width * 4
        let pixelBytes = [UInt8](repeating: 0x7F, count: bytesPerRow * height)
        pixelBytes.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0,
                            withBytes: bytes.baseAddress!,
                            bytesPerRow: bytesPerRow)
        }
        return texture
    }

    private static let goldenCSVOutput = #"""
timestamp,stage,cpuTimeMs,gpuTimeMs,memoryBytes,resolution,viewportType,quality,renderMode,deviceName,osVersion,gpuFamily,maxThreadsPerThreadgroupWidth,maxThreadsPerThreadgroupHeight,maxThreadsPerThreadgroupDepth,recommendedMaxWorkingSetSize,appVersion,buildNumber,metadata
2027-01-15T08:00:01Z,textureUpload,14.125000,8.250000,268435456,1024x768,volume3D,interactive,frontToBack,Clinical Test GPU,iOS 17.4,apple9,1024,1024,64,8589934592,5.4.3,5430,
2027-01-15T08:00:02Z,texturePreparation,6.500000,2.125000,268500992,1024x768,volume3D,interactive,frontToBack,Clinical Test GPU,iOS 17.4,apple9,1024,1024,64,8589934592,5.4.3,5430,
2027-01-15T08:00:03Z,volumeRaycast,12.375000,9.875000,,1024x768,volume3D,interactive,frontToBack,Clinical Test GPU,iOS 17.4,apple9,1024,1024,64,8589934592,5.4.3,5430,
2027-01-15T08:00:04Z,mprReslice,4.625000,3.500000,16777216,512x512,mpr.axial,interactive,single,Clinical Test GPU,iOS 17.4,apple9,1024,1024,64,8589934592,5.4.3,5430,
2027-01-15T08:00:05Z,presentationPass,1.750000,0.950000,16777216,1024x768,volume3D,interactive,frontToBack,Clinical Test GPU,iOS 17.4,apple9,1024,1024,64,8589934592,5.4.3,5430,
2027-01-15T08:00:06Z,memorySnapshot,0.000000,,285278208,1024x768,volume3D,interactive,frontToBack,Clinical Test GPU,iOS 17.4,apple9,1024,1024,64,8589934592,5.4.3,5430,"{""outputTextureBytes"":""16777216"",""outputTexturePoolSize"":""2"",""totalBytes"":""285278208"",""transferTextureBytes"":""65536"",""transferTextureCount"":""1"",""volumeTextureBytes"":""268435456"",""volumeTextureCount"":""1""}"
"""#

    private static let goldenJSONOutput = #"""
{
  "endTimestamp" : "2027-01-15T08:00:12Z",
  "environment" : {
    "appVersion" : "5.4.3",
    "buildNumber" : "5430",
    "deviceName" : "Clinical Test GPU",
    "gpuFamily" : "apple9",
    "maxThreadsPerThreadgroupDimensions" : {
      "depth" : 64,
      "height" : 1024,
      "width" : 1024
    },
    "osVersion" : "iOS 17.4",
    "recommendedMaxWorkingSetSize" : 8589934592
  },
  "samples" : [
    {
      "cpuTimeMilliseconds" : 14.125,
      "gpuTimeMilliseconds" : 8.25,
      "memoryEstimateBytes" : 268435456,
      "stageType" : "textureUpload",
      "timestamp" : "2027-01-15T08:00:01Z",
      "viewportContext" : {
        "quality" : "interactive",
        "renderMode" : "frontToBack",
        "resolutionHeight" : 768,
        "resolutionWidth" : 1024,
        "viewportType" : "volume3D"
      }
    },
    {
      "cpuTimeMilliseconds" : 6.5,
      "gpuTimeMilliseconds" : 2.125,
      "memoryEstimateBytes" : 268500992,
      "stageType" : "texturePreparation",
      "timestamp" : "2027-01-15T08:00:02Z",
      "viewportContext" : {
        "quality" : "interactive",
        "renderMode" : "frontToBack",
        "resolutionHeight" : 768,
        "resolutionWidth" : 1024,
        "viewportType" : "volume3D"
      }
    },
    {
      "cpuTimeMilliseconds" : 12.375,
      "gpuTimeMilliseconds" : 9.875,
      "stageType" : "volumeRaycast",
      "timestamp" : "2027-01-15T08:00:03Z",
      "viewportContext" : {
        "quality" : "interactive",
        "renderMode" : "frontToBack",
        "resolutionHeight" : 768,
        "resolutionWidth" : 1024,
        "viewportType" : "volume3D"
      }
    },
    {
      "cpuTimeMilliseconds" : 4.625,
      "gpuTimeMilliseconds" : 3.5,
      "memoryEstimateBytes" : 16777216,
      "stageType" : "mprReslice",
      "timestamp" : "2027-01-15T08:00:04Z",
      "viewportContext" : {
        "quality" : "interactive",
        "renderMode" : "single",
        "resolutionHeight" : 512,
        "resolutionWidth" : 512,
        "viewportType" : "mpr.axial"
      }
    },
    {
      "cpuTimeMilliseconds" : 1.75,
      "gpuTimeMilliseconds" : 0.95,
      "memoryEstimateBytes" : 16777216,
      "stageType" : "presentationPass",
      "timestamp" : "2027-01-15T08:00:05Z",
      "viewportContext" : {
        "quality" : "interactive",
        "renderMode" : "frontToBack",
        "resolutionHeight" : 768,
        "resolutionWidth" : 1024,
        "viewportType" : "volume3D"
      }
    },
    {
      "cpuTimeMilliseconds" : 0,
      "memoryEstimateBytes" : 285278208,
      "metadata" : {
        "outputTextureBytes" : "16777216",
        "outputTexturePoolSize" : "2",
        "totalBytes" : "285278208",
        "transferTextureBytes" : "65536",
        "transferTextureCount" : "1",
        "volumeTextureBytes" : "268435456",
        "volumeTextureCount" : "1"
      },
      "stageType" : "memorySnapshot",
      "timestamp" : "2027-01-15T08:00:06Z",
      "viewportContext" : {
        "quality" : "interactive",
        "renderMode" : "frontToBack",
        "resolutionHeight" : 768,
        "resolutionWidth" : 1024,
        "viewportType" : "volume3D"
      }
    }
  ],
  "sessionID" : "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
  "startTimestamp" : "2027-01-15T08:00:00Z"
}
"""#
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
