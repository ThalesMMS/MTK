//
//  MTKViewRepresentable.swift
//  MTKUI
//
//  SwiftUI wrapper for MetalViewportSurface.
//

#if canImport(SwiftUI) && os(iOS)
import MetalKit
import SwiftUI
import UIKit

public struct MTKViewRepresentable: UIViewRepresentable {
    public final class ContainerView: UIView {
        private weak var hostedView: UIView?

        public func host(_ view: UIView) {
            guard hostedView !== view || view.superview !== self else {
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

    public let surface: MetalViewportSurface

    public init(surface: MetalViewportSurface) {
        self.surface = surface
    }

    public func makeUIView(context: Context) -> ContainerView {
        let container = ContainerView()
        container.host(surface.view)
        surface.setContentScale(Self.contentScale(for: container, hostedView: surface.view))
        return container
    }

    public func updateUIView(_ uiView: ContainerView, context: Context) {
        uiView.host(surface.view)
        surface.setContentScale(Self.contentScale(for: uiView, hostedView: surface.view))
    }

    private static func contentScale(for container: UIView, hostedView: UIView) -> CGFloat {
        let scale = container.window?.screen.scale
            ?? hostedView.window?.screen.scale
            ?? container.traitCollection.displayScale
        return max(scale, 1)
    }
}
#elseif canImport(SwiftUI) && os(macOS)
import AppKit
import MetalKit
import SwiftUI

public struct MTKViewRepresentable: NSViewRepresentable {
    public final class ContainerView: NSView {
        private weak var hostedView: NSView?

        public override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
        }

        public required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        public func host(_ view: NSView) {
            guard hostedView !== view || view.superview !== self else {
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

    public let surface: MetalViewportSurface

    public init(surface: MetalViewportSurface) {
        self.surface = surface
    }

    public func makeNSView(context: Context) -> ContainerView {
        let container = ContainerView(frame: .zero)
        container.host(surface.view)
        surface.setContentScale(Self.contentScale(for: container, hostedView: surface.view))
        return container
    }

    public func updateNSView(_ nsView: ContainerView, context: Context) {
        nsView.host(surface.view)
        surface.setContentScale(Self.contentScale(for: nsView, hostedView: surface.view))
    }

    private static func contentScale(for container: ContainerView?, hostedView: NSView?) -> CGFloat {
        container?.window?.backingScaleFactor
            ?? hostedView?.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
    }
}
#endif
