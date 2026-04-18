import XCTest
import Metal
@_spi(Testing) @testable import MTKCore

/// Base test case that sets up a MetalMPRComputeAdapter and its Metal dependencies.
///
/// Subclass this instead of XCTestCase to get a ready-to-use `adapter` without
/// repeating the Metal device/queue/library bootstrapping in every MPR test class.
class MetalMPRComputeAdapterTestCase: XCTestCase {
    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var library: MTLLibrary!
    var adapter: MetalMPRComputeAdapter!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Failed to create command queue")
        }
        self.commandQueue = commandQueue

        let library = try ShaderLibraryLoader.loadLibrary(for: device)
        self.library = library

        let featureFlags = FeatureFlags.evaluate(for: device)
        let debugOptions = VolumeRenderingDebugOptions()
        self.adapter = MetalMPRComputeAdapter(
            device: device,
            commandQueue: commandQueue,
            library: library,
            featureFlags: featureFlags,
            debugOptions: debugOptions
        )
    }
}