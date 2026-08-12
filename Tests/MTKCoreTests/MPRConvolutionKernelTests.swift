import XCTest
@testable import MTKCore

final class MPRConvolutionKernelTests: XCTestCase {
    func test_presetsExposeDistinctNormalizedKernels() {
        XCTAssertEqual(MPRConvolutionKernel.identity.size, 1)
        XCTAssertEqual(MPRConvolutionKernel.identity.weights, [1])
        XCTAssertEqual(MPRConvolutionFilter.allCases, [.blur, .sharpen, .unsharpMask, .edge])

        let kernels = MPRConvolutionFilter.allCases.map(\.kernel)
        XCTAssertEqual(kernels.map(\.size), [3, 3, 5, 3])
        XCTAssertEqual(kernels.map(\.weights.count), [9, 9, 25, 9])
        let expectedUnsharpMask: [Float] = [
            -1.0 / 256,  -4.0 / 256,  -6.0 / 256,  -4.0 / 256, -1.0 / 256,
            -4.0 / 256, -16.0 / 256, -24.0 / 256, -16.0 / 256, -4.0 / 256,
            -6.0 / 256, -24.0 / 256, 476.0 / 256, -24.0 / 256, -6.0 / 256,
            -4.0 / 256, -16.0 / 256, -24.0 / 256, -16.0 / 256, -4.0 / 256,
            -1.0 / 256,  -4.0 / 256,  -6.0 / 256,  -4.0 / 256, -1.0 / 256
        ]
        XCTAssertEqual(MPRConvolutionKernel.unsharpMask.weights, expectedUnsharpMask)
        XCTAssertEqual(kernels[0].weights.reduce(0, +), 1, accuracy: 0.000_001)
        XCTAssertEqual(kernels[1].weights.reduce(0, +), 1, accuracy: 0.000_001)
        XCTAssertEqual(kernels[2].weights.reduce(0, +), 1, accuracy: 0.000_001)
        XCTAssertEqual(kernels[3].weights.reduce(0, +), 0, accuracy: 0.000_001)
        XCTAssertEqual(Set(kernels).count, kernels.count)
    }
}
