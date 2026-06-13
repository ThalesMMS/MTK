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
import Foundation
import MTKCore
import QuartzCore
@preconcurrency import Metal
@preconcurrency import MetalKit

@MainActor
private protocol MetalViewportSurfaceLayoutDelegate: AnyObject {
    func metalViewportSurfaceDidLayout()
    func metalViewportSurfaceDidMoveToWindow()
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

    override func didMoveToWindow() {
        super.didMoveToWindow()
        layoutDelegate?.metalViewportSurfaceDidMoveToWindow()
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layoutDelegate?.metalViewportSurfaceDidMoveToWindow()
    }
}
#endif

private final class MetalViewportDrawDelegate: NSObject, MTKViewDelegate {
    weak var surface: MetalViewportSurface?

    init(surface: MetalViewportSurface) {
        self.surface = surface
    }

    func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            surface?.metalViewportSurfaceDraw(in: view)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        Task { @MainActor [weak surface] in
            surface?.metalViewportSurfaceDrawableSizeWillChange(size)
        }
    }
}

private extension MTKView {
    @MainActor
    func configureForClinicalPresentation() {
        isPaused = true
        enableSetNeedsDisplay = true
        framebufferOnly = false
        autoResizeDrawable = false
#if os(iOS)
        preferredFramesPerSecond = 0
        backgroundColor = .clear
        isOpaque = true
#elseif os(macOS)
        wantsLayer = true
#endif
        configureMetalLayerForClinicalPresentation()
    }

    func configureMetalLayerForClinicalPresentation() {
        guard let metalLayer = layer as? CAMetalLayer else { return }
        metalLayer.presentsWithTransaction = false
        metalLayer.isOpaque = true
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
    public var onPresentationCompleted: ((_ presentationToken: UInt64?) -> Void)?
    public var onPresentationSurfaceReady: ((_ drawablePixelSize: CGSize) -> Void)? {
        didSet {
            notifyPresentationSurfaceReadyIfPossible(force: true)
        }
    }
    public var onScrollWheel: (@MainActor (CGFloat, Bool) -> Void)?

    public var onDrawableSizeChange: ((CGSize) -> Void)? {
        didSet {
            onDrawableSizeChange?(lastDrawablePixelSize == .zero ? drawablePixelSize : lastDrawablePixelSize)
        }
    }

    private let presentationPass: PresentationPass
    private var mprPresentationPass: MPRPresentationPass?
    private var contentScale: CGFloat
    private var maximumContentScale: CGFloat?
    private var layoutObservation: MetalViewportLayoutObservation?
    private var lastDrawablePixelSize = CGSize.zero
    private var lastPresentedTexture: (any MTLTexture)?
    private var submittedPresentationCount: UInt64 = 0
    private var completedPresentationCount: UInt64 = 0
    private var failedPresentationCount: UInt64 = 0
    private var lastCompletedPresentationToken: UInt64?
    private var lastPresentationCompletedAt: CFAbsoluteTime?
    private var presentationSurfaceReadyCount: UInt64 = 0
    private var lastPresentationSurfaceReadyAt: CFAbsoluteTime?
    private var lastNotifiedReadyDrawablePixelSize = CGSize.zero
    private var drawDelegate: MetalViewportDrawDelegate?
    private var pendingPresentationRequest: PendingPresentationRequest?
    private var pendingPresentationDuration: CFAbsoluteTime?
    private var pendingPresentationError: (any Error)?
    private var pendingPresentationDidFinish = false
    private let interactionLogger = Logger(category: "MetalViewportSurface")
    public private(set) var lastPresentationError: (any Error)?

    private struct PendingPresentationRequest {
        let source: String
        let texture: any MTLTexture
        let lease: OutputTextureLease?
        let requiredDrawablePixelFormat: MTLPixelFormat?
        let presentationToken: UInt64?
        let submit: (any CAMetalDrawable) throws -> CFAbsoluteTime
    }

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
        let drawDelegate = MetalViewportDrawDelegate(surface: self)
        self.drawDelegate = drawDelegate
        metalView.delegate = drawDelegate
        applyContentScaleToView()
        updateDrawableSize()
        configureMetalLayerForClinicalPresentationIfNeeded(reason: "init")
    }

    public var drawablePixelSize: CGSize {
        Self.pixelSize(for: metalView.bounds, scale: contentScale)
    }

    @_spi(Testing)
    public static func sanitizedDrawablePixelSize(for bounds: CGRect, scale: CGFloat) -> CGSize {
        pixelSize(for: bounds, scale: scale)
    }

    public var isPresentationSurfaceReady: Bool {
        metalView.window != nil
            && metalView.bounds.width.isFinite
            && metalView.bounds.height.isFinite
            && metalView.bounds.width > 0
            && metalView.bounds.height > 0
    }

    package func refreshPresentationSurface(forceReadyNotification: Bool = false) {
        updateDrawableSize()
        if forceReadyNotification {
            notifyPresentationSurfaceReadyIfPossible(force: true)
        }
    }

    /// Presents a completed frame texture through `PresentationPass`.
    @discardableResult
    public func present(frame: VolumeRenderFrame,
                        presentationToken: UInt64? = nil) throws -> CFAbsoluteTime {
        let lease = frame.outputTextureLease
        lease?.updateDebugContext(presentationToken: presentationToken.map(String.init) ?? "nil")
        let metadata = annotatedMetadata(PresentationFrameMetadata(frame: frame),
                                         source: "volumeFrame",
                                         presentationToken: presentationToken)
        return try enqueuePresentation(source: "volumeFrame",
                                       texture: frame.texture,
                                       lease: lease,
                                       presentationToken: presentationToken) { [presentationPass, commandQueue] drawable in
            try presentationPass.present(frame.texture,
                                         metadata: metadata,
                                         to: drawable,
                                         commandQueue: commandQueue,
                                         lease: lease,
                                         onCommandBufferFailure: self.makePresentationFailureHandler(presentationToken: presentationToken),
                                         onCommandBufferCompleted: self.makePresentationCompletionHandler(presentationToken: presentationToken))
        }
    }

    /// Presents a completed 2D output texture without CPU readback.
    ///
    /// The texture pixel format must match the surface's configured
    /// `colorPixelFormat`. Use the initializer's `pixelFormat` parameter when a
    /// viewport needs a non-default presentation format.
    @discardableResult
    package func present(_ frame: RenderFrame,
                        presentationToken: UInt64? = nil) throws -> CFAbsoluteTime {
        let lease = frame.outputTextureLease
        lease?.updateDebugContext(presentationToken: presentationToken.map(String.init) ?? "nil")
        let metadata = annotatedMetadata(PresentationFrameMetadata(frame: frame),
                                         source: "renderFrame",
                                         presentationToken: presentationToken)
        return try enqueuePresentation(source: "renderFrame",
                                       texture: frame.texture,
                                       lease: lease,
                                       presentationToken: presentationToken) { [presentationPass, commandQueue] drawable in
            try presentationPass.present(frame.texture,
                                         metadata: metadata,
                                         to: drawable,
                                         commandQueue: commandQueue,
                                         lease: lease,
                                         onCommandBufferFailure: self.makePresentationFailureHandler(presentationToken: presentationToken),
                                         onCommandBufferCompleted: self.makePresentationCompletionHandler(presentationToken: presentationToken))
        }
    }

    @discardableResult
    public func present(_ texture: any MTLTexture,
                        metadata: PresentationFrameMetadata,
                        presentationToken: UInt64? = nil) throws -> CFAbsoluteTime {
        try present(texture,
                    metadata: metadata,
                    lease: nil,
                    presentationToken: presentationToken)
    }

    @discardableResult
    package func present(_ texture: any MTLTexture,
                         metadata: PresentationFrameMetadata,
                         lease: OutputTextureLease?,
                         presentationToken: UInt64? = nil) throws -> CFAbsoluteTime {
        guard Self.sameDevice(texture.device, commandQueue.device) else {
            lease?.release()
            throw MetalViewportSurfaceError.textureDeviceMismatch
        }

        lease?.updateDebugContext(presentationToken: presentationToken.map(String.init) ?? "nil")
        let metadata = annotatedMetadata(metadata,
                                         source: "texture",
                                         presentationToken: presentationToken)
        return try enqueuePresentation(source: "texture",
                                       texture: texture,
                                       lease: lease,
                                       presentationToken: presentationToken) { [presentationPass, commandQueue] drawable in
            try presentationPass.present(texture,
                                         metadata: metadata,
                                         to: drawable,
                                         commandQueue: commandQueue,
                                         lease: lease,
                                         onCommandBufferFailure: self.makePresentationFailureHandler(presentationToken: presentationToken),
                                         onCommandBufferCompleted: self.makePresentationCompletionHandler(presentationToken: presentationToken))
        }
    }

    @discardableResult
    public func present(_ texture: any MTLTexture,
                        presentationToken: UInt64? = nil) throws -> CFAbsoluteTime {
        try present(texture,
                    metadata: .textureOnly(size: CGSize(width: texture.width, height: texture.height)),
                    lease: nil,
                    presentationToken: presentationToken)
    }

    @discardableResult
    package func present(_ texture: any MTLTexture,
                         lease: OutputTextureLease?,
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
                        labelmapOverlays: [MPRLabelmapOverlay] = [],
                        scalarOverlays: [MPRScalarVolumeOverlay] = [],
                        transform: MPRDisplayTransform? = nil,
                        viewportTransform: MPRViewportTransform = .identity,
                        flipHorizontal: Bool = false,
                        flipVertical: Bool = false,
                        bitShift: Int32 = 0,
                        shutter: MPRPresentationShutter? = nil,
                        presentationToken: UInt64? = nil) throws -> CFAbsoluteTime {
        guard Self.sameDevice(mprFrame.texture.device, commandQueue.device) else {
            throw MetalViewportSurfaceError.textureDeviceMismatch
        }

        if requiresPixelFormatUpdate(.bgra8Unorm) {
            setPixelFormat(.bgra8Unorm)
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
        return try enqueuePresentation(source: "mprFrame",
                                       texture: mprFrame.texture,
                                       lease: mprFrame.presentationManagedOutputTextureLease,
                                       requiredDrawablePixelFormat: .bgra8Unorm,
                                       presentationToken: presentationToken) { [commandQueue] drawable in
            if self.mprPresentationPass == nil {
                self.mprPresentationPass = try MPRPresentationPass(device: commandQueue.device,
                                                                   commandQueue: commandQueue)
            }
            guard var mprPresentationPass = self.mprPresentationPass else {
                throw MetalViewportSurfaceError.mprPresentationPassUnavailable
            }
            let duration = try mprPresentationPass.present(frame: mprFrame,
                                                           window: window,
                                                           to: drawable,
                                                           transform: resolvedTransform,
                                                           invert: invert,
                                                           colormap: colormap,
                                                           bitShift: bitShift,
                                                           viewportTransform: viewportTransform,
                                                           labelmapOverlays: labelmapOverlays,
                                                           scalarOverlays: scalarOverlays,
                                                           shutter: shutter,
                                                           onCommandBufferFailure: self.makeMPRPresentationFailureHandler(presentationToken: presentationToken),
                                                           onCommandBufferCompleted: self.makePresentationCompletionHandler(presentationToken: presentationToken))
            self.mprPresentationPass = mprPresentationPass
            return duration
        }
    }

    private func enqueuePresentation(source: String,
                                     texture: any MTLTexture,
                                     lease: OutputTextureLease?,
                                     requiredDrawablePixelFormat: MTLPixelFormat? = nil,
                                     presentationToken: UInt64?,
                                     submit: @escaping (any CAMetalDrawable) throws -> CFAbsoluteTime) throws -> CFAbsoluteTime {
        guard pendingPresentationRequest == nil else {
            lease?.release()
            throw MetalViewportSurfaceError.presentationRequestInFlight
        }

        pendingPresentationRequest = PendingPresentationRequest(source: source,
                                                               texture: texture,
                                                               lease: lease,
                                                               requiredDrawablePixelFormat: requiredDrawablePixelFormat,
                                                               presentationToken: presentationToken,
                                                               submit: submit)
        pendingPresentationDuration = nil
        pendingPresentationError = nil
        pendingPresentationDidFinish = false

        let progress = presentationProgressSnapshot()
        logInteractionDebug("[MTK3DInteraction] surface.draw.request source=\(source) token=\(describe(presentationToken)) submitted=\(progress.submitted) completed=\(progress.completed) failed=\(progress.failed) terminal=\(progress.terminal) inFlight=\(progress.inFlight) textureID=\(objectIdentifier(texture as AnyObject)) texture=\(texture.width)x\(texture.height)")
        metalView.draw()

        guard pendingPresentationDidFinish else {
            pendingPresentationRequest = nil
            lease?.release()
            let error = PresentationPassError.drawableUnavailable
            lastPresentationError = error
            logInteractionInfo("[MTK3DInteraction] surface.draw.failure source=\(source) token=\(describe(presentationToken)) reason=drawNotInvoked submitted=\(submittedPresentationCount) completed=\(completedPresentationCount) failed=\(failedPresentationCount) terminal=\(terminalPresentationCount) inFlight=\(inFlightPresentationCount)")
            throw error
        }

        if let pendingPresentationError {
            throw pendingPresentationError
        }
        return pendingPresentationDuration ?? 0
    }

    public func setContentScale(_ scale: CGFloat) {
        contentScale = resolvedContentScale(scale)
        applyContentScaleToView()
        updateDrawableSize()
    }

    public func setMaximumContentScale(_ scale: CGFloat?) {
        if let scale, scale.isFinite {
            maximumContentScale = max(scale, 1)
        } else {
            maximumContentScale = nil
        }
        setContentScale(contentScale)
    }

    private func resolvedContentScale(_ scale: CGFloat) -> CGFloat {
        let resolved = scale.isFinite ? max(scale, 1) : 1
        if let maximumContentScale {
            return min(resolved, maximumContentScale)
        }
        return resolved
    }

    private func applyContentScaleToView() {
#if os(iOS)
        metalView.contentScaleFactor = contentScale
#elseif os(macOS)
        metalView.layer?.contentsScale = contentScale
#endif
        configureMetalLayerForClinicalPresentationIfNeeded(reason: "contentScale")
    }

    private func setPixelFormat(_ pixelFormat: MTLPixelFormat) {
        if metalView.colorPixelFormat != pixelFormat {
            metalView.colorPixelFormat = pixelFormat
        }
        if let metalLayer = metalView.layer as? CAMetalLayer,
           metalLayer.pixelFormat != pixelFormat {
            metalLayer.pixelFormat = pixelFormat
        }
        configureMetalLayerForClinicalPresentationIfNeeded(reason: "pixelFormat")
    }

    private func configureMetalLayerForClinicalPresentationIfNeeded(reason: String) {
        guard let metalLayer = metalView.layer as? CAMetalLayer else { return }
        let previousPresentsWithTransaction = metalLayer.presentsWithTransaction
        let previousOpaque = metalLayer.isOpaque
        let previousContentsScale = metalLayer.contentsScale

        metalLayer.presentsWithTransaction = false
        metalLayer.isOpaque = true
        metalLayer.contentsScale = contentScale

        guard previousPresentsWithTransaction != metalLayer.presentsWithTransaction
            || previousOpaque != metalLayer.isOpaque
            || previousContentsScale != metalLayer.contentsScale
        else { return }

        logInteractionDebug("[MTK3DInteraction] surface.layer.configure reason=\(reason) presentsWithTransaction=\(previousPresentsWithTransaction)->\(metalLayer.presentsWithTransaction) opaque=\(previousOpaque)->\(metalLayer.isOpaque) contentsScale=\(previousContentsScale)->\(metalLayer.contentsScale) drawable=\(describe(drawablePixelSize))")
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
                self.failedPresentationCount &+= 1
                let accepted = self.onPresentationFailure?(error, presentationToken) ?? true
                self.logInteractionInfo("[MTK3DInteraction] surface.present.failure token=\(self.describe(presentationToken)) accepted=\(accepted) submitted=\(self.submittedPresentationCount) completed=\(self.completedPresentationCount) failed=\(self.failedPresentationCount) terminal=\(self.terminalPresentationCount) inFlight=\(self.inFlightPresentationCount) error=\(error.localizedDescription)")
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
                self.failedPresentationCount &+= 1
                let accepted = self.onPresentationFailure?(error, presentationToken) ?? true
                self.logInteractionInfo("[MTK3DInteraction] surface.present.failure token=\(self.describe(presentationToken)) accepted=\(accepted) submitted=\(self.submittedPresentationCount) completed=\(self.completedPresentationCount) failed=\(self.failedPresentationCount) terminal=\(self.terminalPresentationCount) inFlight=\(self.inFlightPresentationCount) error=\(error.localizedDescription)")
                if accepted {
                    self.lastPresentationError = error
                }
            }
        }
    }

    private func makePresentationCompletionHandler(presentationToken: UInt64?) -> () -> Void {
        { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.completedPresentationCount &+= 1
                self.lastCompletedPresentationToken = presentationToken
                self.lastPresentationCompletedAt = CFAbsoluteTimeGetCurrent()
                self.logInteractionDebug("[MTK3DInteraction] surface.present.complete token=\(self.describe(presentationToken)) submitted=\(self.submittedPresentationCount) completed=\(self.completedPresentationCount) failed=\(self.failedPresentationCount) terminal=\(self.terminalPresentationCount) inFlight=\(self.inFlightPresentationCount) completedAt=\(self.formatTimestamp(self.lastPresentationCompletedAt))")
                self.onPresentationCompleted?(presentationToken)
            }
        }
    }

    private func recordSubmittedPresentation(texture: any MTLTexture,
                                             presentationToken: UInt64?,
                                             source: String) {
        submittedPresentationCount &+= 1
        lastPresentedTexture = texture
        logInteractionDebug("[MTK3DInteraction] surface.present.submitted source=\(source) token=\(describe(presentationToken)) submitted=\(submittedPresentationCount) completed=\(completedPresentationCount) failed=\(failedPresentationCount) terminal=\(terminalPresentationCount) inFlight=\(inFlightPresentationCount) textureID=\(objectIdentifier(texture as AnyObject)) texture=\(texture.width)x\(texture.height) pixelFormat=\(texture.pixelFormat) storage=\(texture.storageMode) queueID=\(objectIdentifier(commandQueue as AnyObject)) drawable=\(describe(drawablePixelSize))")
    }

    func presentationCompletionSnapshot() -> (count: UInt64, completedAt: CFAbsoluteTime?) {
        (completedPresentationCount, lastPresentationCompletedAt)
    }

    func presentationProgressSnapshot() -> (submitted: UInt64, completed: UInt64, failed: UInt64, terminal: UInt64, inFlight: UInt64, completedAt: CFAbsoluteTime?) {
        (submittedPresentationCount, completedPresentationCount, failedPresentationCount, terminalPresentationCount, inFlightPresentationCount, lastPresentationCompletedAt)
    }

    private var terminalPresentationCount: UInt64 {
        completedPresentationCount &+ failedPresentationCount
    }

    private var inFlightPresentationCount: UInt64 {
        let terminal = terminalPresentationCount
        return submittedPresentationCount > terminal ? submittedPresentationCount - terminal : 0
    }

    /// Returns a descriptor for recreating the persistent output texture after
    /// a drawable-size change.
    public func makeOutputTextureDescriptor(pixelFormat: MTLPixelFormat? = nil,
                                            usage: MTLTextureUsage = [.shaderRead, .shaderWrite, .renderTarget],
                                            storageMode: MTLStorageMode = .private) -> MTLTextureDescriptor {
        let size = drawablePixelSize
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat ?? metalView.colorPixelFormat,
            width: Self.pixelDimension(size.width),
            height: Self.pixelDimension(size.height),
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
    public var submittedPresentationCountForTesting: UInt64 {
        submittedPresentationCount
    }

    @_spi(Testing)
    public var completedPresentationCountForTesting: UInt64 {
        completedPresentationCount
    }

    @_spi(Testing)
    public var failedPresentationCountForTesting: UInt64 {
        failedPresentationCount
    }

    @_spi(Testing)
    public var terminalPresentationCountForTesting: UInt64 {
        terminalPresentationCount
    }

    @_spi(Testing)
    public var inFlightPresentationCountForTesting: UInt64 {
        inFlightPresentationCount
    }

    @_spi(Testing)
    public var lastCompletedPresentationTokenForTesting: UInt64? {
        lastCompletedPresentationToken
    }

    @_spi(Testing)
    public var lastPresentationCompletedAtForTesting: CFAbsoluteTime? {
        lastPresentationCompletedAt
    }

    @_spi(Testing)
    public var presentationSurfaceReadyCountForTesting: UInt64 {
        presentationSurfaceReadyCount
    }

    @_spi(Testing)
    public var lastPresentationSurfaceReadyAtForTesting: CFAbsoluteTime? {
        lastPresentationSurfaceReadyAt
    }

    @_spi(Testing)
    public var lastNotifiedReadyDrawablePixelSizeForTesting: CGSize {
        lastNotifiedReadyDrawablePixelSize
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
    public var currentMaximumContentScale: CGFloat? {
        maximumContentScale
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

    fileprivate func metalViewportSurfaceDraw(in view: MTKView) {
        let progress = presentationProgressSnapshot()
        guard view === metalView else {
            logInteractionInfo("[MTK3DInteraction] surface.draw.skip reason=unexpectedView submitted=\(progress.submitted) completed=\(progress.completed) failed=\(progress.failed) terminal=\(progress.terminal) inFlight=\(progress.inFlight)")
            return
        }
        guard let request = pendingPresentationRequest else {
            logInteractionDebug("[MTK3DInteraction] surface.draw.skip reason=noPending submitted=\(progress.submitted) completed=\(progress.completed) failed=\(progress.failed) terminal=\(progress.terminal) inFlight=\(progress.inFlight)")
            return
        }

        pendingPresentationRequest = nil
        let drawStartedAt = CFAbsoluteTimeGetCurrent()
        logInteractionDebug("[MTK3DInteraction] surface.draw.begin source=\(request.source) token=\(describe(request.presentationToken)) drawable=\(describe(drawablePixelSize)) submitted=\(progress.submitted) completed=\(progress.completed) failed=\(progress.failed) terminal=\(progress.terminal) inFlight=\(progress.inFlight)")

        do {
            let drawable = try validatedDrawable(for: request.texture,
                                                 requiredDrawablePixelFormat: request.requiredDrawablePixelFormat,
                                                 presentationToken: request.presentationToken,
                                                 source: request.source)
            logInteractionDebug("[MTK3DInteraction] surface.draw.drawable.acquired source=\(request.source) token=\(describe(request.presentationToken)) drawableTextureID=\(objectIdentifier(drawable.texture as AnyObject)) actual=\(drawable.texture.width)x\(drawable.texture.height)")
            let duration = try request.submit(drawable)
            lastPresentationError = nil
            recordSubmittedPresentation(texture: request.texture,
                                        presentationToken: request.presentationToken,
                                        source: request.source)
            pendingPresentationDuration = duration
            pendingPresentationError = nil
            let submitProgress = presentationProgressSnapshot()
            let elapsedMilliseconds = max(0, (CFAbsoluteTimeGetCurrent() - drawStartedAt) * 1000.0)
            logInteractionDebug("[MTK3DInteraction] surface.draw.submit source=\(request.source) token=\(describe(request.presentationToken)) drawMs=\(formatMilliseconds(elapsedMilliseconds)) presentCallMs=\(formatMilliseconds(duration * 1000.0)) submitted=\(submitProgress.submitted) completed=\(submitProgress.completed) failed=\(submitProgress.failed) terminal=\(submitProgress.terminal) inFlight=\(submitProgress.inFlight)")
        } catch {
            request.lease?.release()
            lastPresentationError = error
            pendingPresentationDuration = nil
            pendingPresentationError = error
            let failureProgress = presentationProgressSnapshot()
            logInteractionInfo("[MTK3DInteraction] surface.draw.failure source=\(request.source) token=\(describe(request.presentationToken)) submitted=\(failureProgress.submitted) completed=\(failureProgress.completed) failed=\(failureProgress.failed) terminal=\(failureProgress.terminal) inFlight=\(failureProgress.inFlight) error=\(error.localizedDescription)")
        }
        pendingPresentationDidFinish = true
    }

    fileprivate func metalViewportSurfaceDrawableSizeWillChange(_ size: CGSize) {
        logInteractionDebug("[MTK3DInteraction] surface.drawable.willChange size=\(describe(size)) bounds=\(describe(metalView.bounds))")
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let size = drawablePixelSize
        if metalView.drawableSize != size {
            metalView.drawableSize = size
        }
        if let metalLayer = metalView.layer as? CAMetalLayer {
            if metalLayer.drawableSize != size {
                metalLayer.drawableSize = size
            }
        }
        if size != lastDrawablePixelSize {
            logInteractionDebug("[MTK3DInteraction] surface.drawable.size old=\(describe(lastDrawablePixelSize)) new=\(describe(size)) bounds=\(describe(metalView.bounds)) scale=\(contentScale) windowReady=\(metalView.window != nil)")
            lastDrawablePixelSize = size
            onDrawableSizeChange?(size)
        }
        notifyPresentationSurfaceReadyIfPossible()
    }

    private static func pixelSize(for bounds: CGRect, scale: CGFloat) -> CGSize {
        CGSize(width: pixelDimension(bounds.width * scale),
               height: pixelDimension(bounds.height * scale))
    }

    private static func pixelDimension(_ value: CGFloat) -> Int {
        guard value.isFinite, value > 0 else { return 1 }
        let rounded = ceil(value)
        guard rounded.isFinite, rounded < CGFloat(Int.max) else {
            return Int.max
        }
        return max(Int(rounded), 1)
    }

    private static func sameDevice(_ lhs: any MTLDevice, _ rhs: any MTLDevice) -> Bool {
        ObjectIdentifier(lhs as AnyObject) == ObjectIdentifier(rhs as AnyObject)
    }

    private func validatedDrawable(for texture: any MTLTexture,
                                   requiredDrawablePixelFormat: MTLPixelFormat? = nil,
                                   presentationToken: UInt64? = nil,
                                   source: String = "texture") throws -> any CAMetalDrawable {
        logInteractionDebug("[MTK3DInteraction] surface.drawable.validate.begin source=\(source) token=\(describe(presentationToken)) windowReady=\(metalView.window != nil) bounds=\(describe(metalView.bounds)) contentScale=\(contentScale) drawable=\(describe(drawablePixelSize)) texture=\(texture.width)x\(texture.height) texturePixelFormat=\(texture.pixelFormat) surfacePixelFormat=\(metalView.colorPixelFormat) submitted=\(submittedPresentationCount) completed=\(completedPresentationCount) failed=\(failedPresentationCount) terminal=\(terminalPresentationCount) inFlight=\(inFlightPresentationCount)")
        guard contentScale.isFinite, contentScale >= 1 else {
            logInteractionInfo("[MTK3DInteraction] surface.drawable.validate.fail source=\(source) token=\(describe(presentationToken)) reason=invalidContentScale scale=\(contentScale)")
            throw MetalViewportSurfaceError.invalidContentScale(contentScale)
        }
        guard metalView.colorPixelFormat == texture.pixelFormat || requiredDrawablePixelFormat != nil else {
            logInteractionInfo("[MTK3DInteraction] surface.drawable.validate.fail source=\(source) token=\(describe(presentationToken)) reason=pixelFormatMismatch surface=\(metalView.colorPixelFormat) texture=\(texture.pixelFormat)")
            throw MetalViewportSurfaceError.pixelFormatMismatch(
                surface: metalView.colorPixelFormat,
                texture: texture.pixelFormat
            )
        }
#if os(iOS)
        guard isPresentationSurfaceReady else {
            logInteractionInfo("[MTK3DInteraction] surface.drawable.validate.fail source=\(source) token=\(describe(presentationToken)) reason=surfaceNotReady windowReady=\(metalView.window != nil) bounds=\(describe(metalView.bounds)) drawable=\(describe(drawablePixelSize))")
            throw PresentationPassError.drawableUnavailable
        }
#endif

        updateDrawableSize()
        let drawableWaitStartedAt = CFAbsoluteTimeGetCurrent()
        logInteractionDebug("[MTK3DInteraction] surface.drawable.current.begin source=\(source) token=\(describe(presentationToken)) drawable=\(describe(drawablePixelSize)) submitted=\(submittedPresentationCount) completed=\(completedPresentationCount) failed=\(failedPresentationCount) terminal=\(terminalPresentationCount) inFlight=\(inFlightPresentationCount)")
        guard let drawable = metalView.currentDrawable else {
            let waitMilliseconds = max(0, (CFAbsoluteTimeGetCurrent() - drawableWaitStartedAt) * 1000.0)
            logInteractionInfo("[MTK3DInteraction] surface.drawable.current.fail source=\(source) token=\(describe(presentationToken)) reason=unavailable waitMs=\(formatMilliseconds(waitMilliseconds)) windowReady=\(metalView.window != nil) bounds=\(describe(metalView.bounds)) drawable=\(describe(drawablePixelSize)) submitted=\(submittedPresentationCount) completed=\(completedPresentationCount) failed=\(failedPresentationCount) terminal=\(terminalPresentationCount) inFlight=\(inFlightPresentationCount)")
            throw PresentationPassError.drawableUnavailable
        }
        let waitMilliseconds = max(0, (CFAbsoluteTimeGetCurrent() - drawableWaitStartedAt) * 1000.0)
        logInteractionDebug("[MTK3DInteraction] surface.drawable.current.acquired source=\(source) token=\(describe(presentationToken)) waitMs=\(formatMilliseconds(waitMilliseconds)) drawableTextureID=\(objectIdentifier(drawable.texture as AnyObject)) actual=\(drawable.texture.width)x\(drawable.texture.height) pixelFormat=\(drawable.texture.pixelFormat) queueID=\(objectIdentifier(commandQueue as AnyObject))")

        let expectedSize = drawablePixelSize
        let actualSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        guard actualSize == expectedSize else {
            logInteractionInfo("[MTK3DInteraction] surface.drawable.validate.fail source=\(source) token=\(describe(presentationToken)) reason=sizeMismatch expected=\(describe(expectedSize)) actual=\(describe(actualSize))")
            throw MetalViewportSurfaceError.drawableSizeMismatch(expected: expectedSize,
                                                                 actual: actualSize)
        }

        let expectedPixelFormat = requiredDrawablePixelFormat ?? metalView.colorPixelFormat
        guard drawable.texture.pixelFormat == expectedPixelFormat else {
            logInteractionInfo("[MTK3DInteraction] surface.drawable.validate.fail source=\(source) token=\(describe(presentationToken)) reason=drawablePixelFormatMismatch expected=\(expectedPixelFormat) actual=\(drawable.texture.pixelFormat)")
            throw MetalViewportSurfaceError.drawablePixelFormatMismatch(
                surface: expectedPixelFormat,
                drawable: drawable.texture.pixelFormat
            )
        }

        return drawable
    }

    private func notifyPresentationSurfaceReadyIfPossible(force: Bool = false) {
        guard isPresentationSurfaceReady else { return }
        let size = drawablePixelSize
        guard force || size != lastNotifiedReadyDrawablePixelSize else { return }
        lastNotifiedReadyDrawablePixelSize = size
        presentationSurfaceReadyCount &+= 1
        lastPresentationSurfaceReadyAt = CFAbsoluteTimeGetCurrent()
        logInteractionDebug("[MTK3DInteraction] surface.ready.notify force=\(force) count=\(presentationSurfaceReadyCount) drawable=\(describe(size)) bounds=\(describe(metalView.bounds)) scale=\(contentScale) submitted=\(submittedPresentationCount) completed=\(completedPresentationCount) failed=\(failedPresentationCount) terminal=\(terminalPresentationCount) inFlight=\(inFlightPresentationCount)")
        onPresentationSurfaceReady?(size)
    }

    private func logInteractionDebug(_ message: @autoclosure () -> String) {
        guard Logger.interactionLoggingEnabled else { return }
        interactionLogger.debug(message())
    }

    private func logInteractionInfo(_ message: @autoclosure () -> String) {
        guard Logger.interactionLoggingEnabled else { return }
        interactionLogger.info(message())
    }

    private func annotatedMetadata(_ metadata: PresentationFrameMetadata,
                                   source: String,
                                   presentationToken: UInt64?) -> PresentationFrameMetadata {
        var metadata = metadata
        metadata.debugSource = source
        metadata.debugPresentationToken = describe(presentationToken)
        return metadata
    }

    private func describe(_ token: UInt64?) -> String {
        token.map(String.init) ?? "nil"
    }

    private func objectIdentifier(_ object: AnyObject) -> String {
        String(describing: ObjectIdentifier(object))
    }

    private func describe(_ size: CGSize) -> String {
        "\(Self.describe(size.width))x\(Self.describe(size.height))"
    }

    private func describe(_ rect: CGRect) -> String {
        String(format: "{{%.1f,%.1f},{%.1f,%.1f}}",
               rect.origin.x,
               rect.origin.y,
               rect.size.width,
               rect.size.height)
    }

    private static func describe(_ value: CGFloat) -> String {
        guard value.isFinite else { return String(describing: value) }
        return String(Int(value.rounded()))
    }

    private func formatMilliseconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func formatTimestamp(_ value: CFAbsoluteTime?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.6f", value)
    }
}

extension MetalViewportSurface: MetalViewportSurfaceLayoutDelegate {
    fileprivate func metalViewportSurfaceDidLayout() {
        logInteractionDebug("[MTK3DInteraction] surface.layout bounds=\(describe(metalView.bounds)) windowReady=\(metalView.window != nil)")
        updateDrawableSize()
    }

    fileprivate func metalViewportSurfaceDidMoveToWindow() {
        logInteractionDebug("[MTK3DInteraction] surface.window windowReady=\(metalView.window != nil) bounds=\(describe(metalView.bounds)) drawable=\(describe(drawablePixelSize))")
        let readyCountBefore = presentationSurfaceReadyCount
        updateDrawableSize()
        if readyCountBefore == presentationSurfaceReadyCount {
            notifyPresentationSurfaceReadyIfPossible(force: true)
        }
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
    case presentationRequestInFlight

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
        case .presentationRequestInFlight:
            return "A viewport presentation request is already waiting for the MTKView draw cycle."
        }
    }
}
