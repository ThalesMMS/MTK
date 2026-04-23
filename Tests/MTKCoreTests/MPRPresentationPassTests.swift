import Metal
import XCTest

@_spi(Testing) @testable import MTKCore

final class MPRPresentationPassTests: XCTestCase {
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

    func test_signedInputAppliesFullWindow() throws {
        let values: [Int16] = [-100, 0, 100, 200]
        let input = try MPRTestHelpers.makeSignedTexture(values, width: 2, height: 2, device: device)
        let drawable = try MPRTestMetalDrawable(device: device, width: 2, height: 2)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                              pixelFormat: .int16Signed,
                              intensityRange: -100...200)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        try pass.present(frame: frame, window: -100...200, to: drawable)
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(try MPRTestHelpers.readGrayBytes(from: drawable.texture), [0, 85, 170, 255], accuracy: 1)
    }

    func test_unsignedInputAppliesFullWindow() throws {
        let values: [UInt16] = [0, 1_000, 2_000, 4_000]
        let input = try MPRTestHelpers.makeUnsignedTexture(values, width: 2, height: 2, device: device)
        let drawable = try MPRTestMetalDrawable(device: device, width: 2, height: 2)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                              pixelFormat: .int16Unsigned,
                              intensityRange: 0...4_000)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        try pass.present(frame: frame, window: 0...4_000, to: drawable)
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(try MPRTestHelpers.readGrayBytes(from: drawable.texture), [0, 64, 128, 255], accuracy: 1)
    }

    func test_narrowWindowClampsOutput() throws {
        let values: [Int16] = [9, 10, 11, 12]
        let input = try MPRTestHelpers.makeSignedTexture(values, width: 2, height: 2, device: device)
        let drawable = try MPRTestMetalDrawable(device: device, width: 2, height: 2)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                              pixelFormat: .int16Signed,
                              intensityRange: 9...12)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        try pass.present(frame: frame, window: 10...11, to: drawable)
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(try MPRTestHelpers.readGrayBytes(from: drawable.texture), [0, 0, 255, 255], accuracy: 1)
    }

    func test_degenerateWindowRangeUsesMinimumSpan() throws {
        let values: [Int16] = [99, 100, 101, 102]
        let input = try MPRTestHelpers.makeSignedTexture(values, width: 2, height: 2, device: device)
        let drawable = try MPRTestMetalDrawable(device: device, width: 2, height: 2)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                              pixelFormat: .int16Signed,
                              intensityRange: 99...102)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        try pass.present(frame: frame, window: 100...100, to: drawable)
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(try MPRTestHelpers.readGrayBytes(from: drawable.texture), [0, 0, 255, 255], accuracy: 1)
    }

    func test_invertFlagFlipsWindowOutput() throws {
        let values: [UInt16] = [0, 500, 1_000, 2_000]
        let input = try MPRTestHelpers.makeUnsignedTexture(values, width: 2, height: 2, device: device)
        let drawable = try MPRTestMetalDrawable(device: device, width: 2, height: 2)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                              pixelFormat: .int16Unsigned,
                              intensityRange: 0...2_000)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        try pass.present(frame: frame, window: 0...2_000, to: drawable, invert: true)
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(try MPRTestHelpers.readGrayBytes(from: drawable.texture), [255, 191, 128, 0], accuracy: 1)
    }

    func test_monochromePolarityMapsToInvertFlag() throws {
        let values: [Int16] = [0, 100]
        let input = try MPRTestHelpers.makeSignedTexture(values, width: 2, height: 1, device: device)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                              pixelFormat: .int16Signed,
                              intensityRange: 0...100)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        let monochrome2Drawable = try MPRTestMetalDrawable(device: device, width: 2, height: 1)
        try pass.present(frame: frame, window: 0...100, to: monochrome2Drawable)
        try MPRTestHelpers.waitForQueue(commandQueue)
        XCTAssertEqual(try MPRTestHelpers.readGrayBytes(from: monochrome2Drawable.texture), [0, 255], accuracy: 1)

        let monochrome1Drawable = try MPRTestMetalDrawable(device: device, width: 2, height: 1)
        try pass.present(frame: frame, window: 0...100, to: monochrome1Drawable, invert: true)
        try MPRTestHelpers.waitForQueue(commandQueue)
        XCTAssertEqual(try MPRTestHelpers.readGrayBytes(from: monochrome1Drawable.texture), [255, 0], accuracy: 1)
    }

    func test_ctPresetConvenienceCoversCommonClinicalWindows() throws {
        let presetIDs = [
            "ohif.ct-brain",
            "ohif.ct-lung",
            "ohif.ct-bone",
            "ohif.ct-soft-tissue"
        ]
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        for presetID in presetIDs {
            let preset = try XCTUnwrap(WindowLevelPresetLibrary.preset(withId: presetID))
            let window = MPRPresentationPass.windowRange(for: preset)
            let values = [Int16(window.lowerBound), Int16(window.upperBound)]
            let input = try MPRTestHelpers.makeSignedTexture(values, width: 2, height: 1, device: device)
            let drawable = try MPRTestMetalDrawable(device: device, width: 2, height: 1)
            let frame = MPRTestHelpers.makeFrame(texture: input,
                                  pixelFormat: .int16Signed,
                                  intensityRange: window)

            try pass.present(frame: frame, preset: preset, to: drawable)
            try MPRTestHelpers.waitForQueue(commandQueue)

            XCTAssertEqual(try MPRTestHelpers.readGrayBytes(from: drawable.texture), [0, 255], accuracy: 1)
        }
    }

    func test_windowLevelChangesArePresentationOnly() throws {
        let values: [Int16] = [-100, 0, 100, 200]
        let input = try MPRTestHelpers.makeSignedTexture(values, width: 2, height: 2, device: device)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                              pixelFormat: .int16Signed,
                              intensityRange: -100...200)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        let wideWindowDrawable = try MPRTestMetalDrawable(device: device, width: 2, height: 2)
        try pass.present(frame: frame, window: -100...200, to: wideWindowDrawable)
        try MPRTestHelpers.waitForQueue(commandQueue)

        let narrowWindowDrawable = try MPRTestMetalDrawable(device: device, width: 2, height: 2)
        try pass.present(frame: frame, window: 0...100, to: narrowWindowDrawable)
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertNotEqual(try MPRTestHelpers.readGrayBytes(from: wideWindowDrawable.texture),
                          try MPRTestHelpers.readGrayBytes(from: narrowWindowDrawable.texture))
        XCTAssertEqual(try MPRTestHelpers.readInputValues(Int16.self, from: input), values)
    }

    func test_colormapTextureColorsWindowedOutput() throws {
        let values: [UInt16] = [0, 100]
        let input = try MPRTestHelpers.makeUnsignedTexture(values, width: 2, height: 1, device: device)
        let drawable = try MPRTestMetalDrawable(device: device, width: 2, height: 1)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                              pixelFormat: .int16Unsigned,
                              intensityRange: 0...100)
        let colormap = try MPRTestHelpers.makeColormapTexture([SIMD4<Float>(0, 1, 0, 1)], device: device)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        try pass.present(frame: frame, window: 0...100, to: drawable, colormap: colormap)
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(try MPRTestHelpers.readBGRAByteArrays(from: drawable.texture).flatMap { $0 },
                       [0, 255, 0, 255, 0, 255, 0, 255],
                       accuracy: 1)
    }

    func test_flipWritesPresentationOnlyOrientation() throws {
        let values: [Int16] = [0, 1, 2, 3]
        let input = try MPRTestHelpers.makeSignedTexture(values, width: 2, height: 2, device: device)
        let drawable = try MPRTestMetalDrawable(device: device, width: 2, height: 2)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                              pixelFormat: .int16Signed,
                              intensityRange: 0...3)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        try pass.present(frame: frame,
                         window: 0...3,
                         to: drawable,
                         flipHorizontal: true,
                         flipVertical: true)
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(try MPRTestHelpers.readGrayBytes(from: drawable.texture), [255, 170, 85, 0], accuracy: 1)
        XCTAssertEqual(try MPRTestHelpers.readInputValues(Int16.self, from: input), values)
    }

    func test_bitShiftAdjustsDisplayWithoutMutatingRawTexture() throws {
        let values: [UInt16] = [0, 1_024, 2_048, 4_095]
        let input = try MPRTestHelpers.makeUnsignedTexture(values, width: 2, height: 2, device: device)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                              pixelFormat: .int16Unsigned,
                              intensityRange: 0...4_095)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        let fullRangeDrawable = try MPRTestMetalDrawable(device: device, width: 2, height: 2)
        try pass.present(frame: frame, window: 0...4_095, to: fullRangeDrawable)
        try MPRTestHelpers.waitForQueue(commandQueue)

        let shiftedDrawable = try MPRTestMetalDrawable(device: device, width: 2, height: 2)
        try pass.present(frame: frame, window: 0...255, to: shiftedDrawable, bitShift: 4)
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(try MPRTestHelpers.readGrayBytes(from: shiftedDrawable.texture), [0, 64, 128, 255], accuracy: 1)
        XCTAssertEqual(try MPRTestHelpers.readInputValues(UInt16.self, from: input), values)
    }
}
