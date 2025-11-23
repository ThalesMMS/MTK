#if os(iOS)
import UIKit
public typealias PlatformView = UIView
#elseif os(macOS)
import AppKit
public typealias PlatformView = NSView
#endif
import CoreGraphics
import OSLog

@MainActor
public protocol RenderSurface: AnyObject {
    var view: PlatformView { get }
    func display(_ image: CGImage)
    func setContentScale(_ scale: CGFloat)
}

#if os(iOS)
import SwiftUI

public struct RenderSurfaceView: UIViewRepresentable {
    public final class ContainerView: UIView {
        private weak var hostedView: UIView?
        private let logger = Logger(subsystem: "com.isis.viewer", category: "RenderSurfaceView")
        private var lastLoggedSize: CGSize = .zero

        public override func layoutSubviews() {
            super.layoutSubviews()
            if let hostedView = hostedView {
                hostedView.frame = bounds
            }
        }

        public func host(_ view: UIView) {
            let typeName = String(describing: type(of: view))
            if hostedView === view && view.superview === self {
                // logger.debug("RenderSurfaceView already hosting view type=\(typeName)")
                return
            }

            logger.debug("RenderSurfaceView hosting view type=\(typeName) currentSuperview=\(String(describing: type(of: view.superview))) self=\(String(describing: type(of: self)))")

            if typeName.contains("_UIReparentingView") {
                logger.error("CRITICAL: Attempting to host _UIReparentingView! This indicates a UIHostingController's view is being passed instead of the raw Metal/SceneKit view.")
            }

            hostedView?.removeFromSuperview()
            hostedView = view

            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])

            setNeedsLayout()
            layoutIfNeeded()
            logHostingEvent(view: view)
        }

        private func logHostingEvent(view: UIView) {
            let size = bounds.size
            let viewSize = view.bounds.size
            let windowAttached = window != nil || view.window != nil
            guard size != lastLoggedSize || viewSize != lastLoggedSize else { return }
            lastLoggedSize = size
            if size.width <= 1 || size.height <= 1 {
                logger.warning("Render surface container is degenerate hostSize=\(size.width)x\(size.height) viewSize=\(viewSize.width)x\(viewSize.height) windowAttached=\(windowAttached)")
            } else {
                logger.debug("Render surface container hostSize=\(size.width)x\(size.height) viewSize=\(viewSize.width)x\(viewSize.height) windowAttached=\(windowAttached)")
            }
        }
    }

    public let surface: any RenderSurface

    public init(surface: any RenderSurface) {
        self.surface = surface
    }

    public func makeUIView(context: Context) -> ContainerView {
        let container = ContainerView()
        container.host(surface.view)
        surface.setContentScale(UIScreen.main.scale)
        return container
    }

    public func updateUIView(_ uiView: ContainerView, context: Context) {
        uiView.host(surface.view)
        surface.setContentScale(UIScreen.main.scale)
    }
}
#elseif os(macOS)
import SwiftUI

public struct RenderSurfaceView: NSViewRepresentable {
    public final class ContainerView: NSView {
        private weak var hostedView: NSView?

        public override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
        }

        public required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        public override func layout() {
            super.layout()
            if let hostedView = hostedView {
                hostedView.frame = bounds
            }
        }

        public func host(_ view: NSView) {
            guard hostedView !== view else {
                return
            }

            hostedView?.removeFromSuperview()
            hostedView = view

            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)

            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
    }

    public let surface: any RenderSurface

    public init(surface: any RenderSurface) {
        self.surface = surface
    }

    public func makeNSView(context: Context) -> ContainerView {
        let container = ContainerView(frame: .zero)
        container.host(surface.view)
        surface.setContentScale(surface.view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
        return container
    }

    public func updateNSView(_ nsView: ContainerView, context: Context) {
        nsView.host(surface.view)
        let scale = nsView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        surface.setContentScale(scale)
    }
}
#endif
