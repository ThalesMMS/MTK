import XCTest
import Metal
@testable import MTKCore

final class MPRPresentationPassSourceTests: XCTestCase {
    func test_sourceDoesNotUseReadbackOrCGImage() throws {
        let source = try String(contentsOfFile: sourceFilePath("Sources/MTKCore/Rendering/MPRPresentationPass.swift"))

        assertSourceDoesNotUseReadbackOrCGImage(source)
    }

    func test_initialization_evaluatesAndStoresFeatureFlagsOnce() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        let evaluations = EvaluationCounter()
        let expected: FeatureFlags = [.adaptiveRendering, .mprMode]

        let pass = try MPRPresentationPass(
            device: device,
            commandQueue: commandQueue,
            featureFlagEvaluator: { _ in
                evaluations.count += 1
                return expected
            }
        )

        XCTAssertEqual(evaluations.count, 1)
        XCTAssertEqual(pass.featureFlagsForTesting, expected)
    }
}

private final class EvaluationCounter {
    var count = 0
}
