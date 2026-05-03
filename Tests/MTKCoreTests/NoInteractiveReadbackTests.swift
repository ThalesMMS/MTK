import CoreGraphics
import Foundation
import Metal
import XCTest

@_spi(Testing) @testable import MTKCore

/*
 Non-removal audit note:
 Codebase exploration for the no-readback regression suite did not find legacy
 tests that required deletion. There are no tests validating a CGImage display
 path as part of the interactive renderer, no tests treating MPR readback as a
 normal presentation path, and no compatibility or legacy API tests preserving
 removed image-based rendering contracts. Keep this note in sync if future
 cleanup work reintroduces or removes such coverage.
 */

final class NoInteractiveReadbackTests: MTKRenderingEngineTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await engine.setProfilingOptions(.init(measureRenderTime: true))
        ClinicalProfiler.shared.reset()
    }

    override func tearDown() async throws {
        _ = ClinicalProfiler.shared.endSession()
        try await super.tearDown()
    }

    func test_volumeRenderingAdapterRenderFrame_doesNotTriggerReadback() async throws {
        let adapter = try MetalVolumeRenderingAdapter(device: try requireMetalDevice())
        try await adapter.send(.setWindow(min: testDataset.intensityRange.lowerBound,
                                          max: testDataset.intensityRange.upperBound))
        let frame = try await adapter.renderFrame(using: makeVolumeRenderRequest(dataset: testDataset,
                                                                                 viewportSize: CGSize(width: 48, height: 36)))

        XCTAssertEqual(frame.texture.textureType, .type2D)
        XCTAssertEqual(frame.texture.width, 48)
        XCTAssertEqual(frame.texture.height, 36)
        assertNoSnapshotReadback()
    }

    func test_engineRenderVolume3D_doesNotTriggerReadback() async throws {
        let viewportSize = CGSize(width: 40, height: 24)
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D, initialSize: viewportSize)
        )
        try await engine.setVolume(testDataset, for: viewport)

        let frame = try await engine.render(viewport)
        defer { frame.outputTextureLease?.release() }

        XCTAssertEqual(frame.texture.textureType, .type2D)
        XCTAssertEqual(frame.texture.width, 40)
        XCTAssertEqual(frame.texture.height, 24)
        XCTAssertNotNil(frame.outputTextureLease)
        assertNoSnapshotReadback()
    }

    func test_engineRenderMPRAxial_doesNotTriggerReadback() async throws {
        try await assertMPRRenderDoesNotTriggerReadback(axis: .axial)
    }

    func test_engineRenderMPRCoronal_doesNotTriggerReadback() async throws {
        try await assertMPRRenderDoesNotTriggerReadback(axis: .coronal)
    }

    func test_engineRenderMPRSagittal_doesNotTriggerReadback() async throws {
        try await assertMPRRenderDoesNotTriggerReadback(axis: .sagittal)
    }

    func test_mprSliceScroll_reslicesWithoutReadback() async throws {
        let viewport = try await makeMPRViewport(axis: .axial, size: CGSize(width: 32, height: 32))

        try await engine.configure(viewport, slicePosition: 0.5, window: nil)
        let first = try await engine.render(viewport)
        let firstGeometry = try XCTUnwrap(first.mprFrame?.planeGeometry)
        let firstResliceCount = stageCount(.mprReslice)

        try await engine.configure(viewport, slicePosition: 0.3, window: nil)
        let second = try await engine.render(viewport)
        let secondGeometry = try XCTUnwrap(second.mprFrame?.planeGeometry)

        try await engine.configure(viewport, slicePosition: 0.7, window: nil)
        let third = try await engine.render(viewport)
        let thirdGeometry = try XCTUnwrap(third.mprFrame?.planeGeometry)

        XCTAssertNotEqual(secondGeometry, firstGeometry)
        XCTAssertNotEqual(thirdGeometry, secondGeometry)
        XCTAssertGreaterThan(stageCount(.mprReslice), firstResliceCount)
        assertNoSnapshotReadback()
    }

    func test_mprWindowLevelAdjustment_reusesRawSliceWithoutReadback() async throws {
        let viewport = try await makeMPRViewport(axis: .axial, size: CGSize(width: 32, height: 32))

        try await engine.configure(viewport, slicePosition: 0.5, window: -500...600)
        let first = try await engine.render(viewport)
        let firstTextureID = ObjectIdentifier(first.texture as AnyObject)
        let firstResliceCount = stageCount(.mprReslice)

        try await engine.configure(viewport, slicePosition: 0.5, window: -250...250)
        let second = try await engine.render(viewport)

        XCTAssertEqual(ObjectIdentifier(second.texture as AnyObject), firstTextureID)
        XCTAssertEqual(stageCount(.mprReslice), firstResliceCount)
        assertNoSnapshotReadback()
    }

    func test_viewportResize_doesNotTriggerReadback() async throws {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D, initialSize: CGSize(width: 32, height: 32))
        )
        try await engine.setVolume(testDataset, for: viewport)

        let first = try await engine.render(viewport)
        defer { first.outputTextureLease?.release() }
        XCTAssertEqual(first.texture.width, 32)
        XCTAssertEqual(first.texture.height, 32)

        try await engine.resize(viewport, to: CGSize(width: 64, height: 48))
        let second = try await engine.render(viewport)
        defer { second.outputTextureLease?.release() }

        XCTAssertEqual(second.texture.width, 64)
        XCTAssertEqual(second.texture.height, 48)
        assertNoSnapshotReadback()
    }

    func test_presentationPass_doesNotTriggerReadback() async throws {
        let device = try requireMetalDevice()
        let commandQueue = try XCTUnwrap(device.makeCommandQueue())
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D, initialSize: CGSize(width: 32, height: 32))
        )
        try await engine.setVolume(testDataset, for: viewport)

        let frame = try await engine.render(viewport)
        let lease = try XCTUnwrap(frame.outputTextureLease)
        let drawable = try MPRTestMetalDrawable(device: device, width: 32, height: 32)

        _ = try PresentationPass().present(frame, to: drawable, commandQueue: commandQueue)
        try MPRTestHelpers.waitForQueue(commandQueue)
        try await waitUntilReleased(lease)

        XCTAssertGreaterThan(stageCount(.presentationPass), 0)
        assertNoSnapshotReadback()
    }

    func test_textureSnapshotExport_doesTriggerReadback() async throws {
        let adapter = try MetalVolumeRenderingAdapter(device: try requireMetalDevice())
        try await adapter.send(.setWindow(min: testDataset.intensityRange.lowerBound,
                                          max: testDataset.intensityRange.upperBound))
        let frame = try await adapter.renderFrame(using: makeVolumeRenderRequest(dataset: testDataset,
                                                                                 viewportSize: CGSize(width: 16, height: 16)))

        XCTAssertEqual(snapshotReadbackCount(), 0)

        let image = try await TextureSnapshotExporter().makeCGImage(from: frame)

        XCTAssertEqual(image.width, 16)
        XCTAssertEqual(image.height, 16)
        XCTAssertEqual(snapshotReadbackCount(), 1)
    }

    func test_getBytesRestrictedToAllowedFiles() throws {
        let allowedFiles: Set<String> = [
            "Sources/MTKCore/Adapters/TextureSnapshotExporter.swift",
            "Tests/MTKCoreTests/Support/MPRTestHelpers.swift",
            "Tests/MTKCoreTests/Support/MPRTextureReadbackHelper.swift"
        ]
        let productionSources = try scanProductionSources(in: "")
            .merging(try scanTestSources(in: "")) { current, _ in current }
        let getBytesPattern = try NSRegularExpression(pattern: #"(?<!["'])\bgetBytes\s*(?:\(|:)"#)

        let violations = productionSources.keys.sorted().filter { file in
            guard let source = productionSources[file] else { return false }
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            let containsGetBytes = getBytesPattern.firstMatch(in: source, range: range) != nil
            return containsGetBytes && !allowedFiles.contains(file)
        }

        XCTAssertEqual(
            violations,
            [],
            """
            Production readback must stay behind TextureSnapshotExporter. \
            Found forbidden getBytes usage in: \(violations.joined(separator: ", "))
            """
        )
    }

    func test_renderImageSymbolForbidden() throws {
        let productionSources = try scanProductionSources(in: "")
        let violations = productionSources.keys.sorted().filter { file in
            productionSources[file]?.contains("renderImage(") == true
        }

        XCTAssertEqual(violations, [], "Legacy renderImage API reintroduced in: \(violations.joined(separator: ", "))")
    }

    func test_volumeRenderResultTypeForbidden() throws {
        let productionSources = try scanProductionSources(in: "")
        let violations = productionSources.keys.sorted().filter { file in
            productionSources[file]?.contains("VolumeRenderResult") == true
        }

        XCTAssertEqual(violations, [],
                       "VolumeRenderResult must not reappear; use VolumeRenderFrame instead. Violations: \(violations.joined(separator: ", "))")
    }

    func test_cgImageDisplayPathForbidden() throws {
        let productionSources = try scanProductionSources(in: "")
        let allowedBoundaryTokens = ["snapshot", "export", "readback", "debug"]
        let patterns = [
            try NSRegularExpression(pattern: #"func\s+[A-Za-z0-9_]+\s*\([^)]*:\s*CGImage\??"#),
            try NSRegularExpression(pattern: #"(?:^|[^A-Za-z0-9_])display\s*\([^)]*CGImage"#),
            try NSRegularExpression(pattern: #"\.\s*display\s*\([^)]*CGImage"#)
        ]
        let violations = productionSources.keys.sorted().filter { file in
            guard let source = productionSources[file] else { return false }
            let normalizedFile = file.lowercased()
            if allowedBoundaryTokens.contains(where: normalizedFile.contains) {
                return false
            }
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for pattern in patterns {
                guard let match = pattern.firstMatch(in: source, range: range),
                      let matchRange = Range(match.range, in: source) else {
                    continue
                }
                let snippet = source[matchRange].lowercased()
                if allowedBoundaryTokens.contains(where: snippet.contains) {
                    continue
                }
                return true
            }
            return false
        }

        XCTAssertEqual(violations, [],
                       "CGImage display path must not reappear in production code. Violations: \(violations.joined(separator: ", "))")
    }

    func test_mtkuiDoesNotReferenceCGImagePresentationSymbols() throws {
        let productionSources = try scanProductionSources(in: "")

        let mtkuiFiles = productionSources.keys
            .filter { $0.hasPrefix("Sources/MTKUI/") }
            .sorted()

        let allowedBoundaryTokens = ["snapshot", "export", "readback", "debug"]
        let forbiddenTokens = [
            "UIImage",
            "NSImage",
            "CIImage",
            "Image(uiImage:",
            "Image(nsImage:"
        ]

        let violations = mtkuiFiles.filter { file in
            guard let source = productionSources[file] else { return false }

            let normalizedFile = file.lowercased()
            if allowedBoundaryTokens.contains(where: normalizedFile.contains) {
                return false
            }

            let containsForbiddenSymbol = forbiddenTokens.contains(where: source.contains)
            if containsForbiddenSymbol {
                return true
            }

            // `CGImage` references are allowed only behind explicit snapshot/export/readback/debug boundaries.
            if source.contains("CGImage") {
                return allowedBoundaryTokens.contains(where: source.lowercased().contains) == false
            }

            return false
        }

        XCTAssertEqual(
            violations,
            [],
            "MTKUI must not reference CGImage/UIImage/NSImage presentation symbols outside snapshot/export/readback/debug boundaries. Violations: \(violations.joined(separator: ", "))"
        )
    }
}

private extension NoInteractiveReadbackTests {
    func assertMPRRenderDoesNotTriggerReadback(axis: Axis) async throws {
        let viewport = try await makeMPRViewport(axis: axis, size: CGSize(width: 32, height: 28))
        let frame = try await engine.render(viewport)

        XCTAssertEqual(frame.texture.textureType, .type2D)
        XCTAssertEqual(frame.texture.width, 32)
        XCTAssertEqual(frame.texture.height, 28)
        XCTAssertNotNil(frame.mprFrame)
        XCTAssertNil(frame.outputTextureLease)
        assertNoSnapshotReadback()
    }

    func makeMPRViewport(axis: Axis, size: CGSize) async throws -> ViewportID {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .mpr(axis: axis), initialSize: size)
        )
        try await engine.setVolume(testDataset, for: viewport)
        return viewport
    }

    func makeVolumeRenderRequest(dataset: VolumeDataset,
                                 viewportSize: CGSize) -> VolumeRenderRequest {
        VolumeRenderRequest(
            dataset: dataset,
            transferFunction: defaultTransferFunction(for: dataset),
            viewportSize: viewportSize,
            camera: VolumeRenderRequest.Camera(
                position: SIMD3<Float>(0.5, 0.5, 2.0),
                target: SIMD3<Float>(repeating: 0.5),
                up: SIMD3<Float>(0, 1, 0),
                fieldOfView: 45
            ),
            samplingDistance: 1 / 256,
            compositing: .frontToBack,
            quality: .interactive
        )
    }

    func defaultTransferFunction(for dataset: VolumeDataset) -> VolumeTransferFunction {
        let lower = Float(dataset.intensityRange.lowerBound)
        let upper = Float(dataset.intensityRange.upperBound)
        return VolumeTransferFunction(
            opacityPoints: [
                .init(intensity: lower, opacity: 0),
                .init(intensity: upper, opacity: 1)
            ],
            colourPoints: [
                .init(intensity: lower, colour: SIMD4<Float>(0, 0, 0, 1)),
                .init(intensity: upper, colour: SIMD4<Float>(1, 1, 1, 1))
            ]
        )
    }

    func assertNoSnapshotReadback(file: StaticString = #filePath,
                                  line: UInt = #line) {
        XCTAssertEqual(snapshotReadbackCount(), 0,
                       "Interactive path recorded snapshotReadback.",
                       file: file,
                       line: line)
    }

    func snapshotReadbackCount() -> Int {
        stageCount(.snapshotReadback)
    }

    func stageCount(_ stage: ProfilingStage) -> Int {
        ClinicalProfiler.shared.sessionSnapshot()?.samples.filter { $0.stageType == stage }.count ?? 0
    }

    func requireMetalDevice() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        return device
    }

    func waitUntilReleased(_ lease: OutputTextureLease,
                           timeoutNanoseconds: UInt64 = 2_000_000_000) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !lease.isReleased {
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                XCTFail("Timed out waiting for lease release")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func sourceFilePath(_ relativePath: String) -> String {
        packageRootURL().appendingPathComponent(relativePath).path
    }

    func scanProductionSources(in directory: String) throws -> [String: String] {
        try scanSwiftSources(rootDirectory: "Sources", in: directory)
    }

    func scanTestSources(in directory: String) throws -> [String: String] {
        try scanSwiftSources(rootDirectory: "Tests", in: directory)
    }

    func scanSwiftSources(rootDirectory: String,
                          in directory: String) throws -> [String: String] {
        let fileManager = FileManager.default
        let relativeDirectory = directory.isEmpty ? rootDirectory : "\(rootDirectory)/\(directory)"
        let rootURL = URL(fileURLWithPath: sourceFilePath(relativeDirectory), isDirectory: true)
        guard let enumerator = fileManager.enumerator(at: rootURL,
                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else {
            throw NSError(
                domain: "NoInteractiveReadbackTests.ScanError",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to enumerate production sources for \(relativeDirectory) at \(rootURL.path)."
                ]
            )
        }

        var sources: [String: String] = [:]
        while let item = enumerator.nextObject() as? URL {
            guard item.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: item)
            let rootPath = packageRootURL().standardizedFileURL.path + "/"
            let itemPath = item.standardizedFileURL.path
            guard itemPath.hasPrefix(rootPath) else { continue }
            let relativePath = String(itemPath.dropFirst(rootPath.count))
            sources[relativePath] = source
        }
        return sources
    }
}
