//
//  MPRPresentationPass.swift
//  MTK
//
//  Presentation pass for raw MPR intensity textures.
//

import CoreGraphics
import Foundation
import QuartzCore
@preconcurrency import Metal

public enum MPRPresentationPassError: Error, Equatable, LocalizedError {
    case commandQueueDeviceMismatch
    case shaderLibraryDeviceMismatch
    case drawableDeviceMismatch(sourceDevice: String, drawableDevice: String)
    case drawablePixelFormatUnsupported(MTLPixelFormat)
    case frameTextureFormatMismatch(expected: MTLPixelFormat, actual: MTLPixelFormat)
    case sizeMismatch(source: CGSize, drawable: CGSize)
    case pipelineUnavailable(String)
    case pipelineUnavailableWithError(functionName: String, underlyingError: any Error)
    case commandBufferCreationFailed
    case encoderCreationFailed
    case presentationTextureCreationFailed
    case colormapDeviceMismatch
    case fallbackColormapCreationFailed

    public static func == (lhs: MPRPresentationPassError, rhs: MPRPresentationPassError) -> Bool {
        switch (lhs, rhs) {
        case (.commandQueueDeviceMismatch, .commandQueueDeviceMismatch),
             (.shaderLibraryDeviceMismatch, .shaderLibraryDeviceMismatch),
             (.commandBufferCreationFailed, .commandBufferCreationFailed),
             (.encoderCreationFailed, .encoderCreationFailed),
             (.presentationTextureCreationFailed, .presentationTextureCreationFailed),
             (.colormapDeviceMismatch, .colormapDeviceMismatch),
             (.fallbackColormapCreationFailed, .fallbackColormapCreationFailed):
            return true
        case let (.drawableDeviceMismatch(lhsSource, lhsDrawable), .drawableDeviceMismatch(rhsSource, rhsDrawable)):
            return lhsSource == rhsSource && lhsDrawable == rhsDrawable
        case let (.drawablePixelFormatUnsupported(lhsFormat), .drawablePixelFormatUnsupported(rhsFormat)):
            return lhsFormat == rhsFormat
        case let (.frameTextureFormatMismatch(lhsExpected, lhsActual), .frameTextureFormatMismatch(rhsExpected, rhsActual)):
            return lhsExpected == rhsExpected && lhsActual == rhsActual
        case let (.sizeMismatch(lhsSource, lhsDrawable), .sizeMismatch(rhsSource, rhsDrawable)):
            return lhsSource == rhsSource && lhsDrawable == rhsDrawable
        case let (.pipelineUnavailable(lhsName), .pipelineUnavailable(rhsName)):
            return lhsName == rhsName
        case let (
            .pipelineUnavailableWithError(lhsName, lhsError),
            .pipelineUnavailableWithError(rhsName, rhsError)
        ):
            return lhsName == rhsName
                && String(describing: lhsError) == String(describing: rhsError)
        default:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .commandQueueDeviceMismatch:
            return "MPR presentation command queue belongs to a different Metal device."
        case .shaderLibraryDeviceMismatch:
            return "MPR presentation shader library belongs to a different Metal device."
        case let .drawableDeviceMismatch(sourceDevice, drawableDevice):
            return "MPR source texture device \(sourceDevice) does not match drawable device \(drawableDevice)."
        case let .drawablePixelFormatUnsupported(pixelFormat):
            return "MPR presentation requires a BGRA8 drawable, got \(pixelFormat)."
        case let .frameTextureFormatMismatch(expected, actual):
            return "MPR frame texture pixel format \(actual) does not match expected raw intensity format \(expected)."
        case let .sizeMismatch(source, drawable):
            return "MPR frame size \(source.width)x\(source.height) does not match drawable size \(drawable.width)x\(drawable.height)."
        case let .pipelineUnavailable(functionName):
            return "MPR presentation pipeline \(functionName) is unavailable."
        case let .pipelineUnavailableWithError(functionName, underlyingError):
            return "MPR presentation pipeline \(functionName) is unavailable: \(underlyingError.localizedDescription)"
        case .commandBufferCreationFailed:
            return "Failed to create a command buffer for MPR presentation."
        case .encoderCreationFailed:
            return "Failed to create a Metal encoder for MPR presentation."
        case .presentationTextureCreationFailed:
            return "Failed to create the intermediate BGRA8 MPR presentation texture."
        case .colormapDeviceMismatch:
            return "MPR colormap texture belongs to a different Metal device."
        case .fallbackColormapCreationFailed:
            return "Failed to create the fallback MPR colormap texture."
        }
    }
}

public enum MPRPresentationCommandBufferError: Error, Equatable, LocalizedError, Sendable {
    case commandBufferFailed(status: Int, description: String?)

    public var errorDescription: String? {
        switch self {
        case let .commandBufferFailed(status, description):
            if let description, description.isEmpty == false {
                return "MPR presentation command buffer failed with status \(status): \(description)"
            }
            return "MPR presentation command buffer failed with status \(status)."
        }
    }
}

/// Presents raw MPR intensity textures as BGRA8 drawable output.
///
/// `MPRPresentationPass` keeps mutable caches for `pipelineCache` and
/// `cachedPresentationTexture`. Cache access is guarded by `cacheLock`; UI
/// integrations still keep instances MainActor-bound, and `present()` asserts
/// main-thread use in debug builds to catch accidental off-actor calls.
public struct MPRPresentationPass {
    public let device: any MTLDevice
    public let commandQueue: any MTLCommandQueue
    public let library: any MTLLibrary
    private let cacheLock = NSLock()
    private var pipelineCache: [String: MTLComputePipelineState] = [:]
    private var cachedPresentationTexture: (any MTLTexture)?
    private var fallbackColormapTexture: (any MTLTexture)?

    private struct MPRPresentationUniforms {
        var windowMin: Int32
        var windowMax: Int32
        /// `invert == 1` presents MONOCHROME1; `invert == 0` presents MONOCHROME2.
        var invert: Int32
        var useColormap: Int32
        var flipHorizontal: Int32
        var flipVertical: Int32
        var bitShift: Int32
        var _pad0: Int32
    }

    public init(device: any MTLDevice,
                commandQueue: any MTLCommandQueue,
                library: (any MTLLibrary)? = nil) throws {
        guard commandQueue.device === device else {
            throw MPRPresentationPassError.commandQueueDeviceMismatch
        }

        let resolvedLibrary: any MTLLibrary
        if let library {
            resolvedLibrary = library
        } else {
            resolvedLibrary = try ShaderLibraryLoader.loadLibrary(for: device)
        }

        guard resolvedLibrary.device === device else {
            throw MPRPresentationPassError.shaderLibraryDeviceMismatch
        }

        self.device = device
        self.commandQueue = commandQueue
        self.library = resolvedLibrary
    }

    @discardableResult
    public mutating func present(frame: MPRTextureFrame,
                                 window: ClosedRange<Int32>,
                                 to drawable: any CAMetalDrawable,
                                 transform: MPRDisplayTransform,
                                 invert: Bool = false,
                                 colormap: (any MTLTexture)? = nil,
                                 bitShift: Int32 = 0,
                                 onCommandBufferFailure: ((MPRPresentationCommandBufferError) -> Void)? = nil) throws -> CFAbsoluteTime {
        try presentImpl(frame: frame,
                        window: window,
                        to: drawable,
                        invert: invert,
                        colormap: colormap,
                        flipHorizontal: transform.presentationFlipHorizontal,
                        flipVertical: transform.presentationFlipVertical,
                        bitShift: bitShift,
                        onCommandBufferFailure: onCommandBufferFailure)
    }

    @available(*, deprecated, message: "Use present(frame:window:to:transform:...) instead.")
    @discardableResult
    public mutating func present(frame: MPRTextureFrame,
                                 window: ClosedRange<Int32>,
                                 to drawable: any CAMetalDrawable,
                                 invert: Bool = false,
                                 colormap: (any MTLTexture)? = nil,
                                 flipHorizontal: Bool = false,
                                 flipVertical: Bool = false,
                                 bitShift: Int32 = 0,
                                 onCommandBufferFailure: ((MPRPresentationCommandBufferError) -> Void)? = nil) throws -> CFAbsoluteTime {
        try presentImpl(frame: frame,
                        window: window,
                        to: drawable,
                        invert: invert,
                        colormap: colormap,
                        flipHorizontal: flipHorizontal,
                        flipVertical: flipVertical,
                        bitShift: bitShift,
                        onCommandBufferFailure: onCommandBufferFailure)
    }

    @discardableResult
    private mutating func presentImpl(frame: MPRTextureFrame,
                                      window: ClosedRange<Int32>,
                                      to drawable: any CAMetalDrawable,
                                      invert: Bool,
                                      colormap: (any MTLTexture)?,
                                      flipHorizontal: Bool,
                                      flipVertical: Bool,
                                      bitShift: Int32,
                                      onCommandBufferFailure: ((MPRPresentationCommandBufferError) -> Void)?) throws -> CFAbsoluteTime {
        assert(
            Thread.isMainThread,
            "MPRPresentationPass.present() uses pipelineCache and cachedPresentationTexture; use it from the MainActor or another single-threaded context."
        )
        let startedAt = CFAbsoluteTimeGetCurrent()
        try validate(frame: frame, drawableTexture: drawable.texture, colormap: colormap)

        let presentationTexture = try reusablePresentationTexture(width: frame.texture.width,
                                                                  height: frame.texture.height)
        let colormapTexture = try colormap ?? reusableFallbackColormapTexture()
        let pipeline = try pipelineState(for: frame.pixelFormat)
        var uniforms = MPRPresentationUniforms(
            windowMin: window.lowerBound,
            windowMax: window.upperBound,
            invert: invert ? 1 : 0,
            useColormap: colormap == nil ? 0 : 1,
            flipHorizontal: flipHorizontal ? 1 : 0,
            flipVertical: flipVertical ? 1 : 0,
            bitShift: max(0, min(bitShift, 15)),
            _pad0: 0
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MPRPresentationPassError.commandBufferCreationFailed
        }
        commandBuffer.label = "mpr_presentation"

        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MPRPresentationPassError.encoderCreationFailed
        }
        computeEncoder.label = "mpr_presentation"
        computeEncoder.setComputePipelineState(pipeline)
        computeEncoder.setTexture(frame.texture, index: 0)
        computeEncoder.setTexture(presentationTexture, index: 1)
        computeEncoder.setTexture(colormapTexture, index: 2)
        computeEncoder.setBytes(&uniforms,
                                length: MemoryLayout<MPRPresentationUniforms>.stride,
                                index: 0)

        let dispatch = ThreadgroupDispatchConfiguration.default(for: pipeline)
        let threadsPerGrid = MTLSize(width: frame.texture.width,
                                     height: frame.texture.height,
                                     depth: 1)
        if FeatureFlags.evaluate(for: device).contains(.nonUniformThreadgroups) {
            computeEncoder.dispatchThreads(threadsPerGrid,
                                           threadsPerThreadgroup: dispatch.threadsPerThreadgroup)
        } else {
            let groups = MTLSize(
                width: (threadsPerGrid.width + dispatch.threadsPerThreadgroup.width - 1) / dispatch.threadsPerThreadgroup.width,
                height: (threadsPerGrid.height + dispatch.threadsPerThreadgroup.height - 1) / dispatch.threadsPerThreadgroup.height,
                depth: 1
            )
            computeEncoder.dispatchThreadgroups(groups,
                                                threadsPerThreadgroup: dispatch.threadsPerThreadgroup)
        }
        computeEncoder.endEncoding()

        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw MPRPresentationPassError.encoderCreationFailed
        }
        blitEncoder.label = "mpr_presentation_blit"
        blitEncoder.copy(from: presentationTexture,
                         sourceSlice: 0,
                         sourceLevel: 0,
                         sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                         sourceSize: MTLSize(width: presentationTexture.width,
                                             height: presentationTexture.height,
                                             depth: 1),
                         to: drawable.texture,
                         destinationSlice: 0,
                         destinationLevel: 0,
                         destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blitEncoder.endEncoding()

        commandBuffer.present(drawable)
        CommandBufferProfiler.captureTimes(for: commandBuffer,
                                           label: "mpr_present",
                                           category: "Benchmark")
        let profilerDevice = device
        let presentationMemoryEstimate = ResourceMemoryEstimator.estimate(for: presentationTexture)
        commandBuffer.addCompletedHandler { buffer in
            guard buffer.error == nil, buffer.status == .completed else {
                onCommandBufferFailure?(
                    MPRPresentationCommandBufferError.commandBufferFailed(
                        status: Int(buffer.status.rawValue),
                        description: buffer.error?.localizedDescription
                    )
                )
                return
            }
            let timing = buffer.timings(cpuStart: startedAt,
                                        cpuEnd: CFAbsoluteTimeGetCurrent())
            ClinicalProfiler.shared.recordSample(
                stage: .presentationPass,
                cpuTime: timing.cpuTime,
                gpuTime: timing.gpuTime > 0 ? timing.gpuTime : nil,
                memory: presentationMemoryEstimate,
                viewport: ProfilingViewportContext(
                    resolutionWidth: drawable.texture.width,
                    resolutionHeight: drawable.texture.height,
                    viewportType: "mpr",
                    quality: "unknown",
                    renderMode: "mprPresentation"
                ),
                metadata: [
                    "cpuPresentTimeMilliseconds": String(format: "%.6f", timing.cpuTime),
                    "gpuPresentTimeMilliseconds": timing.gpuTime > 0 ? String(format: "%.6f", timing.gpuTime) : "unavailable",
                    "kernelTimeMilliseconds": String(format: "%.6f", timing.kernelTime),
                    "sourceTextureSize": "\(frame.texture.width)x\(frame.texture.height)",
                    "drawableWidth": "\(drawable.texture.width)",
                    "drawableHeight": "\(drawable.texture.height)",
                    "drawableSize": "\(drawable.texture.width)x\(drawable.texture.height)",
                    "sourcePixelFormat": "\(frame.texture.pixelFormat)",
                    "drawablePixelFormat": "\(drawable.texture.pixelFormat)",
                    "voiLUTApplied": colormap == nil ? "false" : "true",
                    "monochrome": invert ? "MONOCHROME1" : "MONOCHROME2",
                    "flipHorizontal": flipHorizontal ? "true" : "false",
                    "flipVertical": flipVertical ? "true" : "false"
                ],
                device: profilerDevice
            )
        }
        commandBuffer.commit()
        return CFAbsoluteTimeGetCurrent() - startedAt
    }

    @discardableResult
    public mutating func present(frame: MPRTextureFrame,
                                 preset: WindowLevelPreset,
                                 to drawable: any CAMetalDrawable,
                                 transform: MPRDisplayTransform,
                                 invert: Bool = false,
                                 colormap: (any MTLTexture)? = nil,
                                 bitShift: Int32 = 0,
                                 onCommandBufferFailure: ((MPRPresentationCommandBufferError) -> Void)? = nil) throws -> CFAbsoluteTime {
        try presentImpl(frame: frame,
                        window: Self.windowRange(for: preset),
                        to: drawable,
                        invert: invert,
                        colormap: colormap,
                        flipHorizontal: transform.presentationFlipHorizontal,
                        flipVertical: transform.presentationFlipVertical,
                        bitShift: bitShift,
                        onCommandBufferFailure: onCommandBufferFailure)
    }

    @discardableResult
    public mutating func present(frame: MPRTextureFrame,
                                 preset: WindowLevelPreset,
                                 to drawable: any CAMetalDrawable,
                                 invert: Bool = false,
                                 colormap: (any MTLTexture)? = nil,
                                 flipHorizontal: Bool = false,
                                 flipVertical: Bool = false,
                                 bitShift: Int32 = 0,
                                 onCommandBufferFailure: ((MPRPresentationCommandBufferError) -> Void)? = nil) throws -> CFAbsoluteTime {
        try presentImpl(frame: frame,
                        window: Self.windowRange(for: preset),
                        to: drawable,
                        invert: invert,
                        colormap: colormap,
                        flipHorizontal: flipHorizontal,
                        flipVertical: flipVertical,
                        bitShift: bitShift,
                        onCommandBufferFailure: onCommandBufferFailure)
    }

    public static func windowRange(for preset: WindowLevelPreset) -> ClosedRange<Int32> {
        preset.windowRange
    }

    private mutating func pipelineState(for pixelFormat: VolumePixelFormat) throws -> MTLComputePipelineState {
        let functionName: String
        switch pixelFormat {
        case .int16Signed:
            functionName = "mprPresentation"
        case .int16Unsigned:
            functionName = "mprPresentationUnsigned"
        }

        if let cached = cachedPipelineState(named: functionName) {
            return cached
        }

        guard let function = library.makeFunction(name: functionName) else {
            throw MPRPresentationPassError.pipelineUnavailable(functionName)
        }
        function.label = functionName

        do {
            let pipeline = try device.makeComputePipelineState(function: function)
            return storePipelineStateIfNeeded(pipeline,
                                              named: functionName)
        } catch {
            throw MPRPresentationPassError.pipelineUnavailableWithError(functionName: functionName,
                                                                        underlyingError: error)
        }
    }

    private func cachedPipelineState(named functionName: String) -> MTLComputePipelineState? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return pipelineCache[functionName]
    }

    private mutating func storePipelineStateIfNeeded(_ pipeline: MTLComputePipelineState,
                                                     named functionName: String) -> MTLComputePipelineState {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = pipelineCache[functionName] {
            return cached
        }
        pipelineCache[functionName] = pipeline
        return pipeline
    }

    private mutating func reusablePresentationTexture(width: Int,
                                                      height: Int) throws -> any MTLTexture {
        if let cachedPresentationTexture = cachedPresentationTexture(width: width,
                                                                     height: height) {
            return cachedPresentationTexture
        }

        let texture = try makePresentationTexture(width: width,
                                                  height: height)
        return storePresentationTextureIfNeeded(texture,
                                                width: width,
                                                height: height)
    }

    private func cachedPresentationTexture(width: Int,
                                           height: Int) -> (any MTLTexture)? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let cachedPresentationTexture,
              isReusablePresentationTexture(cachedPresentationTexture,
                                            width: width,
                                            height: height) else {
            return nil
        }
        return cachedPresentationTexture
    }

    private mutating func storePresentationTextureIfNeeded(_ texture: any MTLTexture,
                                                           width: Int,
                                                           height: Int) -> any MTLTexture {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedPresentationTexture,
           isReusablePresentationTexture(cachedPresentationTexture,
                                         width: width,
                                         height: height) {
            return cachedPresentationTexture
        }
        cachedPresentationTexture = texture
        return texture
    }

    private func isReusablePresentationTexture(_ texture: any MTLTexture,
                                               width: Int,
                                               height: Int) -> Bool {
        texture.device === device
            && texture.width == width
            && texture.height == height
            && texture.pixelFormat == .bgra8Unorm
            && texture.storageMode == .private
            && texture.usage.contains(.shaderWrite)
            && texture.usage.contains(.shaderRead)
    }

    private func makePresentationTexture(width: Int,
                                         height: Int) throws -> any MTLTexture {
        // StorageModePolicy.md: presentation targets are GPU-only and private.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MPRPresentationPassError.presentationTextureCreationFailed
        }
        texture.label = "MPR.presentationTexture"
        return texture
    }

    private mutating func reusableFallbackColormapTexture() throws -> any MTLTexture {
        if let fallbackColormapTexture = cachedFallbackColormapTexture() {
            return fallbackColormapTexture
        }

        // StorageModePolicy.md: fallback colormap is a tiny CPU-authored lookup texture.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                                                                  width: 1,
                                                                  height: 1,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MPRPresentationPassError.fallbackColormapCreationFailed
        }
        texture.label = "MPR.fallbackColormap"
        var color = SIMD4<Float>(1, 1, 1, 1)
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                        mipmapLevel: 0,
                        withBytes: &color,
                        bytesPerRow: MemoryLayout<SIMD4<Float>>.stride)
        return storeFallbackColormapTextureIfNeeded(texture)
    }

    private func cachedFallbackColormapTexture() -> (any MTLTexture)? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let fallbackColormapTexture,
              fallbackColormapTexture.device === device,
              fallbackColormapTexture.width == 1,
              fallbackColormapTexture.height == 1,
              fallbackColormapTexture.pixelFormat == .rgba32Float else {
            return nil
        }
        return fallbackColormapTexture
    }

    private mutating func storeFallbackColormapTextureIfNeeded(_ texture: any MTLTexture) -> any MTLTexture {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let fallbackColormapTexture,
           fallbackColormapTexture.device === device,
           fallbackColormapTexture.width == 1,
           fallbackColormapTexture.height == 1,
           fallbackColormapTexture.pixelFormat == .rgba32Float {
            return fallbackColormapTexture
        }
        fallbackColormapTexture = texture
        return texture
    }

    private func validate(frame: MPRTextureFrame,
                          drawableTexture: any MTLTexture,
                          colormap: (any MTLTexture)?) throws {
        guard frame.texture.device === device,
              drawableTexture.device === device else {
            throw MPRPresentationPassError.drawableDeviceMismatch(
                sourceDevice: frame.texture.device.name,
                drawableDevice: drawableTexture.device.name
            )
        }

        if let colormap,
           colormap.device !== device {
            throw MPRPresentationPassError.colormapDeviceMismatch
        }

        guard drawableTexture.pixelFormat == .bgra8Unorm else {
            throw MPRPresentationPassError.drawablePixelFormatUnsupported(drawableTexture.pixelFormat)
        }

        let expectedFormat = frame.pixelFormat.rawIntensityMetalPixelFormat
        guard frame.texture.pixelFormat == expectedFormat else {
            throw MPRPresentationPassError.frameTextureFormatMismatch(expected: expectedFormat,
                                                                      actual: frame.texture.pixelFormat)
        }

        guard frame.texture.width == drawableTexture.width,
              frame.texture.height == drawableTexture.height else {
            throw MPRPresentationPassError.sizeMismatch(
                source: CGSize(width: frame.texture.width, height: frame.texture.height),
                drawable: CGSize(width: drawableTexture.width, height: drawableTexture.height)
            )
        }
    }
}

extension MPRPresentationPass: @unchecked Sendable {}
