//
//  MetalViewportSurface.swift
//  MTKUI
//
//  Official Metal-native clinical viewport surface.
//

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import CoreGraphics
import MTKCore
import QuartzCore
@preconcurrency import Metal
import MetalKit

@MainActor
private protocol MetalViewportSurfaceLayoutDelegate: AnyObject {
    func metalViewportSurfaceDidLayout()
}

@MainActor
private final class MetalViewportLayoutObservation {
#if os(iOS)
    private var boundsObservation: NSKeyValueObservation?
    private var frameObservation: NSKeyValueObservation?

    init(view: UIView, onChange: @escaping () -> Void) {
        boundsObservation = view.observe(\.bounds, options: [.initial, .old, .new]) { _, change in
            guard let newValue = change.newValue else { return }
            if change.oldValue == nil || change.oldValue != newValue {
                onChange()
            }
        }
        frameObservation = view.observe(\.frame, options: [.old, .new]) { _, change in
            guard let oldValue = change.oldValue, let newValue = change.newValue else {
                onChange()
                return
            }
            if oldValue.size != newValue.size {
                onChange()
            }
        }
    }
#elseif os(macOS)
    private var frameObserver: NSObjectProtocol?
    private var boundsObserver: NSObjectProtocol?

    init(view: NSView, onChange: @escaping () -> Void) {
        view.postsFrameChangedNotifications = true
        view.postsBoundsChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: view,
            queue: .main
        ) { _ in onChange() }
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: view,
            queue: .main
        ) { _ in onChange() }
    }

    deinit {
        if let frameObserver {
            NotificationCenter.default.removeObserver(frameObserver)
        }
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }
#endif
}

#if os(iOS)
@MainActor
private final class MetalViewportMTKView: MTKView {
    weak var layoutDelegate: (any MetalViewportSurfaceLayoutDelegate)?

    override init(frame: CGRect, device: (any MTLDevice)?) {
        super.init(frame: frame, device: device)
        configureForClinicalPresentation()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        configureForClinicalPresentation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutDelegate?.metalViewportSurfaceDidLayout()
    }
}
#elseif os(macOS)
@MainActor
private final class MetalViewportMTKView: MTKView {
    weak var layoutDelegate: (any MetalViewportSurfaceLayoutDelegate)?

    override init(frame frameRect: NSRect, device: (any MTLDevice)?) {
        super.init(frame: frameRect, device: device)
        configureForClinicalPresentation()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        configureForClinicalPresentation()
    }

    override func layout() {
        super.layout()
        layoutDelegate?.metalViewportSurfaceDidLayout()
    }
}
#endif

private extension MTKView {
    @MainActor
    func configureForClinicalPresentation() {
        isPaused = true
        enableSetNeedsDisplay = false
        framebufferOnly = false
        autoResizeDrawable = false
#if os(iOS)
        preferredFramesPerSecond = 0
        backgroundColor = .clear
#elseif os(macOS)
        wantsLayer = true
#endif
    }
}

/// Official MTK clinical presentation surface backed by `MTKView`.
///
/// `MetalViewportSurface` presents completed 2D GPU frames without `CGImage`
/// readback:
///
/// ```text
/// compute/render pass -> persistent outputTexture -> PresentationPass -> drawable -> present
/// ```
///
/// Compute kernels should not target the drawable as the primary output. A
/// drawable is an ephemeral presentation resource whose acquisition can block
/// on display pacing and whose lifetime ends after presentation. Rendering into
/// a persistent output texture keeps the frame inspectable, exportable, and
/// reusable by adaptive quality scheduling or future overlay passes before the
/// final copy into the drawable.
@MainActor
public final class MetalViewportSurface: ViewportPresenting {
    public let metalView: MTKView
    public var view: PlatformView { metalView }
    public let commandQueue: any MTLCommandQueue
    public var onPresentationFailure: ((_ error: any Error, _ presentationToken: UInt64?) -> Bool)?

    public var onDrawableSizeChange: ((CGSize) -> Void)? {
        didSet {
            onDrawableSizeChange?(lastDrawablePixelSize == .zero ? drawablePixelSize : lastDrawablePixelSize)
        }
    }

    private let presentationPass: PresentationPass
    private var mprPresentationPass: MPRPresentationPass?
    private var contentScale: CGFloat
    private var layoutObservation: MetalViewportLayoutObservation?
    private var lastDrawablePixelSize = CGSize.zero
    private var lastPresentedTexture: (any MTLTexture)?
    public private(set) var lastPresentationError: (any Error)?

    /// Creates a Metal viewport surface.
    ///
    /// Each surface creates its own `MTKView` and `MTLCommandQueue` by default.
    /// A command queue may be shared only by explicitly passing `commandQueue`;
    /// the injected queue must belong to the same device as the view and any
    /// texture later presented through the surface.
    public init(device: (any MTLDevice)? = nil,
                commandQueue: (any MTLCommandQueue)? = nil,
                view: MTKView? = nil,
                pixelFormat: MTLPixelFormat = .bgra8Unorm,
                presentationPass: PresentationPass = PresentationPass()) throws {
        let resolvedDevice: any MTLDevice
        if let device {
            resolvedDevice = device
        } else if let viewDevice = view?.device {
            resolvedDevice = viewDevice
        } else if let systemDevice = MTLCreateSystemDefaultDevice() {
            resolvedDevice = systemDevice
        } else {
            throw MetalViewportSurfaceError.metalUnavailable
        }

        if let commandQueue {
            guard Self.sameDevice(commandQueue.device, resolvedDevice) else {
                throw MetalViewportSurfaceError.commandQueueDeviceMismatch
            }
            self.commandQueue = commandQueue
        } else if let createdQueue = resolvedDevice.makeCommandQueue() {
            self.commandQueue = createdQueue
        } else {
            throw MetalViewportSurfaceError.commandQueueCreationFailed
        }

        if let view {
            self.metalView = view
            if view.device == nil {
                view.device = resolvedDevice
            }
            guard let viewDevice = view.device,
                  Self.sameDevice(viewDevice, resolvedDevice) else {
                throw MetalViewportSurfaceError.viewDeviceMismatch
            }
            view.configureForClinicalPresentation()
        } else {
            self.metalView = MetalViewportMTKView(frame: .zero, device: resolvedDevice)
        }

        self.presentationPass = presentationPass
#if os(iOS)
        self.contentScale = view?.window?.screen.scale
            ?? view?.traitCollection.displayScale
            ?? 1
#elseif os(macOS)
        self.contentScale = NSScreen.main?.backingScaleFactor ?? 1
#endif

        setPixelFormat(pixelFormat)
        if let surfaceView = metalView as? MetalViewportMTKView {
            surfaceView.layoutDelegate = self
        } else {
            layoutObservation = MetalViewportLayoutObservation(view: metalView) { [weak self] in
                guard let self else { return }
                self.updateDrawableSize()
            }
        }
        applyContentScaleToView()
        updateDrawableSize()
    }

    public var drawablePixelSize: CGSize {
        Self.pixelSize(for: metalView.bounds, scale: contentScale)
    }

    /// Presents a completed frame texture through `PresentationPass`.
    @discardableResult
    public func present(frame: VolumeRenderFrame,
                        presentationToken: UInt64? = nil) throws -> CFAbsoluteTime {
        let drawable = try validatedDrawable(for: frame.texture)
        let duration = try presentationPass.present(frame,
                                                    to: drawable,
                                                    commandQueue: commandQueue,
                                                    onCommandBufferFailure: makePresentationFailureHandler(presentationToken: presentationToken))
        lastPresentationError = nil
        lastPresentedTexture = frame.texture
        return duration
    }

    /// Presents a completed 2D output texture without CPU readback.
    ///
    /// The texture pixel format must match the surface's configured
    /// `colorPixelFormat`. Use the initializer's `pixelFormat` parameter when a
    /// viewport needs a non-default presentation format.
    @discardableResult
    public func present(_ frame: RenderFrame,
                        presentationToken: UInt64? = nil) throws -> CFAbsoluteTime {
        let drawable = try validatedDrawable(for: frame.texture)
        let duration = try presentationPass.present(frame,
                                                    to: drawable,
                                                    commandQueue: commandQueue,
                                                    onCommandBufferFailure: makePresentationFailureHandler(presentationToken: presentationToken))
        lastPresentationError = nil
        lastPresentedTexture = frame.texture
        return duration
    }

    @discardableResult
    public func present(_ texture: any MTLTexture,
                        metadata: PresentationFrameMetadata,
                        lease: OutputTextureLease? = nil,
                        presentationToken: UInt64? = nil) throws -> CFAbsoluteTime {
        guard Self.sameDevice(texture.device, commandQueue.device) else {
            throw MetalViewportSurfaceError.textureDeviceMismatch
        }

        let drawable = try validatedDrawable(for: texture)
        let duration = try presentationPass.present(texture,
                                                    metadata: metadata,
                                                    to: drawable,
                                                    commandQueue: commandQueue,
                                                    lease: lease,
                                                    onCommandBufferFailure: makePresentationFailureHandler(presentationToken: presentationToken))
        lastPresentationError = nil
        lastPresentedTexture = texture
        return duration
    }

    @discardableResult
    public func present(_ texture: any MTLTexture,
                        lease: OutputTextureLease? = nil,
                        presentationToken: UInt64? = nil) throws -> CFAbsoluteTime {
        try present(texture,
                    metadata: .textureOnly(size: CGSize(width: texture.width, height: texture.height)),
                    lease: lease,
                    presentationToken: presentationToken)
    }

    /// Presents a raw intensity MPR frame through `MPRPresentationPass`.
    ///
    /// MPR presentation requires a `.bgra8Unorm` drawable because the
    /// presentation pass writes BGRA output.
    @discardableResult
    public func present(mprFrame: MPRTextureFrame,
                        window: ClosedRange<Int32>,
                        invert: Bool = false,
                        colormap: (any MTLTexture)? = nil,
                        transform: MPRDisplayTransform? = nil,
                        flipHorizontal: Bool = false,
                        flipVertical: Bool = false,
                        bitShift: Int32 = 0,
                        presentationToken: UInt64? = nil) throws -> CFAbsoluteTime {
        guard Self.sameDevice(mprFrame.texture.device, commandQueue.device) else {
            throw MetalViewportSurfaceError.textureDeviceMismatch
        }

        if requiresPixelFormatUpdate(.bgra8Unorm) {
            setPixelFormat(.bgra8Unorm)
        }
        let drawable = try validatedDrawable(for: mprFrame.texture,
                                             requiredDrawablePixelFormat: .bgra8Unorm)

        if mprPresentationPass == nil {
            mprPresentationPass = try MPRPresentationPass(device: commandQueue.device,
                                                          commandQueue: commandQueue)
        }
        guard var mprPresentationPass else {
            throw MetalViewportSurfaceError.mprPresentationPassUnavailable
        }
        let resolvedTransform = transform ?? MPRDisplayTransform(
            orientation: .standard,
            flipHorizontal: flipHorizontal,
            flipVertical: flipVertical,
            leadingLabel: .right,
            trailingLabel: .left,
            topLabel: .anterior,
            bottomLabel: .posterior
        )
        let duration = try mprPresentationPass.present(frame: mprFrame,
                                                       window: window,
                                                       to: drawable,
                                                       transform: resolvedTransform,
                                                       invert: invert,
                                                       colormap: colormap,
                                                       bitShift: bitShift,
                                                       onCommandBufferFailure: makeMPRPresentationFailureHandler(presentationToken: presentationToken))
        self.mprPresentationPass = mprPresentationPass
        lastPresentationError = nil
        lastPresentedTexture = mprFrame.texture
        return duration
    }

    public func setContentScale(_ scale: CGFloat) {
        contentScale = scale.isFinite ? max(scale, 1) : 1
        applyContentScaleToView()
        updateDrawableSize()
    }

    private func applyContentScaleToView() {
#if os(iOS)
        metalView.contentScaleFactor = contentScale
#elseif os(macOS)
        metalView.layer?.contentsScale = contentScale
#endif
    }

    private func setPixelFormat(_ pixelFormat: MTLPixelFormat) {
        if metalView.colorPixelFormat != pixelFormat {
            metalView.colorPixelFormat = pixelFormat
        }
        if let metalLayer = metalView.layer as? CAMetalLayer,
           metalLayer.pixelFormat != pixelFormat {
            metalLayer.pixelFormat = pixelFormat
        }
    }

    private func requiresPixelFormatUpdate(_ pixelFormat: MTLPixelFormat) -> Bool {
        if metalView.colorPixelFormat != pixelFormat {
            return true
        }
        if let metalLayer = metalView.layer as? CAMetalLayer {
            return metalLayer.pixelFormat != pixelFormat
        }
        return false
    }

    private func makePresentationFailureHandler(presentationToken: UInt64?) -> (PresentationPassCommandBufferError) -> Void {
        { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let accepted = self.onPresentationFailure?(error, presentationToken) ?? true
                if accepted {
                    self.lastPresentationError = error
                }
            }
        }
    }

    private func makeMPRPresentationFailureHandler(presentationToken: UInt64?) -> (MPRPresentationCommandBufferError) -> Void {
        { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let accepted = self.onPresentationFailure?(error, presentationToken) ?? true
                if accepted {
                    self.lastPresentationError = error
                }
            }
        }
    }

    /// Returns a descriptor for recreating the persistent output texture after
    /// a drawable-size change.
    public func makeOutputTextureDescriptor(pixelFormat: MTLPixelFormat? = nil,
                                            usage: MTLTextureUsage = [.shaderRead, .shaderWrite, .renderTarget],
                                            storageMode: MTLStorageMode = .private) -> MTLTextureDescriptor {
        let size = drawablePixelSize
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat ?? metalView.colorPixelFormat,
            width: max(1, Int(size.width.rounded())),
            height: max(1, Int(size.height.rounded())),
            mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = storageMode
        return descriptor
    }

    @_spi(Testing)
    public var presentedTexture: (any MTLTexture)? {
        lastPresentedTexture
    }

    @_spi(Testing)
    public var viewObjectIdentifier: ObjectIdentifier {
        ObjectIdentifier(metalView)
    }

    @_spi(Testing)
    public var commandQueueObjectIdentifier: ObjectIdentifier {
        ObjectIdentifier(commandQueue as AnyObject)
    }

    @_spi(Testing)
    public var currentContentScale: CGFloat {
        contentScale
    }

    @_spi(Testing)
    public var deviceObjectIdentifier: ObjectIdentifier? {
        guard let device = metalView.device else { return nil }
        return ObjectIdentifier(device as AnyObject)
    }

    @_spi(Testing)
    public func clearPresentedTexture() {
        lastPresentedTexture = nil
    }

    private func updateDrawableSize() {
        let size = drawablePixelSize
        metalView.drawableSize = size
        if let metalLayer = metalView.layer as? CAMetalLayer {
            metalLayer.drawableSize = size
        }
        if size != lastDrawablePixelSize {
            lastDrawablePixelSize = size
            onDrawableSizeChange?(size)
        }
    }

    private static func pixelSize(for bounds: CGRect, scale: CGFloat) -> CGSize {
        CGSize(width: max(ceil(bounds.width * scale), 1),
               height: max(ceil(bounds.height * scale), 1))
    }

    private static func sameDevice(_ lhs: any MTLDevice, _ rhs: any MTLDevice) -> Bool {
        ObjectIdentifier(lhs as AnyObject) == ObjectIdentifier(rhs as AnyObject)
    }

    private func validatedDrawable(for texture: any MTLTexture,
                                   requiredDrawablePixelFormat: MTLPixelFormat? = nil) throws -> any CAMetalDrawable {
        guard contentScale.isFinite, contentScale >= 1 else {
            throw MetalViewportSurfaceError.invalidContentScale(contentScale)
        }
        guard metalView.colorPixelFormat == texture.pixelFormat || requiredDrawablePixelFormat != nil else {
            throw MetalViewportSurfaceError.pixelFormatMismatch(
                surface: metalView.colorPixelFormat,
                texture: texture.pixelFormat
            )
        }

        updateDrawableSize()
        guard let drawable = metalView.currentDrawable else {
            throw PresentationPassError.drawableUnavailable
        }

        let expectedSize = drawablePixelSize
        let actualSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        guard actualSize == expectedSize else {
            throw MetalViewportSurfaceError.drawableSizeMismatch(expected: expectedSize,
                                                                 actual: actualSize)
        }

        let expectedPixelFormat = requiredDrawablePixelFormat ?? metalView.colorPixelFormat
        guard drawable.texture.pixelFormat == expectedPixelFormat else {
            throw MetalViewportSurfaceError.drawablePixelFormatMismatch(
                surface: expectedPixelFormat,
                drawable: drawable.texture.pixelFormat
            )
        }

        return drawable
    }
}

extension MetalViewportSurface: MetalViewportSurfaceLayoutDelegate {
    fileprivate func metalViewportSurfaceDidLayout() {
        updateDrawableSize()
    }
}

public enum MetalViewportSurfaceError: Error, Equatable, LocalizedError {
    case metalUnavailable
    case commandQueueCreationFailed
    case commandQueueDeviceMismatch
    case viewDeviceMismatch
    case textureDeviceMismatch
    case invalidContentScale(CGFloat)
    case pixelFormatMismatch(surface: MTLPixelFormat, texture: MTLPixelFormat)
    case drawableSizeMismatch(expected: CGSize, actual: CGSize)
    case drawablePixelFormatMismatch(surface: MTLPixelFormat, drawable: MTLPixelFormat)
    case mprPresentationPassUnavailable

    public var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            return "Metal is unavailable for MTKView presentation."
        case .commandQueueCreationFailed:
            return "Failed to create the Metal viewport presentation command queue."
        case .commandQueueDeviceMismatch:
            return "The injected command queue does not belong to the viewport device."
        case .viewDeviceMismatch:
            return "The injected MTKView does not belong to the viewport device."
        case .textureDeviceMismatch:
            return "The frame texture does not belong to the viewport command queue device."
        case let .invalidContentScale(scale):
            return "The viewport content scale \(scale) is invalid for clinical presentation."
        case let .pixelFormatMismatch(surface, texture):
            return "The frame texture pixel format \(texture) does not match the viewport surface pixel format \(surface)."
        case let .drawableSizeMismatch(expected, actual):
            return "The drawable size \(actual.width)x\(actual.height) does not match the expected viewport drawable size \(expected.width)x\(expected.height)."
        case let .drawablePixelFormatMismatch(surface, drawable):
            return "The drawable pixel format \(drawable) does not match the viewport surface pixel format \(surface)."
        case .mprPresentationPassUnavailable:
            return "The MPR presentation pass was not available when presenting the frame."
        }
    }
}
