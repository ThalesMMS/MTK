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
import simd

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
    case overlayTextureDeviceMismatch
    case overlayLabelmapPixelFormatMismatch(MTLPixelFormat)
    case overlayScalarPixelFormatMismatch(expected: MTLPixelFormat, actual: MTLPixelFormat)
    case overlayColorLUTPixelFormatMismatch(MTLPixelFormat)
    case overlayTextureCreationFailed

    public static func == (lhs: MPRPresentationPassError, rhs: MPRPresentationPassError) -> Bool {
        switch (lhs, rhs) {
        case (.commandQueueDeviceMismatch, .commandQueueDeviceMismatch),
             (.shaderLibraryDeviceMismatch, .shaderLibraryDeviceMismatch),
             (.commandBufferCreationFailed, .commandBufferCreationFailed),
             (.encoderCreationFailed, .encoderCreationFailed),
             (.presentationTextureCreationFailed, .presentationTextureCreationFailed),
             (.colormapDeviceMismatch, .colormapDeviceMismatch),
             (.fallbackColormapCreationFailed, .fallbackColormapCreationFailed),
             (.overlayTextureDeviceMismatch, .overlayTextureDeviceMismatch),
             (.overlayTextureCreationFailed, .overlayTextureCreationFailed):
            return true
        case let (.drawableDeviceMismatch(lhsSource, lhsDrawable), .drawableDeviceMismatch(rhsSource, rhsDrawable)):
            return lhsSource == rhsSource && lhsDrawable == rhsDrawable
        case let (.drawablePixelFormatUnsupported(lhsFormat), .drawablePixelFormatUnsupported(rhsFormat)):
            return lhsFormat == rhsFormat
        case let (.frameTextureFormatMismatch(lhsExpected, lhsActual), .frameTextureFormatMismatch(rhsExpected, rhsActual)):
            return lhsExpected == rhsExpected && lhsActual == rhsActual
        case let (.overlayLabelmapPixelFormatMismatch(lhsFormat), .overlayLabelmapPixelFormatMismatch(rhsFormat)):
            return lhsFormat == rhsFormat
        case let (
            .overlayScalarPixelFormatMismatch(lhsExpected, lhsActual),
            .overlayScalarPixelFormatMismatch(rhsExpected, rhsActual)
        ):
            return lhsExpected == rhsExpected && lhsActual == rhsActual
        case let (.overlayColorLUTPixelFormatMismatch(lhsFormat), .overlayColorLUTPixelFormatMismatch(rhsFormat)):
            return lhsFormat == rhsFormat
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
        case .overlayTextureDeviceMismatch:
            return "MPR labelmap overlay textures belong to a different Metal device."
        case let .overlayLabelmapPixelFormatMismatch(pixelFormat):
            return "MPR labelmap overlay requires r16Uint label textures, got \(pixelFormat)."
        case let .overlayScalarPixelFormatMismatch(expected, actual):
            return "MPR scalar overlay requires \(expected) textures, got \(actual)."
        case let .overlayColorLUTPixelFormatMismatch(pixelFormat):
            return "MPR overlay requires rgba32Float LUT textures, got \(pixelFormat)."
        case .overlayTextureCreationFailed:
            return "Failed to create the intermediate MPR labelmap overlay texture."
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
    private var cachedOverlayTexture: (any MTLTexture)?
    private var cachedAlternateOverlayTexture: (any MTLTexture)?
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
        var viewportZoom: Float
        var viewportPanX: Float
        var viewportPanY: Float
        var viewportRotationCos: Float
        var viewportRotationSin: Float
        var _pad1: Float
        var _pad2: Float
        var _pad3: Float
        var imageOriginX: Float
        var imageOriginY: Float
        var imageWidth: Float
        var imageHeight: Float
        var shutterMode: Int32
        var _pad4: Int32
        var _pad5: Int32
        var _pad6: Int32
        var shutterMinX: Float
        var shutterMinY: Float
        var shutterMaxX: Float
        var shutterMaxY: Float
        var shutterCenterX: Float
        var shutterCenterY: Float
        var shutterRadius: Float
        var _pad7: Float
    }

    private struct MPRLabelmapOverlayUniforms {
        var opacity: Float
        var _pad0: SIMD3<Float>
        var originTexture: SIMD3<Float>
        var _pad1: Float
        var axisUTexture: SIMD3<Float>
        var _pad2: Float
        var axisVTexture: SIMD3<Float>
        var _pad3: Float
        var flipHorizontal: Int32
        var flipVertical: Int32
        var viewportZoom: Float
        var viewportPanX: Float
        var viewportPanY: Float
        var viewportRotationCos: Float
        var viewportRotationSin: Float
        var _pad4: Float
        var _pad5: Float
        var _pad6: Float
        var imageOriginX: Float
        var imageOriginY: Float
        var imageWidth: Float
        var imageHeight: Float
    }

    private struct MPRScalarOverlayUniforms {
        var opacity: Float
        var intensityMin: Float
        var intensityMax: Float
        var blendMode: Int32
        var originTexture: SIMD3<Float>
        var _pad0: Float
        var axisUTexture: SIMD3<Float>
        var _pad1: Float
        var axisVTexture: SIMD3<Float>
        var _pad2: Float
        var flipHorizontal: Int32
        var flipVertical: Int32
        var viewportZoom: Float
        var viewportPanX: Float
        var viewportPanY: Float
        var viewportRotationCos: Float
        var viewportRotationSin: Float
        var _pad3: Float
        var _pad4: Float
        var _pad5: Float
        var imageOriginX: Float
        var imageOriginY: Float
        var imageWidth: Float
        var imageHeight: Float
    }

    private struct EncodedPresentation {
        let commandBuffer: any MTLCommandBuffer
        let outputTexture: any MTLTexture
        let startedAt: CFAbsoluteTime
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
                                 viewportTransform: MPRViewportTransform = .identity,
                                 labelmapOverlays: [MPRLabelmapOverlay] = [],
                                 scalarOverlays: [MPRScalarVolumeOverlay] = [],
                                 shutter: MPRPresentationShutter? = nil,
                                 onCommandBufferFailure: ((MPRPresentationCommandBufferError) -> Void)? = nil,
                                 onCommandBufferCompleted: (() -> Void)? = nil) throws -> CFAbsoluteTime {
        try presentImpl(frame: frame,
                        window: window,
                        to: drawable,
                        invert: invert,
                        colormap: colormap,
                        flipHorizontal: transform.presentationFlipHorizontal,
                        flipVertical: transform.presentationFlipVertical,
                        bitShift: bitShift,
                        viewportTransform: viewportTransform,
                        labelmapOverlays: labelmapOverlays,
                        scalarOverlays: scalarOverlays,
                        shutter: shutter,
                        onCommandBufferFailure: onCommandBufferFailure,
                        onCommandBufferCompleted: onCommandBufferCompleted)
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
                                 viewportTransform: MPRViewportTransform = .identity,
                                 labelmapOverlays: [MPRLabelmapOverlay] = [],
                                 scalarOverlays: [MPRScalarVolumeOverlay] = [],
                                 shutter: MPRPresentationShutter? = nil,
                                 onCommandBufferFailure: ((MPRPresentationCommandBufferError) -> Void)? = nil,
                                 onCommandBufferCompleted: (() -> Void)? = nil) throws -> CFAbsoluteTime {
        try presentImpl(frame: frame,
                        window: window,
                        to: drawable,
                        invert: invert,
                        colormap: colormap,
                        flipHorizontal: flipHorizontal,
                        flipVertical: flipVertical,
                        bitShift: bitShift,
                        viewportTransform: viewportTransform,
                        labelmapOverlays: labelmapOverlays,
                        scalarOverlays: scalarOverlays,
                        shutter: shutter,
                        onCommandBufferFailure: onCommandBufferFailure,
                        onCommandBufferCompleted: onCommandBufferCompleted)
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
                                      viewportTransform: MPRViewportTransform,
                                      labelmapOverlays: [MPRLabelmapOverlay],
                                      scalarOverlays: [MPRScalarVolumeOverlay],
                                      shutter: MPRPresentationShutter?,
                                      onCommandBufferFailure: ((MPRPresentationCommandBufferError) -> Void)?,
                                      onCommandBufferCompleted: (() -> Void)?) throws -> CFAbsoluteTime {
        let encoded = try encodePresentation(frame: frame,
                                             window: window,
                                             outputTexture: drawable.texture,
                                             invert: invert,
                                             colormap: colormap,
                                             flipHorizontal: flipHorizontal,
                                             flipVertical: flipVertical,
                                             bitShift: bitShift,
                                             viewportTransform: viewportTransform,
                                             labelmapOverlays: labelmapOverlays,
                                             scalarOverlays: scalarOverlays,
                                             shutter: shutter)
        let commandBuffer = encoded.commandBuffer
        let drawableWidth = drawable.texture.width
        let drawableHeight = drawable.texture.height
        commandBuffer.present(drawable)
        if Logger.performanceLoggingEnabled {
            CommandBufferProfiler.captureTimes(for: commandBuffer,
                                               label: "mpr_present",
                                               category: "Benchmark")
        }
        let profilerDevice = device
        let presentationMemoryEstimate = ResourceMemoryEstimator.estimate(for: encoded.outputTexture)
        let drawablePixelFormat = drawable.texture.pixelFormat
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
            if ClinicalProfiler.shared.isRecordingEnabled {
                let timing = buffer.timings(cpuStart: encoded.startedAt,
                                            cpuEnd: CFAbsoluteTimeGetCurrent())
                ClinicalProfiler.shared.recordSample(
                    stage: .presentationPass,
                    cpuTime: timing.cpuTime,
                    gpuTime: timing.gpuTime > 0 ? timing.gpuTime : nil,
                    memory: presentationMemoryEstimate,
                    viewport: ProfilingViewportContext(
                        resolutionWidth: drawableWidth,
                        resolutionHeight: drawableHeight,
                        viewportType: "mpr",
                        quality: "unknown",
                        renderMode: "mprPresentation"
                    ),
                    metadata: [
                        "cpuPresentTimeMilliseconds": String(format: "%.6f", timing.cpuTime),
                        "gpuPresentTimeMilliseconds": timing.gpuTime > 0
                            ? String(format: "%.6f", timing.gpuTime)
                            : "unavailable",
                        "kernelTimeMilliseconds": String(format: "%.6f", timing.kernelTime),
                        "sourceTextureSize": "\(frame.texture.width)x\(frame.texture.height)",
                        "drawableWidth": "\(drawableWidth)",
                        "drawableHeight": "\(drawableHeight)",
                        "drawableSize": "\(drawableWidth)x\(drawableHeight)",
                        "sourcePixelFormat": "\(frame.texture.pixelFormat)",
                        "drawablePixelFormat": "\(drawablePixelFormat)",
                        "voiLUTApplied": colormap == nil ? "false" : "true",
                        "labelmapOverlayCount": "\(labelmapOverlays.count)",
                        "scalarOverlayCount": "\(scalarOverlays.count)",
                        "presentationShutter": shutter == nil ? "false" : "true",
                        "monochrome": invert ? "MONOCHROME1" : "MONOCHROME2",
                        "flipHorizontal": flipHorizontal ? "true" : "false",
                        "flipVertical": flipVertical ? "true" : "false",
                        "viewportZoom": String(format: "%.6f", viewportTransform.zoom),
                        "viewportPanX": String(format: "%.6f", viewportTransform.pan.x),
                        "viewportPanY": String(format: "%.6f", viewportTransform.pan.y)
                    ],
                    device: profilerDevice
                )
            }
            onCommandBufferCompleted?()
        }
        commandBuffer.commit()
        return CFAbsoluteTimeGetCurrent() - encoded.startedAt
    }

    public mutating func makeSnapshotTexture(frame: MPRTextureFrame,
                                             window: ClosedRange<Int32>,
                                             transform: MPRDisplayTransform,
                                             width: Int,
                                             height: Int,
                                             invert: Bool = false,
                                             colormap: (any MTLTexture)? = nil,
                                             bitShift: Int32 = 0,
                                             viewportTransform: MPRViewportTransform = .identity,
                                             labelmapOverlays: [MPRLabelmapOverlay] = [],
                                             scalarOverlays: [MPRScalarVolumeOverlay] = [],
                                             shutter: MPRPresentationShutter? = nil) throws -> any MTLTexture {
        let outputTexture = try makePresentationTexture(width: max(1, width),
                                                        height: max(1, height),
                                                        label: "MPR.snapshotTexture")
        let encoded = try encodePresentation(frame: frame,
                                             window: window,
                                             outputTexture: outputTexture,
                                             invert: invert,
                                             colormap: colormap,
                                             flipHorizontal: transform.presentationFlipHorizontal,
                                             flipVertical: transform.presentationFlipVertical,
                                             bitShift: bitShift,
                                             viewportTransform: viewportTransform,
                                             labelmapOverlays: labelmapOverlays,
                                             scalarOverlays: scalarOverlays,
                                             shutter: shutter)
        encoded.commandBuffer.commit()
        encoded.commandBuffer.waitUntilCompleted()
        guard encoded.commandBuffer.error == nil,
              encoded.commandBuffer.status == .completed else {
            throw MPRPresentationCommandBufferError.commandBufferFailed(
                status: Int(encoded.commandBuffer.status.rawValue),
                description: encoded.commandBuffer.error?.localizedDescription
            )
        }
        return outputTexture
    }

    private mutating func encodePresentation(frame: MPRTextureFrame,
                                             window: ClosedRange<Int32>,
                                             outputTexture: any MTLTexture,
                                             invert: Bool,
                                             colormap: (any MTLTexture)?,
                                             flipHorizontal: Bool,
                                             flipVertical: Bool,
                                             bitShift: Int32,
                                             viewportTransform: MPRViewportTransform,
                                             labelmapOverlays: [MPRLabelmapOverlay],
                                             scalarOverlays: [MPRScalarVolumeOverlay],
                                             shutter: MPRPresentationShutter?) throws -> EncodedPresentation {
        assert(
            Thread.isMainThread,
            "MPRPresentationPass uses pipelineCache and cachedPresentationTexture; " +
                "use it from the MainActor or another single-threaded context."
        )
        let startedAt = CFAbsoluteTimeGetCurrent()
        try validate(frame: frame,
                     drawableTexture: outputTexture,
                     colormap: colormap,
                     labelmapOverlays: labelmapOverlays,
                     scalarOverlays: scalarOverlays)

        let outputWidth = outputTexture.width
        let outputHeight = outputTexture.height
        let layout = MPRPresentationLayout.aspectFit(contentAspectRatio: frame.planeGeometry.physicalAspectRatio,
                                                     destinationWidth: outputWidth,
                                                     destinationHeight: outputHeight)
        let presentationTexture = try reusablePresentationTexture(width: outputWidth,
                                                                  height: outputHeight)
        let colormapTexture = try colormap ?? reusableFallbackColormapTexture()
        let pipeline = try pipelineState(for: frame.pixelFormat)
        let shutterUniforms = Self.shutterUniformValues(for: shutter)
        var uniforms = MPRPresentationUniforms(
            windowMin: window.lowerBound,
            windowMax: window.upperBound,
            invert: invert ? 1 : 0,
            useColormap: colormap == nil ? 0 : 1,
            flipHorizontal: flipHorizontal ? 1 : 0,
            flipVertical: flipVertical ? 1 : 0,
            bitShift: max(0, min(bitShift, 15)),
            _pad0: 0,
            viewportZoom: viewportTransform.zoom,
            viewportPanX: viewportTransform.pan.x,
            viewportPanY: viewportTransform.pan.y,
            viewportRotationCos: cos(viewportTransform.rotationRadians),
            viewportRotationSin: sin(viewportTransform.rotationRadians),
            _pad1: 0,
            _pad2: 0,
            _pad3: 0,
            imageOriginX: layout.origin.x,
            imageOriginY: layout.origin.y,
            imageWidth: layout.size.x,
            imageHeight: layout.size.y,
            shutterMode: shutterUniforms.mode,
            _pad4: 0,
            _pad5: 0,
            _pad6: 0,
            shutterMinX: shutterUniforms.min.x,
            shutterMinY: shutterUniforms.min.y,
            shutterMaxX: shutterUniforms.max.x,
            shutterMaxY: shutterUniforms.max.y,
            shutterCenterX: shutterUniforms.center.x,
            shutterCenterY: shutterUniforms.center.y,
            shutterRadius: shutterUniforms.radius,
            _pad7: 0
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
        let presentationThreadsPerGrid = MTLSize(width: presentationTexture.width,
                                                 height: presentationTexture.height,
                                                 depth: 1)
        MetalDispatch.dispatch(encoder: computeEncoder,
                               threadsPerGrid: presentationThreadsPerGrid,
                               configuration: dispatch,
                               featureFlags: FeatureFlags.evaluate(for: device))
        computeEncoder.endEncoding()

        let scalarCompositedTexture = try encodeScalarOverlays(scalarOverlays,
                                                               initialTexture: presentationTexture,
                                                               commandBuffer: commandBuffer,
                                                               width: presentationTexture.width,
                                                               height: presentationTexture.height,
                                                               flipHorizontal: flipHorizontal,
                                                               flipVertical: flipVertical,
                                                               layout: layout,
                                                               viewportTransform: viewportTransform)
        let finalPresentationTexture = try encodeLabelmapOverlays(labelmapOverlays,
                                                                  initialTexture: scalarCompositedTexture,
                                                                  commandBuffer: commandBuffer,
                                                                  width: presentationTexture.width,
                                                                  height: presentationTexture.height,
                                                                  flipHorizontal: flipHorizontal,
                                                                  flipVertical: flipVertical,
                                                                  layout: layout,
                                                                  viewportTransform: viewportTransform)

        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw MPRPresentationPassError.encoderCreationFailed
        }
        blitEncoder.label = "mpr_presentation_blit"
        blitEncoder.copy(from: finalPresentationTexture,
                         sourceSlice: 0,
                         sourceLevel: 0,
                         sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                         sourceSize: MTLSize(width: finalPresentationTexture.width,
                                             height: finalPresentationTexture.height,
                                             depth: 1),
                         to: outputTexture,
                         destinationSlice: 0,
                         destinationLevel: 0,
                         destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blitEncoder.endEncoding()

        return EncodedPresentation(commandBuffer: commandBuffer,
                                   outputTexture: outputTexture,
                                   startedAt: startedAt)
    }

    @discardableResult
    public mutating func present(frame: MPRTextureFrame,
                                 preset: WindowLevelPreset,
                                 to drawable: any CAMetalDrawable,
                                 transform: MPRDisplayTransform,
                                 invert: Bool = false,
                                 colormap: (any MTLTexture)? = nil,
                                 bitShift: Int32 = 0,
                                 viewportTransform: MPRViewportTransform = .identity,
                                 labelmapOverlays: [MPRLabelmapOverlay] = [],
                                 scalarOverlays: [MPRScalarVolumeOverlay] = [],
                                 shutter: MPRPresentationShutter? = nil,
                                 onCommandBufferFailure: ((MPRPresentationCommandBufferError) -> Void)? = nil,
                                 onCommandBufferCompleted: (() -> Void)? = nil) throws -> CFAbsoluteTime {
        try presentImpl(frame: frame,
                        window: Self.windowRange(for: preset),
                        to: drawable,
                        invert: invert,
                        colormap: colormap,
                        flipHorizontal: transform.presentationFlipHorizontal,
                        flipVertical: transform.presentationFlipVertical,
                        bitShift: bitShift,
                        viewportTransform: viewportTransform,
                        labelmapOverlays: labelmapOverlays,
                        scalarOverlays: scalarOverlays,
                        shutter: shutter,
                        onCommandBufferFailure: onCommandBufferFailure,
                        onCommandBufferCompleted: onCommandBufferCompleted)
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
                                 viewportTransform: MPRViewportTransform = .identity,
                                 labelmapOverlays: [MPRLabelmapOverlay] = [],
                                 scalarOverlays: [MPRScalarVolumeOverlay] = [],
                                 shutter: MPRPresentationShutter? = nil,
                                 onCommandBufferFailure: ((MPRPresentationCommandBufferError) -> Void)? = nil,
                                 onCommandBufferCompleted: (() -> Void)? = nil) throws -> CFAbsoluteTime {
        try presentImpl(frame: frame,
                        window: Self.windowRange(for: preset),
                        to: drawable,
                        invert: invert,
                        colormap: colormap,
                        flipHorizontal: flipHorizontal,
                        flipVertical: flipVertical,
                        bitShift: bitShift,
                        viewportTransform: viewportTransform,
                        labelmapOverlays: labelmapOverlays,
                        scalarOverlays: scalarOverlays,
                        shutter: shutter,
                        onCommandBufferFailure: onCommandBufferFailure,
                        onCommandBufferCompleted: onCommandBufferCompleted)
    }

    public static func windowRange(for preset: WindowLevelPreset) -> ClosedRange<Int32> {
        preset.windowRange
    }

    private static func shutterUniformValues(
        for shutter: MPRPresentationShutter?
    ) -> (mode: Int32, min: SIMD2<Float>, max: SIMD2<Float>, center: SIMD2<Float>, radius: Float) {
        switch shutter {
        case let .rectangular(min, max):
            return (
                mode: 1,
                min: SIMD2<Float>(Swift.min(min.x, max.x), Swift.min(min.y, max.y)),
                max: SIMD2<Float>(Swift.max(min.x, max.x), Swift.max(min.y, max.y)),
                center: SIMD2<Float>(repeating: 0),
                radius: 0
            )
        case let .circular(center, radius):
            return (
                mode: 2,
                min: SIMD2<Float>(repeating: 0),
                max: SIMD2<Float>(repeating: 1),
                center: center,
                radius: max(radius.isFinite ? radius : 0, 0)
            )
        case nil:
            return (
                mode: 0,
                min: SIMD2<Float>(repeating: 0),
                max: SIMD2<Float>(repeating: 1),
                center: SIMD2<Float>(repeating: 0),
                radius: 0
            )
        }
    }

    private mutating func pipelineState(for pixelFormat: VolumePixelFormat) throws -> MTLComputePipelineState {
        let functionName: String
        switch pixelFormat {
        case .int16Signed:
            functionName = "mprPresentation"
        case .int16Unsigned:
            functionName = "mprPresentationUnsigned"
        }

        return try pipelineState(named: functionName)
    }

    private mutating func overlayPipelineState() throws -> MTLComputePipelineState {
        try pipelineState(named: "mprCompositeLabelmapOverlay")
    }

    private mutating func scalarOverlayPipelineState(for pixelFormat: VolumePixelFormat) throws -> MTLComputePipelineState {
        switch pixelFormat {
        case .int16Signed:
            return try pipelineState(named: "mprCompositeScalarOverlay")
        case .int16Unsigned:
            return try pipelineState(named: "mprCompositeScalarOverlayUnsigned")
        }
    }

    private mutating func pipelineState(named functionName: String) throws -> MTLComputePipelineState {
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

    private mutating func encodeScalarOverlays(_ overlays: [MPRScalarVolumeOverlay],
                                               initialTexture: any MTLTexture,
                                               commandBuffer: any MTLCommandBuffer,
                                               width: Int,
                                               height: Int,
                                               flipHorizontal: Bool,
                                               flipVertical: Bool,
                                               layout: MPRPresentationLayout,
                                               viewportTransform: MPRViewportTransform) throws -> any MTLTexture {
        guard overlays.isEmpty == false else { return initialTexture }

        let overlayTexture = try reusableOverlayTexture(width: width,
                                                        height: height,
                                                        avoiding: initialTexture)
        var sourceTexture: any MTLTexture = initialTexture
        var destinationTexture: any MTLTexture = overlayTexture

        for (index, overlay) in overlays.enumerated() {
            let pipeline = try scalarOverlayPipelineState(for: overlay.pixelFormat)
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw MPRPresentationPassError.encoderCreationFailed
            }
            encoder.label = "mpr_scalar_overlay_\(index)"
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(sourceTexture, index: 0)
            encoder.setTexture(destinationTexture, index: 1)
            encoder.setTexture(overlay.scalarTexture, index: 2)
            encoder.setTexture(overlay.colorLUTTexture, index: 3)

            var uniforms = MPRScalarOverlayUniforms(
                opacity: max(0, min(overlay.opacity.isFinite ? overlay.opacity : 0, 1)),
                intensityMin: Float(overlay.intensityRange.lowerBound),
                intensityMax: Float(overlay.intensityRange.upperBound),
                blendMode: overlay.blendMode == .additive ? 1 : 0,
                originTexture: overlay.originTexture,
                _pad0: 0,
                axisUTexture: overlay.axisUTexture,
                _pad1: 0,
                axisVTexture: overlay.axisVTexture,
                _pad2: 0,
                flipHorizontal: flipHorizontal ? 1 : 0,
                flipVertical: flipVertical ? 1 : 0,
                viewportZoom: viewportTransform.zoom,
                viewportPanX: viewportTransform.pan.x,
                viewportPanY: viewportTransform.pan.y,
                viewportRotationCos: cos(viewportTransform.rotationRadians),
                viewportRotationSin: sin(viewportTransform.rotationRadians),
                _pad3: 0,
                _pad4: 0,
                _pad5: 0,
                imageOriginX: layout.origin.x,
                imageOriginY: layout.origin.y,
                imageWidth: layout.size.x,
                imageHeight: layout.size.y
            )
            encoder.setBytes(&uniforms,
                             length: MemoryLayout<MPRScalarOverlayUniforms>.stride,
                             index: 0)

            let dispatch = ThreadgroupDispatchConfiguration.default(for: pipeline)
            let threadsPerGrid = MTLSize(width: width,
                                         height: height,
                                         depth: 1)
            MetalDispatch.dispatch(encoder: encoder,
                                   threadsPerGrid: threadsPerGrid,
                                   configuration: dispatch,
                                   featureFlags: FeatureFlags.evaluate(for: device))
            encoder.endEncoding()

            if index < overlays.count - 1 {
                swap(&sourceTexture, &destinationTexture)
            }
        }

        return destinationTexture
    }

    private mutating func encodeLabelmapOverlays(_ overlays: [MPRLabelmapOverlay],
                                                 initialTexture: any MTLTexture,
                                                 commandBuffer: any MTLCommandBuffer,
                                                 width: Int,
                                                 height: Int,
                                                 flipHorizontal: Bool,
                                                 flipVertical: Bool,
                                                 layout: MPRPresentationLayout,
                                                 viewportTransform: MPRViewportTransform) throws -> any MTLTexture {
        guard overlays.isEmpty == false else { return initialTexture }

        let overlayTexture = try reusableOverlayTexture(width: width,
                                                        height: height,
                                                        avoiding: initialTexture)
        var sourceTexture: any MTLTexture = initialTexture
        var destinationTexture: any MTLTexture = overlayTexture
        let pipeline = try overlayPipelineState()

        for (index, overlay) in overlays.enumerated() {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw MPRPresentationPassError.encoderCreationFailed
            }
            encoder.label = "mpr_labelmap_overlay_\(index)"
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(sourceTexture, index: 0)
            encoder.setTexture(destinationTexture, index: 1)
            encoder.setTexture(overlay.labelmapTexture, index: 2)
            encoder.setTexture(overlay.colorLUTTexture, index: 3)

            var uniforms = MPRLabelmapOverlayUniforms(
                opacity: max(0, min(overlay.opacity.isFinite ? overlay.opacity : 0, 1)),
                _pad0: SIMD3<Float>(0, 0, 0),
                originTexture: overlay.originTexture,
                _pad1: 0,
                axisUTexture: overlay.axisUTexture,
                _pad2: 0,
                axisVTexture: overlay.axisVTexture,
                _pad3: 0,
                flipHorizontal: flipHorizontal ? 1 : 0,
                flipVertical: flipVertical ? 1 : 0,
                viewportZoom: viewportTransform.zoom,
                viewportPanX: viewportTransform.pan.x,
                viewportPanY: viewportTransform.pan.y,
                viewportRotationCos: cos(viewportTransform.rotationRadians),
                viewportRotationSin: sin(viewportTransform.rotationRadians),
                _pad4: 0,
                _pad5: 0,
                _pad6: 0,
                imageOriginX: layout.origin.x,
                imageOriginY: layout.origin.y,
                imageWidth: layout.size.x,
                imageHeight: layout.size.y
            )
            encoder.setBytes(&uniforms,
                             length: MemoryLayout<MPRLabelmapOverlayUniforms>.stride,
                             index: 0)

            let dispatch = ThreadgroupDispatchConfiguration.default(for: pipeline)
            let threadsPerGrid = MTLSize(width: width,
                                         height: height,
                                         depth: 1)
            MetalDispatch.dispatch(encoder: encoder,
                                   threadsPerGrid: threadsPerGrid,
                                   configuration: dispatch,
                                   featureFlags: FeatureFlags.evaluate(for: device))
            encoder.endEncoding()

            if index < overlays.count - 1 {
                swap(&sourceTexture, &destinationTexture)
            }
        }

        return destinationTexture
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

    private mutating func reusableOverlayTexture(width: Int,
                                                 height: Int,
                                                 avoiding textureToAvoid: any MTLTexture) throws -> any MTLTexture {
        if let cachedOverlayTexture = cachedOverlayTexture(width: width,
                                                           height: height,
                                                           avoiding: textureToAvoid) {
            return cachedOverlayTexture
        }

        let texture = try makePresentationTexture(width: width,
                                                  height: height)
        texture.label = "MPR.overlayTexture"
        return storeOverlayTextureIfNeeded(texture,
                                           width: width,
                                           height: height,
                                           avoiding: textureToAvoid)
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

    private func cachedOverlayTexture(width: Int,
                                      height: Int,
                                      avoiding textureToAvoid: any MTLTexture) -> (any MTLTexture)? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedOverlayTexture,
           !sameTexture(cachedOverlayTexture, textureToAvoid),
           isReusablePresentationTexture(cachedOverlayTexture,
                                         width: width,
                                         height: height) {
            return cachedOverlayTexture
        }
        if let cachedAlternateOverlayTexture,
           !sameTexture(cachedAlternateOverlayTexture, textureToAvoid),
           isReusablePresentationTexture(cachedAlternateOverlayTexture,
                                         width: width,
                                         height: height) {
            return cachedAlternateOverlayTexture
        }
        return nil
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

    private mutating func storeOverlayTextureIfNeeded(_ texture: any MTLTexture,
                                                      width: Int,
                                                      height: Int,
                                                      avoiding textureToAvoid: any MTLTexture) -> any MTLTexture {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedOverlayTexture,
           !sameTexture(cachedOverlayTexture, textureToAvoid),
           isReusablePresentationTexture(cachedOverlayTexture,
                                         width: width,
                                         height: height) {
            return cachedOverlayTexture
        }
        if let cachedAlternateOverlayTexture,
           !sameTexture(cachedAlternateOverlayTexture, textureToAvoid),
           isReusablePresentationTexture(cachedAlternateOverlayTexture,
                                         width: width,
                                         height: height) {
            return cachedAlternateOverlayTexture
        }
        if cachedOverlayTexture == nil || cachedOverlayTexture.map({ sameTexture($0, textureToAvoid) }) == true {
            cachedOverlayTexture = texture
            return texture
        }
        cachedAlternateOverlayTexture = texture
        return texture
    }

    private func isReusablePresentationTexture(_ texture: any MTLTexture,
                                               width: Int,
                                               height: Int) -> Bool {
        OutputTextureFactory.matchesPrivateBGRAOutput(
            texture,
            width: width,
            height: height,
            device: device,
            requiredUsage: OutputTextureFactory.shaderUsage
        )
    }

    private func sameTexture(_ lhs: any MTLTexture, _ rhs: any MTLTexture) -> Bool {
        (lhs as AnyObject) === (rhs as AnyObject)
    }

    private func makePresentationTexture(width: Int,
                                         height: Int,
                                         label: String = "MPR.presentationTexture") throws -> any MTLTexture {
        // StorageModePolicy.md: presentation targets are GPU-only and private.
        guard let texture = OutputTextureFactory.makeTexture(
            device: device,
            width: width,
            height: height,
            label: label,
            usage: OutputTextureFactory.shaderUsage
        ) else {
            throw MPRPresentationPassError.presentationTextureCreationFailed
        }
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
                          colormap: (any MTLTexture)?,
                          labelmapOverlays: [MPRLabelmapOverlay],
                          scalarOverlays: [MPRScalarVolumeOverlay]) throws {
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

        for overlay in labelmapOverlays {
            guard overlay.labelmapTexture.device === device,
                  overlay.colorLUTTexture.device === device else {
                throw MPRPresentationPassError.overlayTextureDeviceMismatch
            }
            guard overlay.labelmapTexture.pixelFormat == .r16Uint else {
                throw MPRPresentationPassError.overlayLabelmapPixelFormatMismatch(overlay.labelmapTexture.pixelFormat)
            }
            guard overlay.colorLUTTexture.pixelFormat == .rgba32Float else {
                throw MPRPresentationPassError.overlayColorLUTPixelFormatMismatch(overlay.colorLUTTexture.pixelFormat)
            }
        }

        for overlay in scalarOverlays {
            guard overlay.scalarTexture.device === device,
                  overlay.colorLUTTexture.device === device else {
                throw MPRPresentationPassError.overlayTextureDeviceMismatch
            }
            let expectedPixelFormat = overlay.pixelFormat.rawIntensityMetalPixelFormat
            guard overlay.scalarTexture.pixelFormat == expectedPixelFormat else {
                throw MPRPresentationPassError.overlayScalarPixelFormatMismatch(
                    expected: expectedPixelFormat,
                    actual: overlay.scalarTexture.pixelFormat
                )
            }
            guard overlay.colorLUTTexture.pixelFormat == .rgba32Float else {
                throw MPRPresentationPassError.overlayColorLUTPixelFormatMismatch(overlay.colorLUTTexture.pixelFormat)
            }
        }

        guard drawableTexture.pixelFormat == .bgra8Unorm else {
            throw MPRPresentationPassError.drawablePixelFormatUnsupported(drawableTexture.pixelFormat)
        }

        let expectedFormat = frame.pixelFormat.rawIntensityMetalPixelFormat
        guard frame.texture.pixelFormat == expectedFormat else {
            throw MPRPresentationPassError.frameTextureFormatMismatch(expected: expectedFormat,
                                                                      actual: frame.texture.pixelFormat)
        }

        guard frame.texture.width > 0,
              frame.texture.height > 0,
              drawableTexture.width > 0,
              drawableTexture.height > 0 else {
            throw MPRPresentationPassError.sizeMismatch(
                source: CGSize(width: frame.texture.width, height: frame.texture.height),
                drawable: CGSize(width: drawableTexture.width, height: drawableTexture.height)
            )
        }
    }
}

extension MPRPresentationPass: @unchecked Sendable {}
