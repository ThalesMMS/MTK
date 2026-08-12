import Metal
import simd
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

    func test_signedIdentityConvolutionPreservesPresentedImage() throws {
        let values: [Int16] = [
            -100, -75, -50,
            -25,    0,  25,
              50,  75, 100
        ]
        let input = try MPRTestHelpers.makeSignedTexture(values, width: 3, height: 3, device: device)
        let frame = MPRTestHelpers.makeFrame(
            texture: input,
            pixelFormat: .int16Signed,
            intensityRange: -100...100
        )
        var pass = try MPRPresentationPass(device: device, commandQueue: commandQueue, library: library)

        let baseline = try pass.makeSnapshotTexture(
            frame: frame,
            window: -100...100,
            transform: .identity,
            width: 3,
            height: 3
        )
        let identity = try pass.makeSnapshotTexture(
            frame: frame,
            window: -100...100,
            transform: .identity,
            width: 3,
            height: 3,
            convolutionKernel: .identity
        )

        XCTAssertEqual(
            try MPRTestHelpers.readBGRAByteArrays(from: identity),
            try MPRTestHelpers.readBGRAByteArrays(from: baseline)
        )
    }

    func test_unsignedBlurConvolutionAppliesRawKernelBeforeWindowing() throws {
        let values: [UInt16] = [
              0,   0, 0,
              0, 100, 0,
              0,   0, 0
        ]
        let input = try MPRTestHelpers.makeUnsignedTexture(values, width: 3, height: 3, device: device)
        let frame = MPRTestHelpers.makeFrame(
            texture: input,
            pixelFormat: .int16Unsigned,
            intensityRange: 0...100
        )
        var pass = try MPRPresentationPass(device: device, commandQueue: commandQueue, library: library)

        let filtered = try pass.makeSnapshotTexture(
            frame: frame,
            window: 0...100,
            transform: .identity,
            width: 3,
            height: 3,
            convolutionKernel: .blur
        )

        XCTAssertEqual(
            try MPRTestHelpers.readGrayBytes(from: filtered),
            [16, 32, 16, 32, 64, 32, 16, 32, 16],
            accuracy: 1
        )
    }

    func test_disabledShadingPreservesPreviousPresentationExactly() throws {
        let values: [Int16] = [
            0, 20, 40,
            60, 80, 100,
            120, 140, 160
        ]
        let input = try MPRTestHelpers.makeSignedTexture(values, width: 3, height: 3, device: device)
        let frame = MPRTestHelpers.makeFrame(
            texture: input,
            pixelFormat: .int16Signed,
            intensityRange: 0...160
        )
        var pass = try MPRPresentationPass(device: device, commandQueue: commandQueue, library: library)

        let baseline = try pass.makeSnapshotTexture(
            frame: frame,
            window: 0...160,
            transform: .identity,
            width: 3,
            height: 3
        )
        let disabled = try pass.makeSnapshotTexture(
            frame: frame,
            window: 0...160,
            transform: .identity,
            width: 3,
            height: 3,
            shading: MPRShadingSettings(isEnabled: false, ambient: 1, diffuse: 1, specular: 1)
        )

        XCTAssertEqual(
            try MPRTestHelpers.readBGRAByteArrays(from: disabled),
            try MPRTestHelpers.readBGRAByteArrays(from: baseline)
        )
    }

    func test_enabledShadingAppliesAmbientDiffuseAndSpecularDeterministically() throws {
        let values: [UInt16] = [
            20, 80, 140,
            40, 120, 200,
            60, 160, 240
        ]
        let input = try MPRTestHelpers.makeUnsignedTexture(values, width: 3, height: 3, device: device)
        let frame = MPRTestHelpers.makeFrame(
            texture: input,
            pixelFormat: .int16Unsigned,
            intensityRange: 0...240
        )
        var pass = try MPRPresentationPass(device: device, commandQueue: commandQueue, library: library)
        let settings = MPRShadingSettings(isEnabled: true, ambient: 0.25, diffuse: 0.5, specular: 0.2)

        let first = try pass.makeSnapshotTexture(
            frame: frame,
            window: 0...240,
            transform: .identity,
            width: 3,
            height: 3,
            shading: settings
        )
        let firstBytes = try MPRTestHelpers.readGrayBytes(from: first)
        let second = try pass.makeSnapshotTexture(
            frame: frame,
            window: 0...240,
            transform: .identity,
            width: 3,
            height: 3,
            shading: settings
        )
        let secondBytes = try MPRTestHelpers.readGrayBytes(from: second)
        let ambientOnly = try pass.makeSnapshotTexture(
            frame: frame,
            window: 0...240,
            transform: .identity,
            width: 3,
            height: 3,
            shading: MPRShadingSettings(isEnabled: true, ambient: 0.25, diffuse: 0, specular: 0)
        )

        XCTAssertEqual(secondBytes, firstBytes)
        XCTAssertNotEqual(firstBytes, try MPRTestHelpers.readGrayBytes(from: ambientOnly))
        XCTAssertNotEqual(firstBytes, values.map { UInt8((Float($0) / 240 * 255).rounded()) })
    }

    func test_eachShadingComponentReachesKernelAtExpectedUniformOffset() throws {
        let values: [UInt16] = [
            100, 115, 130,
            105, 120, 135,
            110, 125, 140
        ]
        let input = try MPRTestHelpers.makeUnsignedTexture(values, width: 3, height: 3, device: device)
        let frame = MPRTestHelpers.makeFrame(
            texture: input,
            pixelFormat: .int16Unsigned,
            intensityRange: 0...240
        )
        var pass = try MPRPresentationPass(device: device, commandQueue: commandQueue, library: library)
        let ambient = try pass.makeSnapshotTexture(
            frame: frame,
            window: 0...240,
            transform: .identity,
            width: 3,
            height: 3,
            shading: MPRShadingSettings(isEnabled: true, ambient: 0.4, diffuse: 0, specular: 0)
        )
        let diffuse = try pass.makeSnapshotTexture(
            frame: frame,
            window: 0...240,
            transform: .identity,
            width: 3,
            height: 3,
            shading: MPRShadingSettings(isEnabled: true, ambient: 0, diffuse: 0.6, specular: 0)
        )
        let specular = try pass.makeSnapshotTexture(
            frame: frame,
            window: 0...240,
            transform: .identity,
            width: 3,
            height: 3,
            shading: MPRShadingSettings(isEnabled: true, ambient: 0, diffuse: 0, specular: 1)
        )

        let scales = MPRPresentationPass.shadingGradientScales(for: frame)
        let gradientU = Float(105 - 135) * scales.x
        let gradientV = Float(115 - 125) * scales.y
        let diffuseFactor = 1 / sqrt(gradientU * gradientU + gradientV * gradientV + 1)
        let specularFactor = pow(diffuseFactor, MPRPresentationPass.shadingSpecularExponent)
        let centerNormalized: Float = 0.5

        XCTAssertEqual(
            Int(try MPRTestHelpers.readGrayBytes(from: ambient)[4]),
            Int((centerNormalized * 0.4 * 255).rounded()),
            accuracy: 1
        )
        XCTAssertEqual(
            Int(try MPRTestHelpers.readGrayBytes(from: diffuse)[4]),
            Int((centerNormalized * 0.6 * diffuseFactor * 255).rounded()),
            accuracy: 1
        )
        XCTAssertEqual(
            Int(try MPRTestHelpers.readGrayBytes(from: specular)[4]),
            Int((centerNormalized * specularFactor * 255).rounded()),
            accuracy: 1
        )
    }

    func test_shadingGradientScalesUseRawIntensityRangeAndPhysicalTexelSpacing() throws {
        let input = try MPRTestHelpers.makeUnsignedTexture(
            [UInt16](repeating: 0, count: 25),
            width: 5,
            height: 5,
            device: device
        )
        var frame = MPRTestHelpers.makeFrame(
            texture: input,
            pixelFormat: .int16Unsigned,
            intensityRange: 0...1_200
        )
        frame.planeGeometry.axisUWorld = SIMD3<Float>(2, 0, 0)
        frame.planeGeometry.axisVWorld = SIMD3<Float>(0, 8, 0)

        let scales = MPRPresentationPass.shadingGradientScales(for: frame)
        let shiftedScales = MPRPresentationPass.shadingGradientScales(for: frame, bitShift: 4)
        let rawSpan = Float(frame.intensityRange.upperBound - frame.intensityRange.lowerBound)
        let spacingU = simd_length(frame.planeGeometry.axisUWorld) / Float(frame.texture.width - 1)
        let spacingV = simd_length(frame.planeGeometry.axisVWorld) / Float(frame.texture.height - 1)
        let normalizedScale = MPRPresentationPass.shadingNormalizedGradientScale / rawSpan
        let shiftedNormalizedScale = MPRPresentationPass.shadingNormalizedGradientScale / (rawSpan / 16)

        XCTAssertEqual(scales.x, normalizedScale / spacingU, accuracy: 0.000_001)
        XCTAssertEqual(scales.y, normalizedScale / spacingV, accuracy: 0.000_001)
        XCTAssertEqual(shiftedScales.x, shiftedNormalizedScale / spacingU, accuracy: 0.000_001)
        XCTAssertEqual(shiftedScales.y, shiftedNormalizedScale / spacingV, accuracy: 0.000_001)
    }

    func test_shadingNormalDoesNotChangeWithWindowLevel() throws {
        let values: [UInt16] = [
            100, 115, 130,
            105, 120, 135,
            110, 125, 140
        ]
        let input = try MPRTestHelpers.makeUnsignedTexture(values, width: 3, height: 3, device: device)
        let frame = MPRTestHelpers.makeFrame(
            texture: input,
            pixelFormat: .int16Unsigned,
            intensityRange: 0...240
        )
        var pass = try MPRPresentationPass(device: device, commandQueue: commandQueue, library: library)
        let shading = MPRShadingSettings(isEnabled: true, ambient: 0.3, diffuse: 0.6, specular: 0.1)

        // The center value 120 normalizes to 0.5 in both 0...240 and 100...140.
        let wideWindow = try pass.makeSnapshotTexture(
            frame: frame,
            window: 0...240,
            transform: .identity,
            width: 3,
            height: 3,
            shading: shading
        )
        let narrowWindow = try pass.makeSnapshotTexture(
            frame: frame,
            window: 100...140,
            transform: .identity,
            width: 3,
            height: 3,
            shading: shading
        )

        XCTAssertEqual(
            try MPRTestHelpers.readGrayBytes(from: wideWindow)[4],
            try MPRTestHelpers.readGrayBytes(from: narrowWindow)[4]
        )
    }

    func test_overlayFreePresentation_shaderWritableDrawable_usesDirectOutput() throws {
        let input = try MPRTestHelpers.makeUnsignedTexture([0, 100], width: 2, height: 1, device: device)
        let drawable = try MPRTestMetalDrawable(device: device, width: 2, height: 1)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                                             pixelFormat: .int16Unsigned,
                                             intensityRange: 0...100)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        try pass.present(frame: frame,
                         window: 0...100,
                         to: drawable,
                         transform: .identity)
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(pass.debugLastPresentationUsedDirectOutput, true)
        XCTAssertEqual(try MPRTestHelpers.readGrayBytes(from: drawable.texture), [0, 255], accuracy: 1)
    }

    func test_presentationTextureCallback_receivesGPUIntermediateUsedForMagnification() throws {
        let input = try MPRTestHelpers.makeUnsignedTexture([0, 100], width: 2, height: 1, device: device)
        let drawable = try MPRTestMetalDrawable(device: device, width: 2, height: 1)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                                             pixelFormat: .int16Unsigned,
                                             intensityRange: 0...100)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)
        var presentationTexture: (any MTLTexture)?

        try pass.present(
            frame: frame,
            window: 0...100,
            to: drawable,
            transform: .identity,
            onPresentationTextureReady: { presentationTexture = $0 }
        )
        try MPRTestHelpers.waitForQueue(commandQueue)

        let texture = try XCTUnwrap(presentationTexture)
        XCTAssertEqual(pass.debugLastPresentationUsedDirectOutput, false)
        XCTAssertNotEqual(ObjectIdentifier(texture as AnyObject), ObjectIdentifier(drawable.texture))
        XCTAssertEqual(texture.pixelFormat, .bgra8Unorm)
        XCTAssertEqual(try MPRTestHelpers.readGrayBytes(from: texture), [0, 255], accuracy: 1)
    }

    func test_overlayFreePresentation_nonShaderWritableDrawable_usesFallback() throws {
        let input = try MPRTestHelpers.makeUnsignedTexture([0, 100], width: 2, height: 1, device: device)
        let drawable = try MPRTestMetalDrawable(device: device,
                                                width: 2,
                                                height: 1,
                                                usage: [.shaderRead, .renderTarget])
        let frame = MPRTestHelpers.makeFrame(texture: input,
                                             pixelFormat: .int16Unsigned,
                                             intensityRange: 0...100)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        try pass.present(frame: frame,
                         window: 0...100,
                         to: drawable,
                         transform: .identity)
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(pass.debugLastPresentationUsedDirectOutput, false)
        XCTAssertEqual(try MPRTestHelpers.readGrayBytes(from: drawable.texture), [0, 255], accuracy: 1)
    }

    func test_snapshot_intermediatePresentationRoute_isPreserved() throws {
        let input = try MPRTestHelpers.makeUnsignedTexture([0, 100], width: 2, height: 1, device: device)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                                             pixelFormat: .int16Unsigned,
                                             intensityRange: 0...100)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        let snapshot = try pass.makeSnapshotTexture(frame: frame,
                                                    window: 0...100,
                                                    transform: .identity,
                                                    width: 2,
                                                    height: 1)

        XCTAssertEqual(pass.debugLastPresentationUsedDirectOutput, false)
        XCTAssertEqual(try MPRTestHelpers.readGrayBytes(from: snapshot), [0, 255], accuracy: 1)
    }

    func test_aspectFitLetterboxesInsteadOfStretchingSourcePixels() throws {
        let values: [Int16] = [0, 100, 200, 300]
        let input = try MPRTestHelpers.makeSignedTexture(values, width: 2, height: 2, device: device)
        let drawable = try MPRTestMetalDrawable(device: device, width: 4, height: 2)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                                             pixelFormat: .int16Signed,
                                             intensityRange: 0...300)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        try pass.present(frame: frame, window: 0...300, to: drawable)
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(try MPRTestHelpers.readGrayBytes(from: drawable.texture),
                       [
                           0, 0, 85, 0,
                           0, 170, 255, 0
                       ],
                       accuracy: 1)
    }

    func test_outOfVolumeObliquePixelsRemainBlackWithInvertedWindow() throws {
        let input = try MPRTestHelpers.makeSignedTexture(
            [100, 100, 100, 100],
            width: 2,
            height: 2,
            device: device
        )
        let drawable = try MPRTestMetalDrawable(device: device, width: 2, height: 2)
        var frame = MPRTestHelpers.makeFrame(
            texture: input,
            pixelFormat: .int16Signed,
            intensityRange: 0...200
        )
        frame.planeGeometry.originTexture = SIMD3<Float>(-0.5, 0, 0.25)
        frame.planeGeometry.axisUTexture = SIMD3<Float>(1, 0, 0.5)
        frame.planeGeometry.axisVTexture = SIMD3<Float>(0.5, 1, 0)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        try pass.present(frame: frame,
                         window: 0...200,
                         to: drawable,
                         invert: true)
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(
            try MPRTestHelpers.readGrayBytes(from: drawable.texture),
            [0, 128, 128, 128],
            accuracy: 1
        )
    }

    func test_outOfVolumeObliqueUnsignedPixelsRemainBlackWithInvertedWindow() throws {
        let input = try MPRTestHelpers.makeUnsignedTexture(
            [100, 100, 100, 100],
            width: 2,
            height: 2,
            device: device
        )
        let drawable = try MPRTestMetalDrawable(device: device, width: 2, height: 2)
        var frame = MPRTestHelpers.makeFrame(
            texture: input,
            pixelFormat: .int16Unsigned,
            intensityRange: 0...200
        )
        frame.planeGeometry.originTexture = SIMD3<Float>(-0.5, 0, 0.25)
        frame.planeGeometry.axisUTexture = SIMD3<Float>(1, 0, 0.5)
        frame.planeGeometry.axisVTexture = SIMD3<Float>(0.5, 1, 0)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        try pass.present(frame: frame,
                         window: 0...200,
                         to: drawable,
                         invert: true)
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(
            try MPRTestHelpers.readGrayBytes(from: drawable.texture),
            [0, 128, 128, 128],
            accuracy: 1
        )
    }

    func test_outOfVolumeObliquePixelsRemainBlackWithHorizontalFlipAndTransposition() throws {
        let input = try MPRTestHelpers.makeSignedTexture(
            [100, 100, 100, 100],
            width: 2,
            height: 2,
            device: device
        )
        let drawable = try MPRTestMetalDrawable(device: device, width: 2, height: 2)
        var frame = MPRTestHelpers.makeFrame(
            texture: input,
            pixelFormat: .int16Signed,
            intensityRange: 0...200
        )
        frame.planeGeometry.originTexture = SIMD3<Float>(-0.5, 0, 0.25)
        frame.planeGeometry.axisUTexture = SIMD3<Float>(1, 0, 0.5)
        frame.planeGeometry.axisVTexture = SIMD3<Float>(0.5, 1, 0)
        let transform = makeDisplayTransform(orientation: .rotated90CW)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        XCTAssertTrue(transform.presentationFlipHorizontal)
        XCTAssertTrue(transform.transposeUV)
        try pass.present(frame: frame,
                         window: 0...200,
                         to: drawable,
                         transform: transform,
                         invert: true)
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(
            try MPRTestHelpers.readGrayBytes(from: drawable.texture),
            [128, 0, 128, 128],
            accuracy: 1
        )
    }

    func test_rotated90CW_presentsPixelsAtDisplayTransformCoordinates() throws {
        let input = try MPRTestHelpers.makeUnsignedTexture(
            [0, 10, 20, 30, 40, 50],
            width: 2,
            height: 3,
            device: device
        )
        let drawable = try MPRTestMetalDrawable(device: device, width: 3, height: 2)
        let frame = MPRTestHelpers.makeFrame(
            texture: input,
            pixelFormat: .int16Unsigned,
            intensityRange: 0...50
        )
        let transform = makeDisplayTransform(orientation: .rotated90CW)
        var pass = try MPRPresentationPass(device: device, commandQueue: commandQueue, library: library)

        try pass.present(frame: frame, window: 0...50, to: drawable, transform: transform)
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(transform.textureCoordinates(forScreen: .zero), SIMD2<Float>(0, 1))
        XCTAssertEqual(
            try MPRTestHelpers.readGrayBytes(from: drawable.texture),
            [204, 102, 0, 255, 153, 51],
            accuracy: 1
        )
    }

    func test_rotated90CCW_presentsPixelsAtDisplayTransformCoordinates() throws {
        let input = try MPRTestHelpers.makeUnsignedTexture(
            [0, 10, 20, 30, 40, 50],
            width: 2,
            height: 3,
            device: device
        )
        let drawable = try MPRTestMetalDrawable(device: device, width: 3, height: 2)
        let frame = MPRTestHelpers.makeFrame(
            texture: input,
            pixelFormat: .int16Unsigned,
            intensityRange: 0...50
        )
        let transform = makeDisplayTransform(orientation: .rotated90CCW)
        var pass = try MPRPresentationPass(device: device, commandQueue: commandQueue, library: library)

        try pass.present(frame: frame, window: 0...50, to: drawable, transform: transform)
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(transform.textureCoordinates(forScreen: .zero), SIMD2<Float>(1, 0))
        XCTAssertEqual(
            try MPRTestHelpers.readGrayBytes(from: drawable.texture),
            [51, 153, 255, 0, 102, 204],
            accuracy: 1
        )
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
            "isis.ct-brain",
            "isis.ct-lung",
            "isis.ct-bone",
            "isis.ct-soft-tissue"
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

    func test_rectangularShutterMasksOutsideRegionInPresentationPass() throws {
        let values = [Int16](repeating: 100, count: 9)
        let input = try MPRTestHelpers.makeSignedTexture(values, width: 3, height: 3, device: device)
        let drawable = try MPRTestMetalDrawable(device: device, width: 3, height: 3)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                                             pixelFormat: .int16Signed,
                                             intensityRange: 0...100)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        try pass.present(frame: frame,
                         window: 0...100,
                         to: drawable,
                         shutter: .rectangular(
                            min: SIMD2<Float>(0.5, 0.5),
                            max: SIMD2<Float>(0.5, 0.5)
                         ))
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(try MPRTestHelpers.readGrayBytes(from: drawable.texture),
                       [
                           0, 0, 0,
                           0, 255, 0,
                           0, 0, 0
                       ],
                       accuracy: 1)
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

    func test_identityColormapMatchesPresentationWithoutColormap() throws {
        let values: [UInt16] = [0, 25, 50, 75, 100]
        let input = try MPRTestHelpers.makeUnsignedTexture(values, width: 5, height: 1, device: device)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                                             pixelFormat: .int16Unsigned,
                                             intensityRange: 0...100)
        let baselineDrawable = try MPRTestMetalDrawable(device: device, width: 5, height: 1)
        let identityDrawable = try MPRTestMetalDrawable(device: device, width: 5, height: 1)
        let identityColors = (0..<256).map { index -> SIMD4<Float> in
            let value = Float(index) / 255
            return SIMD4<Float>(value, value, value, 1)
        }
        let identity = try MPRTestHelpers.makeColormapTexture(identityColors, device: device)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        try pass.present(frame: frame, window: 0...100, to: baselineDrawable)
        try pass.present(frame: frame, window: 0...100, to: identityDrawable, colormap: identity)
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(
            try MPRTestHelpers.readBGRAByteArrays(from: identityDrawable.texture).flatMap { $0 },
            try MPRTestHelpers.readBGRAByteArrays(from: baselineDrawable.texture).flatMap { $0 },
            accuracy: 1
        )
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

    func test_viewportRotationWritesPresentationOnlyOrientation() throws {
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
                         viewportTransform: MPRViewportTransform(rotationRadians: .pi / 2))
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(try MPRTestHelpers.readGrayBytes(from: drawable.texture), [170, 0, 255, 85], accuracy: 1)
        XCTAssertEqual(try MPRTestHelpers.readInputValues(Int16.self, from: input), values)
    }

    func test_viewportQuarterTurnSwapsRectangularPresentationBounds() throws {
        let values = [Int16](repeating: 100, count: 8)
        let input = try MPRTestHelpers.makeSignedTexture(values, width: 4, height: 2, device: device)
        let drawable = try MPRTestMetalDrawable(device: device, width: 4, height: 4)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                                             pixelFormat: .int16Signed,
                                             intensityRange: 0...100)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        try pass.present(frame: frame,
                         window: 0...100,
                         to: drawable,
                         viewportTransform: MPRViewportTransform(rotationRadians: .pi / 2))
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(try MPRTestHelpers.readGrayBytes(from: drawable.texture),
                       [
                           0, 255, 255, 0,
                           0, 255, 255, 0,
                           0, 255, 255, 0,
                           0, 255, 255, 0
                       ],
                       accuracy: 1)
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

    func test_viewportZoomResamplesPresentationWithoutMutatingRawTexture() throws {
        let values = (0..<16).map(Int16.init)
        let input = try MPRTestHelpers.makeSignedTexture(values, width: 4, height: 4, device: device)
        let drawable = try MPRTestMetalDrawable(device: device, width: 4, height: 4)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                                             pixelFormat: .int16Signed,
                                             intensityRange: 0...15)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        try pass.present(frame: frame,
                         window: 0...15,
                         to: drawable,
                         transform: .identity,
                         viewportTransform: MPRViewportTransform(zoom: 2))
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(try MPRTestHelpers.readGrayBytes(from: drawable.texture),
                       [
                           85, 85, 102, 102,
                           85, 85, 102, 102,
                           153, 153, 170, 170,
                           153, 153, 170, 170
                       ],
                       accuracy: 1)
        XCTAssertEqual(try MPRTestHelpers.readInputValues(Int16.self, from: input), values)
    }

    func test_viewportZoomUsesLetterboxBandsWhenMagnified() throws {
        let values = [Int16](repeating: 100, count: 16)
        let input = try MPRTestHelpers.makeSignedTexture(values, width: 4, height: 4, device: device)
        let drawable = try MPRTestMetalDrawable(device: device, width: 4, height: 8)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                                             pixelFormat: .int16Signed,
                                             intensityRange: 0...100)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        try pass.present(frame: frame,
                         window: 0...100,
                         to: drawable,
                         transform: .identity,
                         viewportTransform: MPRViewportTransform(zoom: 2))
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(
            try MPRTestHelpers.readGrayBytes(from: drawable.texture),
            [UInt8](repeating: 255, count: 32),
            accuracy: 1
        )
    }

    func test_viewportTransformKeepsLabelmapOverlayAlignedWithVisibleSourcePixels() throws {
        let input = try MPRTestHelpers.makeUnsignedTexture([UInt16](repeating: 0, count: 16),
                                                           width: 4,
                                                           height: 4,
                                                           device: device)
        let drawable = try MPRTestMetalDrawable(device: device, width: 4, height: 4)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                                             pixelFormat: .int16Unsigned,
                                             intensityRange: 0...100)
        let labelmapTexture = try makeLabelmapTexture([UInt16](repeating: 1, count: 16),
                                                       width: 4,
                                                       height: 4,
                                                       depth: 1)
        let lutTexture = try MPRTestHelpers.makeColormapTexture([
            SIMD4<Float>(0, 0, 0, 0),
            SIMD4<Float>(1, 0, 0, 1)
        ], device: device)
        let overlay = MPRLabelmapOverlay(
            labelmapTexture: labelmapTexture,
            colorLUTTexture: lutTexture,
            opacity: 1,
            originTexture: SIMD3<Float>(0, 0, 0.5),
            axisUTexture: SIMD3<Float>(1, 0, 0),
            axisVTexture: SIMD3<Float>(0, 1, 0)
        )
        var viewport = MPRViewportTransform(zoom: 2)
        viewport.pan = SIMD2<Float>(1, 0)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        try pass.present(frame: frame,
                         window: 0...100,
                         to: drawable,
                         transform: .identity,
                         viewportTransform: viewport,
                         labelmapOverlays: [overlay])
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(try MPRTestHelpers.readBGRAByteArrays(from: drawable.texture).flatMap { $0 },
                       [
                           0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255,
                           0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255,
                           0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255,
                           0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255
                       ],
                       accuracy: 1)
    }

    func test_emptyLabelmapOverlayListMatchesBasePresentation() throws {
        let values: [UInt16] = [0, 50, 100, 150]
        let input = try MPRTestHelpers.makeUnsignedTexture(values, width: 2, height: 2, device: device)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                              pixelFormat: .int16Unsigned,
                              intensityRange: 0...150)
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        let baseDrawable = try MPRTestMetalDrawable(device: device, width: 2, height: 2)
        try pass.present(frame: frame, window: 0...150, to: baseDrawable)
        try MPRTestHelpers.waitForQueue(commandQueue)

        let overlayDrawable = try MPRTestMetalDrawable(device: device, width: 2, height: 2)
        try pass.present(frame: frame,
                         window: 0...150,
                         to: overlayDrawable,
                         labelmapOverlays: [])
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(try MPRTestHelpers.readBGRAByteArrays(from: overlayDrawable.texture).flatMap { $0 },
                       try MPRTestHelpers.readBGRAByteArrays(from: baseDrawable.texture).flatMap { $0 })
    }

    func test_labelmapOverlayCompositesVisibleLabelsWithOpacityAndTransparentBackground() throws {
        let input = try MPRTestHelpers.makeUnsignedTexture([0, 0, 0, 0], width: 2, height: 2, device: device)
        let drawable = try MPRTestMetalDrawable(device: device, width: 2, height: 2)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                              pixelFormat: .int16Unsigned,
                              intensityRange: 0...100)
        let labelmapTexture = try makeLabelmapTexture([0, 1, 2, 0], width: 2, height: 2, depth: 1)
        let lutTexture = try MPRTestHelpers.makeColormapTexture([
            SIMD4<Float>(0, 0, 0, 0),
            SIMD4<Float>(1, 0, 0, 1),
            SIMD4<Float>(0, 1, 0, 0.5)
        ], device: device)
        let overlay = MPRLabelmapOverlay(
            labelmapTexture: labelmapTexture,
            colorLUTTexture: lutTexture,
            opacity: 0.5,
            originTexture: SIMD3<Float>(0.25, 0.25, 0.5),
            axisUTexture: SIMD3<Float>(0.5, 0, 0),
            axisVTexture: SIMD3<Float>(0, 0.5, 0)
        )
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        try pass.present(frame: frame,
                         window: 0...100,
                         to: drawable,
                         labelmapOverlays: [overlay])
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(pass.debugLastPresentationUsedDirectOutput, false)
        XCTAssertEqual(try MPRTestHelpers.readBGRAByteArrays(from: drawable.texture).flatMap { $0 },
                       [
                           0, 0, 0, 255,
                           0, 0, 128, 255,
                           0, 64, 0, 255,
                           0, 0, 0, 255
                       ],
                       accuracy: 1)
    }

    func test_rotated90CW_transposesLabelmapOverlayWithBasePresentation() throws {
        let input = try MPRTestHelpers.makeUnsignedTexture([0, 0, 0, 0], width: 2, height: 2, device: device)
        let drawable = try MPRTestMetalDrawable(device: device, width: 2, height: 2)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                                             pixelFormat: .int16Unsigned,
                                             intensityRange: 0...100)
        let labelmapTexture = try makeLabelmapTexture([0, 1, 0, 0], width: 2, height: 2, depth: 1)
        let lutTexture = try MPRTestHelpers.makeColormapTexture([
            SIMD4<Float>(0, 0, 0, 0),
            SIMD4<Float>(1, 0, 0, 1)
        ], device: device)
        let overlay = MPRLabelmapOverlay(labelmapTexture: labelmapTexture,
                                         colorLUTTexture: lutTexture,
                                         opacity: 1,
                                         originTexture: SIMD3<Float>(0.25, 0.25, 0.5),
                                         axisUTexture: SIMD3<Float>(0.5, 0, 0),
                                         axisVTexture: SIMD3<Float>(0, 0.5, 0))
        var pass = try MPRPresentationPass(device: device, commandQueue: commandQueue, library: library)

        try pass.present(frame: frame,
                         window: 0...100,
                         to: drawable,
                         transform: makeDisplayTransform(orientation: .rotated90CW),
                         labelmapOverlays: [overlay])
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(try MPRTestHelpers.readBGRAByteArrays(from: drawable.texture).flatMap { $0 },
                       [0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 255, 255],
                       accuracy: 1)
    }

    func test_scalarOverlayCompositesColorwashWithOpacity() throws {
        let input = try MPRTestHelpers.makeUnsignedTexture([0, 0, 0, 0], width: 2, height: 2, device: device)
        let drawable = try MPRTestMetalDrawable(device: device, width: 2, height: 2)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                                             pixelFormat: .int16Unsigned,
                                             intensityRange: 0...100)
        let scalarTexture = try makeLabelmapTexture([0, 200, 200, 0],
                                                    width: 2,
                                                    height: 2,
                                                    depth: 1)
        let lutTexture = try MPRTestHelpers.makeColormapTexture([
            SIMD4<Float>(0, 0, 0, 0),
            SIMD4<Float>(1, 0, 0, 1)
        ], device: device)
        let overlay = MPRScalarVolumeOverlay(
            scalarTexture: scalarTexture,
            colorLUTTexture: lutTexture,
            pixelFormat: .int16Unsigned,
            opacity: 0.5,
            blendMode: .sourceOver,
            intensityRange: 0...200,
            originTexture: SIMD3<Float>(0.25, 0.25, 0.5),
            axisUTexture: SIMD3<Float>(0.5, 0, 0),
            axisVTexture: SIMD3<Float>(0, 0.5, 0)
        )
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        try pass.present(frame: frame,
                         window: 0...100,
                         to: drawable,
                         scalarOverlays: [overlay])
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(try MPRTestHelpers.readBGRAByteArrays(from: drawable.texture).flatMap { $0 },
                       [
                           0, 0, 0, 255,
                           0, 0, 128, 255,
                           0, 0, 128, 255,
                           0, 0, 0, 255
                       ],
                       accuracy: 1)
    }

    func test_rotated90CCW_transposesScalarOverlayWithBasePresentation() throws {
        let input = try MPRTestHelpers.makeUnsignedTexture([0, 0, 0, 0], width: 2, height: 2, device: device)
        let drawable = try MPRTestMetalDrawable(device: device, width: 2, height: 2)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                                             pixelFormat: .int16Unsigned,
                                             intensityRange: 0...100)
        let scalarTexture = try makeLabelmapTexture([0, 200, 0, 0], width: 2, height: 2, depth: 1)
        let lutTexture = try MPRTestHelpers.makeColormapTexture([
            SIMD4<Float>(0, 0, 0, 0),
            SIMD4<Float>(1, 0, 0, 1)
        ], device: device)
        let overlay = MPRScalarVolumeOverlay(scalarTexture: scalarTexture,
                                             colorLUTTexture: lutTexture,
                                             pixelFormat: .int16Unsigned,
                                             opacity: 1,
                                             blendMode: .sourceOver,
                                             intensityRange: 0...200,
                                             originTexture: SIMD3<Float>(0.25, 0.25, 0.5),
                                             axisUTexture: SIMD3<Float>(0.5, 0, 0),
                                             axisVTexture: SIMD3<Float>(0, 0.5, 0))
        var pass = try MPRPresentationPass(device: device, commandQueue: commandQueue, library: library)

        try pass.present(frame: frame,
                         window: 0...100,
                         to: drawable,
                         transform: makeDisplayTransform(orientation: .rotated90CCW),
                         scalarOverlays: [overlay])
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(try MPRTestHelpers.readBGRAByteArrays(from: drawable.texture).flatMap { $0 },
                       [0, 0, 255, 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255],
                       accuracy: 1)
    }

    func test_labelmapOverlaySkipsOutOfBoundsSamples() throws {
        let input = try MPRTestHelpers.makeUnsignedTexture([0, 0, 0, 0], width: 2, height: 2, device: device)
        let drawable = try MPRTestMetalDrawable(device: device, width: 2, height: 2)
        let frame = MPRTestHelpers.makeFrame(texture: input,
                              pixelFormat: .int16Unsigned,
                              intensityRange: 0...100)
        let labelmapTexture = try makeLabelmapTexture([1, 1, 1, 1], width: 2, height: 2, depth: 1)
        let lutTexture = try MPRTestHelpers.makeColormapTexture([
            SIMD4<Float>(0, 0, 0, 0),
            SIMD4<Float>(1, 0, 0, 1)
        ], device: device)
        let overlay = MPRLabelmapOverlay(
            labelmapTexture: labelmapTexture,
            colorLUTTexture: lutTexture,
            opacity: 1,
            originTexture: SIMD3<Float>(-0.5, -0.5, 0.5),
            axisUTexture: SIMD3<Float>(0, 0, 0),
            axisVTexture: SIMD3<Float>(0, 0, 0)
        )
        var pass = try MPRPresentationPass(device: device,
                                           commandQueue: commandQueue,
                                           library: library)

        try pass.present(frame: frame,
                         window: 0...100,
                         to: drawable,
                         labelmapOverlays: [overlay])
        try MPRTestHelpers.waitForQueue(commandQueue)

        XCTAssertEqual(try MPRTestHelpers.readBGRAByteArrays(from: drawable.texture).flatMap { $0 },
                       [
                           0, 0, 0, 255,
                           0, 0, 0, 255,
                           0, 0, 0, 255,
                           0, 0, 0, 255
                       ],
                       accuracy: 1)
    }

    private func makeLabelmapTexture(_ values: [UInt16],
                                     width: Int,
                                     height: Int,
                                     depth: Int) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r16Uint
        descriptor.width = width
        descriptor.height = height
        descriptor.depth = depth
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        values.withUnsafeBytes { buffer in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, width, height, depth),
                            mipmapLevel: 0,
                            slice: 0,
                            withBytes: buffer.baseAddress!,
                            bytesPerRow: width * MemoryLayout<UInt16>.stride,
                            bytesPerImage: width * height * MemoryLayout<UInt16>.stride)
        }
        return texture
    }

    private func makeDisplayTransform(orientation: MPRDisplayOrientation) -> MPRDisplayTransform {
        MPRDisplayTransform(
            orientation: orientation,
            flipHorizontal: false,
            flipVertical: false,
            leadingLabel: .right,
            trailingLabel: .left,
            topLabel: .anterior,
            bottomLabel: .posterior
        )
    }
}
