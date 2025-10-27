#if os(iOS)
import UIKit
public typealias PlatformView = UIView
#elseif os(macOS)
import AppKit
public typealias PlatformView = NSView
#endif
import CoreGraphics

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

        public func host(_ view: UIView) {
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
