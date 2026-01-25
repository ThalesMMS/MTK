#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import CoreGraphics
import QuartzCore
#if canImport(MetalKit)
import MetalKit
#endif
#if canImport(SceneKit)
import SceneKit
#endif

@MainActor
private protocol SurfaceLayoutDelegate: AnyObject {
    func surfaceViewDidLayout(bounds: CGRect)
}

@MainActor
private final class LayoutObservation {
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
        ) { _ in
            onChange()
        }
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: view,
            queue: .main
        ) { _ in
            onChange()
        }
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
#if canImport(SceneKit)
@MainActor
private final class SceneSurfaceView: SCNView {
    weak var layoutDelegate: (any SurfaceLayoutDelegate)?

    override init(frame: CGRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutDelegate?.surfaceViewDidLayout(bounds: bounds)
    }

    private func configure() {
        preferredFramesPerSecond = 0
        isPlaying = false
        rendersContinuously = false
        antialiasingMode = .none
        autoenablesDefaultLighting = false
        backgroundColor = .clear
    }
}
#endif

#if canImport(MetalKit)
@MainActor
private final class MetalSurfaceView: MTKView {
    weak var layoutDelegate: (any SurfaceLayoutDelegate)?

    override init(frame: CGRect, device: (any MTLDevice)?) {
        super.init(frame: frame, device: device)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutDelegate?.surfaceViewDidLayout(bounds: bounds)
    }
}
#endif

@MainActor
private final class MetalLayerBackedView: UIView {
    weak var layoutDelegate: (any SurfaceLayoutDelegate)?

    override class var layerClass: AnyClass { CAMetalLayer.self }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutDelegate?.surfaceViewDidLayout(bounds: bounds)
    }
}
#elseif os(macOS)
#if canImport(SceneKit)
@MainActor
private final class SceneSurfaceView: SCNView {
    weak var layoutDelegate: (any SurfaceLayoutDelegate)?

    override init(frame: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func layout() {
        super.layout()
        layoutDelegate?.surfaceViewDidLayout(bounds: bounds)
    }

    private func configure() {
        isPlaying = false
        rendersContinuously = false
        if #available(macOS 10.14, *) {
            // Deprecated; no-op on modern macOS.
        } else {
            wantsBestResolutionOpenGLSurface = false
        }
        antialiasingMode = .none
        autoenablesDefaultLighting = false
        backgroundColor = .clear
    }
}
#endif

#if canImport(MetalKit)
@MainActor
private final class MetalSurfaceView: MTKView {
    weak var layoutDelegate: (any SurfaceLayoutDelegate)?

    override init(frame frameRect: NSRect, device: (any MTLDevice)?) {
        super.init(frame: frameRect, device: device)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func layout() {
        super.layout()
        layoutDelegate?.surfaceViewDidLayout(bounds: bounds)
    }
}
#endif

@MainActor
private final class MetalLayerBackedView: NSView {
    weak var layoutDelegate: (any SurfaceLayoutDelegate)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CAMetalLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer = CAMetalLayer()
    }

    override func layout() {
        super.layout()
        layoutDelegate?.surfaceViewDidLayout(bounds: bounds)
    }
}
#endif

@MainActor
public final class ImageSurface {
    public let view: PlatformView

    private let imageLayer: CALayer
    private var contentPhysicalSize: CGSize?
    private var contentScale: CGFloat = 1
    private var lastRenderedImage: CGImage?
    private var geometryFlipped = false
    private var layoutObservation: LayoutObservation?

    public init(view: PlatformView? = nil) {
        let resolvedView = view ?? ImageSurface.makeDefaultView()
        self.view = resolvedView
        let displayLayer = CALayer()
        displayLayer.masksToBounds = true
        imageLayer = displayLayer
        attachDisplayLayer(displayLayer, to: resolvedView)
        configureLayer()
        updateDrawableSize()
    }

    public func display(_ image: CGImage) {
        imageLayer.contents = image
        lastRenderedImage = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateLayerGeometry()
        CATransaction.commit()
    }

    public func clear() {
        imageLayer.contents = nil
        lastRenderedImage = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateLayerGeometry()
        CATransaction.commit()
    }

    public func setContentScale(_ scale: CGFloat) {
        contentScale = max(scale, 1)
        imageLayer.contentsScale = contentScale
        updateDrawableSize()
    }

    public func setContentPhysicalSize(_ size: CGSize?) {
        contentPhysicalSize = size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateLayerGeometry()
        CATransaction.commit()
    }

    public func setGeometryFlipped(_ flipped: Bool) {
        guard geometryFlipped != flipped else { return }
        geometryFlipped = flipped
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.isGeometryFlipped = flipped
        updateLayerGeometry()
        CATransaction.commit()
    }

    @_spi(Testing)
    public var renderedImage: CGImage? {
        lastRenderedImage
    }

    @_spi(Testing)
    public var isGeometryFlipped: Bool {
        geometryFlipped
    }

    private func configureLayer() {
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.isGeometryFlipped = geometryFlipped
        imageLayer.contentsScale = contentScale
    }

    private func updateLayerGeometry() {
        let bounds = view.bounds
        guard let size = contentPhysicalSize,
              size.width > 0,
              size.height > 0,
              bounds.width > 0,
              bounds.height > 0
        else {
            imageLayer.frame = bounds
            updateDrawableSize()
            return
        }

        let aspect = size.width / size.height
        let containerAspect = bounds.width / bounds.height

        var targetSize = CGSize.zero
        if aspect > containerAspect {
            targetSize.width = bounds.width
            targetSize.height = bounds.width / aspect
        } else {
            targetSize.height = bounds.height
            targetSize.width = bounds.height * aspect
        }

        let origin = CGPoint(
            x: bounds.midX - targetSize.width / 2,
            y: bounds.midY - targetSize.height / 2
        )

        imageLayer.frame = CGRect(origin: origin, size: targetSize)
        updateDrawableSize()
    }

    private func attachDisplayLayer(_ layer: CALayer, to view: PlatformView) {
        layoutObservation = nil
#if canImport(SceneKit)
        if let sceneView = view as? SceneSurfaceView {
            configureSceneView(sceneView)
            sceneView.layoutDelegate = self
            #if os(iOS)
            sceneView.layer.addSublayer(layer)
            #else
            sceneView.layer?.addSublayer(layer)
            #endif
            return
        } else if let sceneView = view as? SCNView {
            configureSceneView(sceneView)
            #if os(iOS)
            sceneView.layer.addSublayer(layer)
            #else
            sceneView.layer?.addSublayer(layer)
            #endif
            startFallbackLayoutObservation(on: sceneView)
            return
        }
#endif
#if canImport(MetalKit)
        if let metalView = view as? MetalSurfaceView {
            configureMetalView(metalView)
            metalView.layoutDelegate = self
            #if os(iOS)
            metalView.layer.addSublayer(layer)
            #else
            metalView.layer?.addSublayer(layer)
            #endif
            return
        } else if let metalView = view as? MTKView {
            configureMetalView(metalView)
            #if os(iOS)
            metalView.layer.addSublayer(layer)
            #else
            metalView.layer?.addSublayer(layer)
            #endif
            startFallbackLayoutObservation(on: metalView)
            return
        }
#endif
#if os(iOS)
        if let metalView = view as? MetalLayerBackedView {
            metalView.layoutDelegate = self
            metalView.layer.addSublayer(layer)
            return
        }
        view.layer.addSublayer(layer)
        startFallbackLayoutObservation(on: view)
#elseif os(macOS)
        if let metalView = view as? MetalLayerBackedView {
            metalView.layoutDelegate = self
            metalView.layer?.addSublayer(layer)
            return
        }
        view.layer?.addSublayer(layer)
        startFallbackLayoutObservation(on: view)
#endif
    }

#if canImport(SceneKit)
    private func configureSceneView(_ sceneView: SCNView) {
        sceneView.isPlaying = false
        sceneView.rendersContinuously = false
        sceneView.antialiasingMode = .none
        sceneView.autoenablesDefaultLighting = false
#if os(iOS)
        sceneView.backgroundColor = .clear
#elseif os(macOS)
        sceneView.backgroundColor = NSColor.clear
#endif
    }
#endif

#if canImport(MetalKit)
    private func configureMetalView(_ metalView: MTKView) {
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.framebufferOnly = false
        metalView.autoResizeDrawable = false
#if os(iOS)
        metalView.preferredFramesPerSecond = 0
#endif
    }
#endif

    private func updateDrawableSize() {
        let bounds = view.bounds
        let width = max(bounds.width * contentScale, 1)
        let height = max(bounds.height * contentScale, 1)
#if canImport(SceneKit)
        if let sceneView = view as? SCNView {
#if os(iOS)
            sceneView.contentScaleFactor = contentScale
#elseif os(macOS)
            sceneView.layer?.contentsScale = contentScale
#endif
            if let metalLayer = sceneView.layer as? CAMetalLayer {
                metalLayer.drawableSize = CGSize(width: width, height: height)
            }
            return
        }
#endif
#if canImport(MetalKit)
        if let metalView = view as? MTKView {
            metalView.drawableSize = CGSize(width: width, height: height)
            return
        }
#endif
#if os(iOS)
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.drawableSize = CGSize(width: width, height: height)
        }
#elseif os(macOS)
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.drawableSize = CGSize(width: width, height: height)
        } else {
            view.layer?.contentsScale = contentScale
        }
#endif
    }

    private func startFallbackLayoutObservation(on view: PlatformView) {
        layoutObservation = LayoutObservation(view: view) { [weak self, weak view] in
            guard let self, let view else { return }
            self.surfaceViewDidLayout(bounds: view.bounds)
        }
    }

#if os(iOS)
    private static func makeDefaultView() -> PlatformView {
#if canImport(SceneKit)
        return SceneSurfaceView(frame: .zero)
#elseif canImport(MetalKit)
        if let device = MTLCreateSystemDefaultDevice() {
            return MetalSurfaceView(frame: .zero, device: device)
        }
        return MetalLayerBackedView(frame: .zero)
#else
        return MetalLayerBackedView(frame: .zero)
#endif
    }
#elseif os(macOS)
    private static func makeDefaultView() -> PlatformView {
#if canImport(SceneKit)
        return SceneSurfaceView(frame: .zero)
#elseif canImport(MetalKit)
        if let device = MTLCreateSystemDefaultDevice() {
            return MetalSurfaceView(frame: .zero, device: device)
        }
        return MetalLayerBackedView(frame: .zero)
#else
        return MetalLayerBackedView(frame: .zero)
#endif
    }
#endif
}

#if os(iOS)
extension ImageSurface: SurfaceLayoutDelegate {
    func surfaceViewDidLayout(bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateLayerGeometry()
        CATransaction.commit()
    }
}
#elseif os(macOS)
extension ImageSurface: SurfaceLayoutDelegate {
    func surfaceViewDidLayout(bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateLayerGeometry()
        CATransaction.commit()
    }
}
#endif
