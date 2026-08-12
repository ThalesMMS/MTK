import Foundation
import Metal
import XCTest

@testable import MTKCore

final class MPRPresentationShadingPerformanceTests: XCTestCase {
    func test_enabledShadingStaysWithinInteractivePresentationBudget() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        let library = try ShaderLibraryLoader.loadLibrary(for: device)
        let width = 512
        let height = 512
        let values = (0..<(width * height)).map { UInt16(($0 * 17) % 4_096) }
        let input = try MPRTestHelpers.makeUnsignedTexture(values, width: width, height: height, device: device)
        let frame = MPRTestHelpers.makeFrame(
            texture: input,
            pixelFormat: .int16Unsigned,
            intensityRange: 0...4_095
        )
        var pass = try MPRPresentationPass(device: device, commandQueue: commandQueue, library: library)
        let settings = MPRShadingSettings(isEnabled: true, ambient: 0.35, diffuse: 0.55, specular: 0.10)

        _ = try pass.makeSnapshotTexture(
            frame: frame,
            window: 0...4_095,
            transform: .identity,
            width: width,
            height: height,
            shading: settings
        )

        let iterationCount = 10
        let startedAt = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterationCount {
            _ = try pass.makeSnapshotTexture(
                frame: frame,
                window: 0...4_095,
                transform: .identity,
                width: width,
                height: height,
                shading: settings
            )
        }
        let averageMilliseconds = (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000 / Double(iterationCount)
        let configuredBudget = ProcessInfo.processInfo.environment["MTK_MPR_SHADING_BUDGET_MS"]
            .flatMap(Double.init)
        let report = XCTAttachment(
            string: "MPR shading presentation: \(String(format: "%.3f", averageMilliseconds)) ms average " +
                "at \(width)x\(height)"
        )
        report.name = "MPR shading presentation timing"
        report.lifetime = .keepAlways
        add(report)

        if let configuredBudget {
            XCTAssertLessThan(averageMilliseconds, configuredBudget)
        }
    }
}
