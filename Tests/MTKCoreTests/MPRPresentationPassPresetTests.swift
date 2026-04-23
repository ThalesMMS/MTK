import Metal
import XCTest

@_spi(Testing) @testable import MTKCore

final class MPRPresentationPassPresetTests: XCTestCase {
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var library: MTLLibrary!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Failed to create command queue")
        }

        self.device = device
        self.commandQueue = commandQueue
        self.library = try ShaderLibraryLoader.loadLibrary(for: device)
    }

    func test_brainPresetWindowClampsAndNormalizesRamp() throws {
        try assertPresetWindow(WindowLevelPresetLibrary.brain,
                               expectedWindow: 80,
                               expectedLevel: 40)
    }

    func test_lungPresetWindowClampsAndNormalizesRamp() throws {
        try assertPresetWindow(WindowLevelPresetLibrary.lung,
                               expectedWindow: 1_500,
                               expectedLevel: -600)
    }

    func test_bonePresetWindowClampsAndNormalizesRamp() throws {
        try assertPresetWindow(WindowLevelPresetLibrary.bone,
                               expectedWindow: 2_500,
                               expectedLevel: 480)
    }

    func test_softTissuePresetWindowClampsAndNormalizesRamp() throws {
        try assertPresetWindow(WindowLevelPresetLibrary.softTissue,
                               expectedWindow: 400,
                               expectedLevel: 40)
    }

    func test_monochrome2MapsLowHUToDarkAndHighHUToBright() throws {
        let window: ClosedRange<Int32> = 0...100
        let values: [Int16] = [-50, 0, 50, 100, 150]
        let bytes = try presentGray(values: values, window: window, invert: false)

        XCTAssertEqual(bytes,
                       values.map { expectedGrayByte(value: Int32($0), window: window, invert: false) },
                       accuracy: 1)
        XCTAssertEqual(bytes.first, 0)
        XCTAssertEqual(bytes.last, 255)
    }

    func test_monochrome1MapsLowHUToBrightAndHighHUToDark() throws {
        let window: ClosedRange<Int32> = 0...100
        let values: [Int16] = [-50, 0, 50, 100, 150]
        let bytes = try presentGray(values: values, window: window, invert: true)

        XCTAssertEqual(bytes,
                       values.map { expectedGrayByte(value: Int32($0), window: window, invert: true) },
                       accuracy: 1)
        XCTAssertEqual(bytes.first, 255)
        XCTAssertEqual(bytes.last, 0)
    }

    func test_colormapSamplesBlackBlueRedGradient() throws {
        let values: [Int16] = [0, 50, 100]
        let colormap = try MPRTestHelpers.makeColormapTexture([
            SIMD4<Float>(0, 0, 0, 1),
            SIMD4<Float>(0, 0, 1, 1),
            SIMD4<Float>(1, 0, 0, 1)
        ], device: device)

        let bytes = try presentBGRA(values: values,
                                    width: values.count,
                                    height: 1,
                                    window: 0...100,
                                    colormap: colormap)

        XCTAssertEqual(bytes, [
            (0, 0, 0, 255),
            (255, 0, 0, 255),
            (0, 0, 255, 255)
        ], accuracy: 2)
    }

    func test_colormapDisabledPathProducesGrayscale() throws {
        let values: [Int16] = [0, 50, 100]
        let bytes = try presentBGRA(values: values,
                                    width: values.count,
                                    height: 1,
                                    window: 0...100)

        XCTAssertEqual(bytes, [
            (0, 0, 0, 255),
            (128, 128, 128, 255),
            (255, 255, 255, 255)
        ], accuracy: 1)
    }

    func test_colormapHonorsInvertBeforeLookup() throws {
        let values: [Int16] = [0, 100]
        let colormap = try MPRTestHelpers.makeColormapTexture([
            SIMD4<Float>(0, 0, 0, 1),
            SIMD4<Float>(1, 0, 0, 1)
        ], device: device)

        let bytes = try presentBGRA(values: values,
                                    width: values.count,
                                    height: 1,
                                    window: 0...100,
                                    invert: true,
                                    colormap: colormap)

        XCTAssertEqual(bytes, [
            (0, 0, 255, 255),
            (0, 0, 0, 255)
        ], accuracy: 2)
    }

    func test_flipHorizontalUsesRightmostInputForLeftmostOutput() throws {
        let values: [Int16] = [0, 50, 100]
        let bytes = try presentGray(values: values,
                                    width: 3,
                                    height: 1,
                                    window: 0...100,
                                    flipHorizontal: true)

        XCTAssertEqual(bytes, [255, 128, 0], accuracy: 1)
    }

    func test_flipVerticalUsesBottomInputForTopOutput() throws {
        let values: [Int16] = [
            0, 10,
            90, 100
        ]
        let bytes = try presentGray(values: values,
                                    width: 2,
                                    height: 2,
                                    window: 0...100,
                                    flipVertical: true)

        XCTAssertEqual(bytes, [230, 255, 0, 26], accuracy: 1)
    }

    func test_combinedFlipsRotateAsymmetricPatternByBothAxes() throws {
        let values: [Int16] = [
            0, 25,
            75, 100
        ]
        let bytes = try presentGray(values: values,
                                    width: 2,
                                    height: 2,
                                    window: 0...100,
                                    flipHorizontal: true,
                                    flipVertical: true)

        XCTAssertEqual(bytes, [255, 191, 64, 0], accuracy: 1)
    }

    func test_transformOverloadAppliesFoldedPresentationFlips() throws {
        let values: [Int16] = [
            0, 25,
            75, 100
        ]
        let bytes = try presentGray(values: values,
                                    width: 2,
                                    height: 2,
                                    window: 0...100,
                                    transform: MPRDisplayTransform(
                                        orientation: .rotated180,
                                        flipHorizontal: false,
                                        flipVertical: false,
                                        leadingLabel: .right,
                                        trailingLabel: .left,
                                        topLabel: .superior,
                                        bottomLabel: .inferior
                                    ))

        XCTAssertEqual(bytes, [255, 191, 64, 0], accuracy: 1)

        let flippedBytes = try presentGray(values: values,
                                           width: 2,
                                           height: 2,
                                           window: 0...100,
                                           transform: MPRDisplayTransform(
                                               orientation: .standard,
                                               flipHorizontal: true,
                                               flipVertical: false,
                                               leadingLabel: .right,
                                               trailingLabel: .left,
                                               topLabel: .superior,
                                               bottomLabel: .inferior
                                           ))

        XCTAssertEqual(flippedBytes, [64, 0, 255, 191], accuracy: 1)
    }

    private func assertPresetWindow(_ preset: WindowLevelPreset,
                                    expectedWindow: Double,
                                    expectedLevel: Double) throws {
        XCTAssertEqual(preset.window, expectedWindow)
        XCTAssertEqual(preset.level, expectedLevel)

        let window = preset.windowRange
        let midpoint = window.lowerBound + (window.upperBound - window.lowerBound) / 2
        let values = [
            window.lowerBound - 100,
            window.lowerBound,
            midpoint,
            window.upperBound,
            window.upperBound + 100
        ].map(Int16.init)

        let bytes = try presentGray(values: values,
                                    width: values.count,
                                    height: 1,
                                    preset: preset)

        XCTAssertEqual(bytes,
                       values.map { expectedGrayByte(value: Int32($0), window: window, invert: false) },
                       accuracy: 1)
        XCTAssertEqual(bytes[0], 0)
        XCTAssertEqual(bytes[1], 0)
        XCTAssertEqual(bytes[3], 255)
        XCTAssertEqual(bytes[4], 255)
    }

    private func presentGray(values: [Int16],
                             width: Int? = nil,
                             height: Int = 1,
                             window: ClosedRange<Int32>,
                             invert: Bool = false,
                             transform: MPRDisplayTransform? = nil,
                             flipHorizontal: Bool = false,
                             flipVertical: Bool = false) throws -> [UInt8] {
        let resolvedWidth = width ?? values.count
        let bytes = try presentBGRA(values: values,
                                    width: resolvedWidth,
                                    height: height,
                                    window: window,
                                    invert: invert,
                                    transform: transform,
                                    flipHorizontal: flipHorizontal,
                                    flipVertical: flipVertical)
        return bytes.map(\.0)
    }

    private func presentGray(values: [Int16],
                             width: Int? = nil,
                             height: Int = 1,
                             preset: WindowLevelPreset) throws -> [UInt8] {
        let resolvedWidth = width ?? values.count
        let bytes = try presentBGRA(values: values,
                                    width: resolvedWidth,
                                    height: height,
                                    preset: preset)
        return bytes.map(\.0)
    }

    private func presentBGRA(values: [Int16],
                             width: Int,
                             height: Int,
                             window: ClosedRange<Int32>,
                             invert: Bool = false,
                             colormap: (any MTLTexture)? = nil,
                             transform: MPRDisplayTransform? = nil,
                             flipHorizontal: Bool = false,
                             flipVertical: Bool = false) throws -> [(UInt8, UInt8, UInt8, UInt8)] {
        precondition(values.count == width * height)
        precondition(!values.isEmpty)
        let intensities = values.map(Int32.init)
        let minIntensity = intensities.min() ?? 0
        let maxIntensity = intensities.max() ?? 0
        let input = try MPRTestHelpers.makeSignedTexture(values, width: width, height: height, device: device)
        let drawable = try MPRTestMetalDrawable(device: device, width: width, height: height)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                              pixelFormat: .int16Signed,
                              intensityRange: minIntensity...maxIntensity)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        if let transform {
            try pass.present(frame: frame,
                             window: window,
                             to: drawable,
                             transform: transform,
                             invert: invert,
                             colormap: colormap)
        } else {
            try pass.present(frame: frame,
                             window: window,
                             to: drawable,
                             invert: invert,
                             colormap: colormap,
                             flipHorizontal: flipHorizontal,
                             flipVertical: flipVertical)
        }
        try MPRTestHelpers.waitForQueue(commandQueue)
        return try MPRTestHelpers.readBGRAPixels(from: drawable.texture)
    }

    private func presentBGRA(values: [Int16],
                             width: Int,
                             height: Int,
                             preset: WindowLevelPreset) throws -> [(UInt8, UInt8, UInt8, UInt8)] {
        precondition(values.count == width * height)
        precondition(!values.isEmpty)
        let intensities = values.map(Int32.init)
        let minIntensity = intensities.min() ?? 0
        let maxIntensity = intensities.max() ?? 0
        let input = try MPRTestHelpers.makeSignedTexture(values, width: width, height: height, device: device)
        let drawable = try MPRTestMetalDrawable(device: device, width: width, height: height)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                              pixelFormat: .int16Signed,
                              intensityRange: minIntensity...maxIntensity)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        try pass.present(frame: frame, preset: preset, to: drawable)
        try MPRTestHelpers.waitForQueue(commandQueue)
        return try MPRTestHelpers.readBGRAPixels(from: drawable.texture)
    }

    private func expectedGrayByte(value: Int32,
                                  window: ClosedRange<Int32>,
                                  invert: Bool) -> UInt8 {
        let lower = min(window.lowerBound, window.upperBound)
        let upper = max(window.lowerBound, window.upperBound)
        let span = max(Float(upper - lower), 1)
        var normalized = min(max((Float(value) - Float(lower)) / span, 0), 1)
        if invert {
            normalized = 1 - normalized
        }
        return UInt8((normalized * 255).rounded())
    }

}

private func XCTAssertEqual(_ actual: [(UInt8, UInt8, UInt8, UInt8)],
                            _ expected: [(UInt8, UInt8, UInt8, UInt8)],
                            accuracy: UInt8,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
    XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    for (index, pair) in zip(actual, expected).enumerated() {
        XCTAssertLessThanOrEqual(abs(Int(pair.0.0) - Int(pair.1.0)),
                                 Int(accuracy),
                                 "B mismatch at pixel \(index): \(actual) != \(expected)",
                                 file: file,
                                 line: line)
        XCTAssertLessThanOrEqual(abs(Int(pair.0.1) - Int(pair.1.1)),
                                 Int(accuracy),
                                 "G mismatch at pixel \(index): \(actual) != \(expected)",
                                 file: file,
                                 line: line)
        XCTAssertLessThanOrEqual(abs(Int(pair.0.2) - Int(pair.1.2)),
                                 Int(accuracy),
                                 "R mismatch at pixel \(index): \(actual) != \(expected)",
                                 file: file,
                                 line: line)
        XCTAssertLessThanOrEqual(abs(Int(pair.0.3) - Int(pair.1.3)),
                                 Int(accuracy),
                                 "A mismatch at pixel \(index): \(actual) != \(expected)",
                                 file: file,
                                 line: line)
    }
}
