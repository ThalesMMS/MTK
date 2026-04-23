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

    public init(requestedDrawableSize: CGSize,
                viewportType: String,
                quality: String,
                renderMode: String,
                renderGraphRoute: String? = nil) {
        self.requestedDrawableSize = requestedDrawableSize
        self.viewportType = viewportType
        self.quality = quality
        self.renderMode = renderMode
        self.renderGraphRoute = renderGraphRoute
    }

    public init(frame: RenderFrame) {
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
            renderMode: String(describing: frame.metadata.compositing)
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
    public func present(_ frame: RenderFrame,
                        to drawable: (any CAMetalDrawable)?,
                        commandQueue: any MTLCommandQueue,
                        onCommandBufferFailure: ((PresentationPassCommandBufferError) -> Void)? = nil) throws -> CFAbsoluteTime {
        try present(frame.texture,
                    metadata: PresentationFrameMetadata(frame: frame),
                    to: drawable,
                    commandQueue: commandQueue,
                    lease: frame.outputTextureLease,
                    onCommandBufferFailure: onCommandBufferFailure)
    }

    @discardableResult
    public func present(_ frame: VolumeRenderFrame,
                        to drawable: (any CAMetalDrawable)?,
                        commandQueue: any MTLCommandQueue,
                        lease: OutputTextureLease? = nil,
                        onCommandBufferFailure: ((PresentationPassCommandBufferError) -> Void)? = nil) throws -> CFAbsoluteTime {
        try present(frame.texture,
                    metadata: PresentationFrameMetadata(frame: frame),
                    to: drawable,
                    commandQueue: commandQueue,
                    lease: lease,
                    onCommandBufferFailure: onCommandBufferFailure)
    }

    /// Presents `sourceTexture` fullscreen into `drawable`.
    ///
    /// The source and drawable textures must already have identical dimensions
    /// and pixel formats. Resize handling and output texture recreation belong
    /// to the caller through the viewport surface's drawable-size callback.
    @discardableResult
    public func present(_ sourceTexture: any MTLTexture,
                        metadata: PresentationFrameMetadata,
                        to drawable: (any CAMetalDrawable)?,
                        commandQueue: any MTLCommandQueue,
                        lease: OutputTextureLease? = nil,
                        onCommandBufferFailure: ((PresentationPassCommandBufferError) -> Void)? = nil) throws -> CFAbsoluteTime {
        let startedAt = CFAbsoluteTimeGetCurrent()
        Self.lifecycleLogger.info(
            "Presentation request sourceLabel=\(sourceTexture.label ?? "nil") sourceSize=\(sourceTexture.width)x\(sourceTexture.height) sourcePixelFormat=\(sourceTexture.pixelFormat) drawableRequestedSize=\(Int(metadata.requestedDrawableSize.width))x\(Int(metadata.requestedDrawableSize.height)) viewportType=\(metadata.viewportType) renderMode=\(metadata.renderMode)"
        )
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
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            lease?.release()
            Self.lifecycleLogger.error(
                "Presentation failed before encoding reason=blitEncoderCreationFailed sourceLabel=\(sourceTexture.label ?? "nil")"
            )
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
        commandBuffer.present(drawable)
        CommandBufferProfiler.captureTimes(for: commandBuffer,
                                           label: "present",
                                           category: "Benchmark")
        commandBuffer.addCompletedHandler { buffer in
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
                    "Presentation command buffer failed status=\(buffer.status.rawValue) error=\(String(describing: buffer.error)) sourceLabel=\(sourceTexture.label ?? "nil") sourceSize=\(sourceTexture.width)x\(sourceTexture.height) drawableSize=\(drawable.texture.width)x\(drawable.texture.height)"
                )
                return
            }

            lease?.markPresented()
            let timing = buffer.timings(cpuStart: startedAt,
                                        cpuEnd: CFAbsoluteTimeGetCurrent())
            let profilerMetadata = profilerMetadata(
                presentation: metadata,
                sourceTexture: sourceTexture,
                drawableTexture: drawable.texture,
                timing: timing
            )
            ClinicalProfiler.shared.recordSample(
                stage: .presentationPass,
                cpuTime: timing.cpuTime,
                gpuTime: timing.gpuTime > 0 ? timing.gpuTime : nil,
                memory: nil,
                viewport: ProfilingViewportContext(
                    resolutionWidth: drawable.texture.width,
                    resolutionHeight: drawable.texture.height,
                    viewportType: metadata.viewportType,
                    quality: metadata.quality,
                    renderMode: metadata.renderMode
                ),
                metadata: profilerMetadata,
                device: sourceTexture.device
            )
            Self.lifecycleLogger.debug(
                "Presented output texture sourceLabel=\(sourceTexture.label ?? "nil") sourceSize=\(sourceTexture.width)x\(sourceTexture.height) drawableSize=\(drawable.texture.width)x\(drawable.texture.height) pixelFormat=\(sourceTexture.pixelFormat) status=\(buffer.status.rawValue)"
            )
        }
        commandBuffer.commit()
        return CFAbsoluteTimeGetCurrent() - startedAt
    }

    @discardableResult
    public func present(_ sourceTexture: any MTLTexture,
                        to drawable: (any CAMetalDrawable)?,
                        commandQueue: any MTLCommandQueue,
                        lease: OutputTextureLease? = nil,
                        onCommandBufferFailure: ((PresentationPassCommandBufferError) -> Void)? = nil) throws -> CFAbsoluteTime {
        try present(
            sourceTexture,
            metadata: .textureOnly(size: CGSize(width: sourceTexture.width, height: sourceTexture.height)),
            to: drawable,
            commandQueue: commandQueue,
            lease: lease,
            onCommandBufferFailure: onCommandBufferFailure
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

        guard sourceTexture.width == drawableTexture.width,
              sourceTexture.height == drawableTexture.height else {
            throw PresentationPassError.sizeMismatch(
                source: CGSize(width: sourceTexture.width, height: sourceTexture.height),
                drawable: CGSize(width: drawableTexture.width, height: drawableTexture.height)
            )
        }
    }

    private func sameDevice(_ lhs: any MTLDevice, _ rhs: any MTLDevice) -> Bool {
        ObjectIdentifier(lhs as AnyObject) == ObjectIdentifier(rhs as AnyObject)
    }

    private func profilerMetadata(presentation: PresentationFrameMetadata,
                                  sourceTexture: any MTLTexture,
                                  drawableTexture: any MTLTexture,
                                  timing: CommandBufferTimings) -> [String: String] {
        var metadata = [
            "cpuPresentTimeMilliseconds": String(format: "%.6f", timing.cpuTime),
            "gpuPresentTimeMilliseconds": timing.gpuTime > 0 ? String(format: "%.6f", timing.gpuTime) : "unavailable",
            "kernelTimeMilliseconds": String(format: "%.6f", timing.kernelTime),
            "requestedDrawableSize": format(size: presentation.requestedDrawableSize),
            "sourceTextureSize": "\(sourceTexture.width)x\(sourceTexture.height)",
            "drawableWidth": "\(drawableTexture.width)",
            "drawableHeight": "\(drawableTexture.height)",
            "drawableSize": "\(drawableTexture.width)x\(drawableTexture.height)",
            "sourcePixelFormat": "\(sourceTexture.pixelFormat)",
            "drawablePixelFormat": "\(drawableTexture.pixelFormat)"
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
