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

#if canImport(MetalKit)
@MainActor
private func applyDefaultMTKViewConfiguration(_ view: MTKView) {
    view.isPaused = true
    view.enableSetNeedsDisplay = false
    view.framebufferOnly = false
    view.autoResizeDrawable = false
#if os(iOS)
    view.preferredFramesPerSecond = 0
    view.backgroundColor = .clear
#elseif os(macOS)
    view.wantsLayer = true
#endif
}
#endif

#if os(iOS)
#if canImport(MetalKit)
@MainActor
private final class MetalSurfaceView: MTKView {
    weak var layoutDelegate: (any SurfaceLayoutDelegate)?

    override init(frame: CGRect, device: (any MTLDevice)?) {
        super.init(frame: frame, device: device)
        configure()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutDelegate?.surfaceViewDidLayout(bounds: bounds)
    }

    private func configure() {
        applyDefaultMTKViewConfiguration(self)
    }
}
#endif

#elseif os(macOS)
#if canImport(MetalKit)
@MainActor
private final class MetalSurfaceView: MTKView {
    weak var layoutDelegate: (any SurfaceLayoutDelegate)?

    override init(frame frameRect: NSRect, device: (any MTLDevice)?) {
        super.init(frame: frameRect, device: device)
        configure()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func layout() {
        super.layout()
        layoutDelegate?.surfaceViewDidLayout(bounds: bounds)
    }

    private func configure() {
        applyDefaultMTKViewConfiguration(self)
    }
}
#endif

#endif

@MainActor
public final class ImageSurface: RenderSurface {
    public let view: PlatformView
    public var onDrawableSizeChange: ((CGSize) -> Void)? {
        didSet {
            onDrawableSizeChange?(lastDrawablePixelSize == .zero ? drawablePixelSize : lastDrawablePixelSize)
        }
    }

    private let imageLayer: CALayer
    private var contentPhysicalSize: CGSize?
    private var contentScale: CGFloat = 1
    private var lastRenderedImage: CGImage?
    private var geometryFlipped = false
    private var layoutObservation: LayoutObservation?
    private var lastDrawablePixelSize = CGSize.zero

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

    public var drawablePixelSize: CGSize {
        pixelSize(for: view.bounds)
    }

    private func pixelSize(for bounds: CGRect) -> CGSize {
        return CGSize(
            width: max(ceil(bounds.width * contentScale), 1),
            height: max(ceil(bounds.height * contentScale), 1)
        )
    }

    public func display(_ image: CGImage) {
        imageLayer.contents = image
        lastRenderedImage = image
        setContentPhysicalSize(CGSize(width: image.width, height: image.height))
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

    private func attachDisplayLayer(_ layer: CALayer, to view: PlatformView) {
        layoutObservation = nil
#if canImport(MetalKit)
        if let metalView = view as? MetalSurfaceView {
            metalView.layoutDelegate = self
            add(layer, to: metalView)
            return
        } else if let metalView = view as? MTKView {
            applyDefaultMTKViewConfiguration(metalView)
            add(layer, to: metalView)
            startFallbackLayoutObservation(on: metalView)
            return
        }
#endif
        add(layer, to: view)
        startFallbackLayoutObservation(on: view)
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

        imageLayer.frame = CGRect(
            x: bounds.midX - targetSize.width / 2,
            y: bounds.midY - targetSize.height / 2,
            width: targetSize.width,
            height: targetSize.height
        )
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let size = drawablePixelSize
#if canImport(MetalKit)
        if let metalView = view as? MTKView {
            metalView.drawableSize = size
        }
#endif
#if os(iOS)
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.drawableSize = size
        }
#elseif os(macOS)
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.drawableSize = size
        } else {
            view.layer?.contentsScale = contentScale
        }
#endif
        if size != lastDrawablePixelSize {
            lastDrawablePixelSize = size
            onDrawableSizeChange?(size)
        }
    }

    private func startFallbackLayoutObservation(on view: PlatformView) {
        layoutObservation = LayoutObservation(view: view) { [weak self, weak view] in
            guard let self, let view else { return }
            self.surfaceViewDidLayout(bounds: view.bounds)
        }
    }

    private func add(_ layer: CALayer, to view: PlatformView) {
#if os(iOS)
        view.layer.addSublayer(layer)
#elseif os(macOS)
        view.wantsLayer = true
        view.layer?.addSublayer(layer)
#endif
    }

    private static func makeDefaultView() -> PlatformView {
#if canImport(MetalKit)
        if let device = MTLCreateSystemDefaultDevice() {
#if os(iOS)
            return MetalSurfaceView(frame: .zero, device: device)
#elseif os(macOS)
            return MetalSurfaceView(frame: .zero, device: device)
#endif
        }
#endif
        return makePlainLayerBackedView()
    }

    private static func makePlainLayerBackedView() -> PlatformView {
#if os(iOS)
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        return view
#elseif os(macOS)
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        return view
#endif
    }
}

extension ImageSurface: SurfaceLayoutDelegate {
    func surfaceViewDidLayout(bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateLayerGeometry()
        CATransaction.commit()
    }
}
