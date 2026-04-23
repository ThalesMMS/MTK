import Metal
import XCTest

func makeTestMetalDevice() throws -> any MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw XCTSkip("Metal device unavailable on this test runner")
    }
    return device
}
