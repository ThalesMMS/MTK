//
//  PresentationPass.swift
//  MTKCore
//
//  Drawable presentation pass for Metal-native clinical viewports.
//

import CoreGraphics
import Foundation
import QuartzCore
@preconcurrency import Metal

public struct PresentationFrameMetadata: Sendable {
    public var requestedDrawableSize: CGSize
    public var viewportType: String
    public var quality: String
    public var renderMode: String
    public var renderGraphRoute: String?
    public var debugSource: String?
    public var debugPresentationToken: String?
    public var debugFrameIndex: UInt64?

    public init(requestedDrawableSize: CGSize,
                viewportType: String,
                quality: String,
                renderMode: String,
                renderGraphRoute: String? = nil,
                debugSource: String? = nil,
                debugPresentationToken: String? = nil,
                debugFrameIndex: UInt64? = nil) {
        self.requestedDrawableSize = requestedDrawableSize
        self.viewportType = viewportType
        self.quality = quality
        self.renderMode = renderMode
        self.renderGraphRoute = renderGraphRoute
        self.debugSource = debugSource
        self.debugPresentationToken = debugPresentationToken
        self.debugFrameIndex = debugFrameIndex
    }

    package init(frame: RenderFrame) {
        self.init(
            requestedDrawableSize: frame.metadata.viewportSize,
            viewportType: frame.route.viewportType.profilingName,
            quality: "unknown",
            renderMode: frame.route.presentationPass?.kind.profilingName ?? "presentation",
            renderGraphRoute: frame.route.profilingName
        )
    }

    public init(frame: VolumeRenderFrame) {
        self.init(
            requestedDrawableSize: frame.metadata.viewportSize,
            viewportType: "volume3D",
            quality: String(describing: frame.metadata.quality),
            renderMode: String(describing: frame.metadata.compositing),
            debugFrameIndex: frame.metadata.debugFrameIndex
        )
    }

    public static func textureOnly(size: CGSize) -> PresentationFrameMetadata {
        PresentationFrameMetadata(requestedDrawableSize: size,
                                  viewportType: "presentation",
                                  quality: "unknown",
                                  renderMode: "drawableBlit")
    }
}

/// Errors reported while presenting a completed GPU frame to a drawable.
public enum PresentationPassError: Error, Equatable, LocalizedError {
    case drawableUnavailable
    case sourceDrawableDeviceMismatch(sourceDevice: String, drawableDevice: String)
    case sourceQueueDeviceMismatch(sourceDevice: String, queueDevice: String)
    case pixelFormatMismatch(source: MTLPixelFormat, drawable: MTLPixelFormat)
    case sizeMismatch(source: CGSize, drawable: CGSize)
    case commandBufferCreationFailed
    case blitEncoderCreationFailed
    case renderPipelineCreationFailed(String)
    case renderEncoderCreationFailed

    public var errorDescription: String? {
        switch self {
        case .drawableUnavailable:
            return "No CAMetalDrawable is available for presentation."
        case let .sourceDrawableDeviceMismatch(sourceDevice, drawableDevice):
            return "Source texture device \(sourceDevice) does not match drawable texture device \(drawableDevice)."
        case let .sourceQueueDeviceMismatch(sourceDevice, queueDevice):
            return "Source texture device \(sourceDevice) does not match command queue device \(queueDevice)."
        case let .pixelFormatMismatch(source, drawable):
            return "Source pixel format \(source) does not match drawable pixel format \(drawable)."
        case let .sizeMismatch(source, drawable):
            return "Source size \(source.width)x\(source.height) does not match drawable size \(drawable.width)x\(drawable.height)."
        case .commandBufferCreationFailed:
            return "Failed to create a command buffer for presentation."
        case .blitEncoderCreationFailed:
            return "Failed to create a blit encoder for presentation."
        case let .renderPipelineCreationFailed(description):
            return "Failed to create the scaled presentation pipeline: \(description)"
        case .renderEncoderCreationFailed:
            return "Failed to create a render encoder for scaled presentation."
        }
    }
}

private struct PresentationPipelineKey: Hashable {
    let device: ObjectIdentifier
    let pixelFormat: UInt
}

private final class PresentationPipelineCache: @unchecked Sendable {
    static let shared = PresentationPipelineCache()

    private let lock = NSLock()
    private var pipelines: [PresentationPipelineKey: any MTLRenderPipelineState] = [:]

    func pipeline(device: any MTLDevice,
                  pixelFormat: MTLPixelFormat) throws -> any MTLRenderPipelineState {
        let key = PresentationPipelineKey(device: ObjectIdentifier(device as AnyObject),
                                          pixelFormat: pixelFormat.rawValue)
        lock.lock()
        defer { lock.unlock() }
        if let pipeline = pipelines[key] {
            return pipeline
        }

        do {
            let library = try ShaderLibraryLoader.loadLibrary(for: device)
            guard let vertexFunction = library.makeFunction(name: "presentation_vertex"),
                  let fragmentFunction = library.makeFunction(name: "presentation_linear_fragment") else {
                throw PresentationPassError.renderPipelineCreationFailed("shader functions are unavailable")
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "PresentationPass.LinearUpscale"
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[key] = pipeline
            return pipeline
        } catch let error as PresentationPassError {
            throw error
        } catch {
            throw PresentationPassError.renderPipelineCreationFailed(error.localizedDescription)
        }
    }
}

public enum PresentationPassCommandBufferError: Error, Equatable, LocalizedError, Sendable {
    case commandBufferFailed(status: Int, description: String?)

    public var errorDescription: String? {
        switch self {
        case let .commandBufferFailed(status, description):
            if let description, description.isEmpty == false {
                return "Presentation command buffer failed with status \(status): \(description)"
            }
            return "Presentation command buffer failed with status \(status)."
        }
    }
}

/// Copies a completed viewport texture into the current drawable and presents it.
///
/// Presentation is intentionally modeled as its own pass instead of being
/// inlined into a surface. Clinical rendering should target persistent output
/// textures that can be reused by scheduling, export, debugging, and future
/// overlay composition. The drawable is only the final, short-lived display
/// target acquired at presentation time.
public struct PresentationPass: Sendable {
    private static let lifecycleLogger = Logger(subsystem: "com.mtk.volumerendering",
                                                category: "PresentationPass")

    public init() {}

    @discardableResult
    package func present(_ frame: RenderFrame,
                        to drawable: (any CAMetalDrawable)?,
                        commandQueue: any MTLCommandQueue,
                        onCommandBufferFailure: ((PresentationPassCommandBufferError) -> Void)? = nil,
                        onCommandBufferCompleted: (() -> Void)? = nil) throws -> CFAbsoluteTime {
        try present(frame.texture,
                    metadata: PresentationFrameMetadata(frame: frame),
                    to: drawable,
                    commandQueue: commandQueue,
                    lease: frame.outputTextureLease,
                    onCommandBufferFailure: onCommandBufferFailure,
                    onCommandBufferCompleted: onCommandBufferCompleted)
    }

    @discardableResult
    public func present(_ frame: VolumeRenderFrame,
                        to drawable: (any CAMetalDrawable)?,
                        commandQueue: any MTLCommandQueue,
                        onCommandBufferFailure: ((PresentationPassCommandBufferError) -> Void)? = nil,
                        onCommandBufferCompleted: (() -> Void)? = nil) throws -> CFAbsoluteTime {
        try present(frame,
                    to: drawable,
                    commandQueue: commandQueue,
                    lease: frame.outputTextureLease,
                    onCommandBufferFailure: onCommandBufferFailure,
                    onCommandBufferCompleted: onCommandBufferCompleted)
    }

    @discardableResult
    package func present(_ frame: VolumeRenderFrame,
                         to drawable: (any CAMetalDrawable)?,
                         commandQueue: any MTLCommandQueue,
                         lease: OutputTextureLease?,
                         onCommandBufferFailure: ((PresentationPassCommandBufferError) -> Void)? = nil,
                         onCommandBufferCompleted: (() -> Void)? = nil) throws -> CFAbsoluteTime {
        try present(frame.texture,
                    metadata: PresentationFrameMetadata(frame: frame),
                    to: drawable,
                    commandQueue: commandQueue,
                    lease: lease,
                    onCommandBufferFailure: onCommandBufferFailure,
                    onCommandBufferCompleted: onCommandBufferCompleted)
    }

    /// Presents `sourceTexture` fullscreen into `drawable`.
    ///
    /// Matching source and drawable dimensions use a direct blit. Smaller
    /// interactive sources are linearly upscaled into the drawable on the GPU.
    /// Pixel formats must match.
    @discardableResult
    public func present(_ sourceTexture: any MTLTexture,
                        metadata: PresentationFrameMetadata,
                        to drawable: (any CAMetalDrawable)?,
                        commandQueue: any MTLCommandQueue,
                        onCommandBufferFailure: ((PresentationPassCommandBufferError) -> Void)? = nil,
                        onCommandBufferCompleted: (() -> Void)? = nil) throws -> CFAbsoluteTime {
        try present(sourceTexture,
                    metadata: metadata,
                    to: drawable,
                    commandQueue: commandQueue,
                    lease: nil,
                    onCommandBufferFailure: onCommandBufferFailure,
                    onCommandBufferCompleted: onCommandBufferCompleted)
    }

    @discardableResult
    package func present(_ sourceTexture: any MTLTexture,
                         metadata: PresentationFrameMetadata,
                         to drawable: (any CAMetalDrawable)?,
                         commandQueue: any MTLCommandQueue,
                         lease: OutputTextureLease?,
                         onCommandBufferFailure: ((PresentationPassCommandBufferError) -> Void)? = nil,
                         onCommandBufferCompleted: (() -> Void)? = nil) throws -> CFAbsoluteTime {
        let startedAt = CFAbsoluteTimeGetCurrent()
        lease?.updateDebugContext(frameIndex: metadata.debugFrameIndex,
                                  presentationToken: metadata.debugPresentationToken ?? "nil")
        if Logger.performanceLoggingEnabled {
            Self.lifecycleLogger.info(
                "Presentation request sourceLabel=\(sourceTexture.label ?? "nil") sourceSize=\(sourceTexture.width)x\(sourceTexture.height) sourcePixelFormat=\(sourceTexture.pixelFormat) drawableRequestedSize=\(Int(metadata.requestedDrawableSize.width))x\(Int(metadata.requestedDrawableSize.height)) viewportType=\(metadata.viewportType) renderMode=\(metadata.renderMode)"
            )
        }
        guard let drawable else {
            lease?.release()
            Self.lifecycleLogger.error(
                "Presentation failed before encoding reason=drawableUnavailable sourceLabel=\(sourceTexture.label ?? "nil") sourceSize=\(sourceTexture.width)x\(sourceTexture.height)"
            )
            throw PresentationPassError.drawableUnavailable
        }

        do {
            try validate(sourceTexture: sourceTexture,
                         drawableTexture: drawable.texture,
                         commandQueue: commandQueue)
        } catch {
            lease?.release()
            Self.lifecycleLogger.error(
                "Presentation validation failed sourceLabel=\(sourceTexture.label ?? "nil") sourceSize=\(sourceTexture.width)x\(sourceTexture.height) drawableSize=\(drawable.texture.width)x\(drawable.texture.height) sourcePixelFormat=\(sourceTexture.pixelFormat) drawablePixelFormat=\(drawable.texture.pixelFormat) reason=\(String(describing: error))"
            )
            throw error
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            lease?.release()
            Self.lifecycleLogger.error(
                "Presentation failed before encoding reason=commandBufferCreationFailed sourceLabel=\(sourceTexture.label ?? "nil")"
            )
            throw PresentationPassError.commandBufferCreationFailed
        }

        lease?.markPresentationSubmitted()
        let presentationMode: String
        do {
            if sourceTexture.width == drawable.texture.width,
               sourceTexture.height == drawable.texture.height {
                guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
                    throw PresentationPassError.blitEncoderCreationFailed
                }
                encoder.copy(from: sourceTexture,
                             sourceSlice: 0,
                             sourceLevel: 0,
                             sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                             sourceSize: MTLSize(width: sourceTexture.width,
                                                 height: sourceTexture.height,
                                                 depth: 1),
                             to: drawable.texture,
                             destinationSlice: 0,
                             destinationLevel: 0,
                             destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                encoder.endEncoding()
                presentationMode = "blit"
            } else {
                let pipeline = try PresentationPipelineCache.shared.pipeline(
                    device: sourceTexture.device,
                    pixelFormat: drawable.texture.pixelFormat
                )
                let descriptor = MTLRenderPassDescriptor()
                descriptor.colorAttachments[0].texture = drawable.texture
                descriptor.colorAttachments[0].loadAction = .dontCare
                descriptor.colorAttachments[0].storeAction = .store
                guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                    throw PresentationPassError.renderEncoderCreationFailed
                }
                encoder.label = "PresentationPass.LinearUpscale"
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(sourceTexture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
                presentationMode = "linearUpscale"
            }
        } catch {
            lease?.release()
            Self.lifecycleLogger.error(
                "Presentation failed during encoding sourceLabel=\(sourceTexture.label ?? "nil") reason=\(String(describing: error))"
            )
            throw error
        }

        let interactionIDs = Logger.performanceLoggingEnabled
            ? (commandBuffer: Self.objectIdentifier(commandBuffer),
               commandQueue: Self.objectIdentifier(commandQueue),
               sourceTexture: Self.objectIdentifier(sourceTexture),
               drawableTexture: Self.objectIdentifier(drawable.texture))
            : nil
        Self.logInteractionInfo(
            "[MTK3DInteraction] presentation.\(presentationMode).commit source=\(metadata.debugSource ?? "unknown") token=\(metadata.debugPresentationToken ?? "nil") frameIndex=\(Self.describe(metadata.debugFrameIndex)) slotID=\(Self.describe(lease?.debugSlotID)) leaseID=\(lease?.leaseIdentifier.uuidString ?? "nil") commandBufferID=\(interactionIDs?.commandBuffer ?? "nil") commandQueueID=\(interactionIDs?.commandQueue ?? "nil") sourceTextureID=\(interactionIDs?.sourceTexture ?? "nil") drawableTextureID=\(interactionIDs?.drawableTexture ?? "nil") sourceLabel=\(sourceTexture.label ?? "nil") source=\(sourceTexture.width)x\(sourceTexture.height) drawable=\(drawable.texture.width)x\(drawable.texture.height) quality=\(metadata.quality) renderMode=\(metadata.renderMode)"
        )
        commandBuffer.present(drawable)
        if Logger.performanceLoggingEnabled {
            CommandBufferProfiler.captureTimes(for: commandBuffer,
                                               label: "present",
                                               category: "Benchmark")
        }
        let drawableWidth = drawable.texture.width
        let drawableHeight = drawable.texture.height
        let drawablePixelFormat = drawable.texture.pixelFormat
        commandBuffer.addCompletedHandler { buffer in
            // Invoked on an arbitrary queue. Avoid capturing non-Sendable Objective-C
            // backed objects (like CAMetalDrawable) inside this closure.
            defer {
                lease?.release()
            }

            guard buffer.error == nil, buffer.status == .completed else {
                let failure = PresentationPassCommandBufferError.commandBufferFailed(
                    status: Int(buffer.status.rawValue),
                    description: buffer.error?.localizedDescription
                )
                onCommandBufferFailure?(failure)
                Self.lifecycleLogger.error(
                    "Presentation command buffer failed status=\(buffer.status.rawValue) error=\(String(describing: buffer.error)) sourceLabel=\(sourceTexture.label ?? "nil") sourceSize=\(sourceTexture.width)x\(sourceTexture.height) drawableSize=\(drawableWidth)x\(drawableHeight)"
                )
                return
            }

            lease?.markPresented()
            if ClinicalProfiler.shared.isRecordingEnabled {
                let timing = buffer.timings(cpuStart: startedAt,
                                            cpuEnd: CFAbsoluteTimeGetCurrent())
                let profilerMetadata = profilerMetadata(
                    presentation: metadata,
                    sourceTexture: sourceTexture,
                    drawableTextureSize: (drawableWidth, drawableHeight),
                    drawablePixelFormat: drawablePixelFormat,
                    timing: timing
                )
                ClinicalProfiler.shared.recordSample(
                    stage: .presentationPass,
                    cpuTime: timing.cpuTime,
                    gpuTime: timing.gpuTime > 0 ? timing.gpuTime : nil,
                    memory: nil,
                    viewport: ProfilingViewportContext(
                        resolutionWidth: drawableWidth,
                        resolutionHeight: drawableHeight,
                        viewportType: metadata.viewportType,
                        quality: metadata.quality,
                        renderMode: metadata.renderMode
                    ),
                    metadata: profilerMetadata,
                    device: sourceTexture.device
                )
            }
            if Logger.performanceLoggingEnabled {
                Self.lifecycleLogger.debug(
                    "Presented output texture sourceLabel=\(sourceTexture.label ?? "nil") sourceSize=\(sourceTexture.width)x\(sourceTexture.height) drawableSize=\(drawableWidth)x\(drawableHeight) pixelFormat=\(sourceTexture.pixelFormat) status=\(buffer.status.rawValue)"
                )
            }
            Self.logInteractionInfo(
                "[MTK3DInteraction] presentation.\(presentationMode).complete source=\(metadata.debugSource ?? "unknown") token=\(metadata.debugPresentationToken ?? "nil") frameIndex=\(Self.describe(metadata.debugFrameIndex)) slotID=\(Self.describe(lease?.debugSlotID)) leaseID=\(lease?.leaseIdentifier.uuidString ?? "nil") commandBufferID=\(interactionIDs?.commandBuffer ?? "nil") commandQueueID=\(interactionIDs?.commandQueue ?? "nil") sourceTextureID=\(interactionIDs?.sourceTexture ?? "nil") drawableTextureID=\(interactionIDs?.drawableTexture ?? "nil") status=completed sourceLabel=\(sourceTexture.label ?? "nil") drawable=\(drawableWidth)x\(drawableHeight) pixelFormat=\(sourceTexture.pixelFormat)"
            )
            onCommandBufferCompleted?()
        }
        commandBuffer.commit()
        return CFAbsoluteTimeGetCurrent() - startedAt
    }

    @discardableResult
    public func present(_ sourceTexture: any MTLTexture,
                        to drawable: (any CAMetalDrawable)?,
                        commandQueue: any MTLCommandQueue,
                        onCommandBufferFailure: ((PresentationPassCommandBufferError) -> Void)? = nil,
                        onCommandBufferCompleted: (() -> Void)? = nil) throws -> CFAbsoluteTime {
        try present(sourceTexture,
                    to: drawable,
                    commandQueue: commandQueue,
                    lease: nil,
                    onCommandBufferFailure: onCommandBufferFailure,
                    onCommandBufferCompleted: onCommandBufferCompleted)
    }

    @discardableResult
    package func present(_ sourceTexture: any MTLTexture,
                         to drawable: (any CAMetalDrawable)?,
                         commandQueue: any MTLCommandQueue,
                         lease: OutputTextureLease?,
                         onCommandBufferFailure: ((PresentationPassCommandBufferError) -> Void)? = nil,
                         onCommandBufferCompleted: (() -> Void)? = nil) throws -> CFAbsoluteTime {
        try present(
            sourceTexture,
            metadata: .textureOnly(size: CGSize(width: sourceTexture.width, height: sourceTexture.height)),
            to: drawable,
            commandQueue: commandQueue,
            lease: lease,
            onCommandBufferFailure: onCommandBufferFailure,
            onCommandBufferCompleted: onCommandBufferCompleted
        )
    }

    private func validate(sourceTexture: any MTLTexture,
                          drawableTexture: any MTLTexture,
                          commandQueue: any MTLCommandQueue) throws {
        guard sameDevice(sourceTexture.device, drawableTexture.device) else {
            throw PresentationPassError.sourceDrawableDeviceMismatch(
                sourceDevice: sourceTexture.device.name,
                drawableDevice: drawableTexture.device.name
            )
        }

        guard sameDevice(sourceTexture.device, commandQueue.device) else {
            throw PresentationPassError.sourceQueueDeviceMismatch(
                sourceDevice: sourceTexture.device.name,
                queueDevice: commandQueue.device.name
            )
        }

        guard sourceTexture.pixelFormat == drawableTexture.pixelFormat else {
            throw PresentationPassError.pixelFormatMismatch(source: sourceTexture.pixelFormat,
                                                            drawable: drawableTexture.pixelFormat)
        }

    }

    private func sameDevice(_ lhs: any MTLDevice, _ rhs: any MTLDevice) -> Bool {
        ObjectIdentifier(lhs as AnyObject) == ObjectIdentifier(rhs as AnyObject)
    }

    private static func logInteractionInfo(_ message: @autoclosure () -> String) {
        guard Logger.performanceLoggingEnabled else { return }
        lifecycleLogger.info(message())
    }

    private static func objectIdentifier(_ object: AnyObject) -> String {
        String(describing: ObjectIdentifier(object))
    }

    private static func describe(_ value: UInt64?) -> String {
        value.map(String.init) ?? "nil"
    }

    private static func describe(_ value: Int?) -> String {
        value.map(String.init) ?? "nil"
    }

    private func profilerMetadata(presentation: PresentationFrameMetadata,
                                  sourceTexture: any MTLTexture,
                                  drawableTextureSize: (width: Int, height: Int),
                                  drawablePixelFormat: MTLPixelFormat,
                                  timing: CommandBufferTimings) -> [String: String] {
        var metadata = [
            "cpuPresentTimeMilliseconds": String(format: "%.6f", timing.cpuTime),
            "gpuPresentTimeMilliseconds": timing.gpuTime > 0 ? String(format: "%.6f", timing.gpuTime) : "unavailable",
            "kernelTimeMilliseconds": String(format: "%.6f", timing.kernelTime),
            "requestedDrawableSize": format(size: presentation.requestedDrawableSize),
            "sourceTextureSize": "\(sourceTexture.width)x\(sourceTexture.height)",
            "drawableWidth": "\(drawableTextureSize.width)",
            "drawableHeight": "\(drawableTextureSize.height)",
            "drawableSize": "\(drawableTextureSize.width)x\(drawableTextureSize.height)",
            "outputScale": String(format: "%.6f",
                                  min(Double(sourceTexture.width) / Double(drawableTextureSize.width),
                                      Double(sourceTexture.height) / Double(drawableTextureSize.height))),
            "sourcePixelFormat": "\(sourceTexture.pixelFormat)",
            "drawablePixelFormat": "\(drawablePixelFormat)"
        ]
        if let renderGraphRoute = presentation.renderGraphRoute {
            metadata["renderGraphRoute"] = renderGraphRoute
        }
        return metadata
    }

    private func format(size: CGSize) -> String {
        "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }
}
