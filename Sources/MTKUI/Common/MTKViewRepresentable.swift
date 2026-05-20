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
        private weak var surface: MetalViewportSurface?
        private weak var installer: NativeVolume3DInteractionInstaller?
        private var interaction: NativeVolume3DInteraction?
        private var lastLifecycleRenderKey: LifecycleRenderKey?
        private var presentationPriority = 0
        private let logger = Logger(category: "MTKViewRepresentable")

        private struct LifecycleRenderKey: Equatable {
            var windowReady: Bool
            var bounds: CGSize
            var scale: CGFloat
        }

        fileprivate var isHostingSurfaceView: Bool {
            guard let surface else { return false }
            return hostedView === surface.view && surface.view.superview === self
        }

        public func host(_ view: UIView) -> Bool {
            guard hostedView !== view || view.superview !== self else {
                layoutHostedView()
                return true
            }

            if let currentHost = view.superview as? ContainerView,
               currentHost !== self,
               currentHost.window != nil,
               currentHost.presentationPriority > presentationPriority {
                if hostedView?.superview === self {
                    hostedView?.removeFromSuperview()
                }
                hostedView = nil
                lastLifecycleRenderKey = nil
                logInteraction("[MTK3DInteraction] host.reparent.skip container=\(ObjectIdentifier(self)) surfaceView=\(ObjectIdentifier(view)) currentHost=\(ObjectIdentifier(currentHost)) currentPriority=\(currentHost.presentationPriority) requestedPriority=\(presentationPriority)")
                return false
            }

            if hostedView?.superview === self {
                hostedView?.removeFromSuperview()
            }
            hostedView = view
            lastLifecycleRenderKey = nil

            view.translatesAutoresizingMaskIntoConstraints = true
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.isUserInteractionEnabled = false
            view.frame = bounds
            if view.superview !== self {
                view.removeFromSuperview()
                addSubview(view)
            }
            layoutHostedView()
            return true
        }

        func configure(surface: MetalViewportSurface,
                       installer: NativeVolume3DInteractionInstaller,
                       interaction: NativeVolume3DInteraction?,
                       presentationPriority: Int = 0) {
            self.surface = surface
            self.installer = installer
            self.interaction = interaction
            self.presentationPriority = presentationPriority
            let didHost = host(surface.view)
            logInteraction("[MTK3DInteraction] host.configure container=\(ObjectIdentifier(self)) surfaceView=\(ObjectIdentifier(surface.view)) hosted=\(didHost) priority=\(presentationPriority) windowReady=\(window != nil) bounds=\(Self.describe(bounds))")
            guard didHost else { return }
            applyViewportLifecycle(reason: "configure")
        }

        public override func layoutSubviews() {
            super.layoutSubviews()
            layoutHostedView()
            logInteraction("[MTK3DInteraction] host.layout container=\(ObjectIdentifier(self)) windowReady=\(window != nil) bounds=\(Self.describe(bounds)) hostedBounds=\(Self.describe(hostedView?.bounds ?? .zero))")
            applyViewportLifecycle(reason: "layout")
        }

        public override func didMoveToWindow() {
            super.didMoveToWindow()
            logInteraction("[MTK3DInteraction] host.window container=\(ObjectIdentifier(self)) windowReady=\(window != nil) bounds=\(Self.describe(bounds))")
            applyViewportLifecycle(reason: "window")
        }

        private func layoutHostedView() {
            guard hostedView?.superview === self else { return }
            hostedView?.frame = bounds
        }

        private func applyViewportLifecycle(reason: String) {
            guard let surface else { return }
            guard isHostingSurfaceView else {
                logInteraction("[MTK3DInteraction] host.lifecycle.skip reason=\(reason) hosted=false windowReady=\(window != nil) bounds=\(Self.describe(bounds))")
                return
            }
            let scale = MTKViewRepresentable.contentScale(for: self, hostedView: surface.view)
            layoutHostedView()
            surface.setContentScale(scale)
            surface.refreshPresentationSurface()
            installer?.install(on: self, interaction: interaction)

            let key = LifecycleRenderKey(windowReady: window != nil,
                                         bounds: bounds.size,
                                         scale: scale)
            guard key != lastLifecycleRenderKey else {
                logInteraction("[MTK3DInteraction] host.lifecycle.skip reason=\(reason) duplicate=true windowReady=\(key.windowReady) bounds=\(Self.describe(bounds)) scale=\(scale)")
                return
            }
            lastLifecycleRenderKey = key
            guard key.windowReady, key.bounds.width > 0, key.bounds.height > 0 else {
                logInteraction("[MTK3DInteraction] host.lifecycle.skip reason=\(reason) ready=false windowReady=\(key.windowReady) bounds=\(Self.describe(bounds)) scale=\(scale)")
                return
            }
            logInteraction("[MTK3DInteraction] host.lifecycle.render reason=\(reason) windowReady=\(key.windowReady) bounds=\(Self.describe(bounds)) scale=\(scale)")
            installer?.renderAfterViewportLifecycleEvent(reason)
        }

        private func logInteraction(_ message: @autoclosure () -> String) {
            guard Logger.interactionLoggingEnabled else { return }
            logger.debug(message())
        }

        private static func describe(_ rect: CGRect) -> String {
            String(format: "{{%.1f,%.1f},{%.1f,%.1f}}",
                   rect.origin.x,
                   rect.origin.y,
                   rect.size.width,
                   rect.size.height)
        }
    }

    public let surface: MetalViewportSurface
    private let native3DInteraction: NativeVolume3DInteraction?
    private let presentationPriority: Int

    public init(surface: MetalViewportSurface,
                native3DInteraction: NativeVolume3DInteraction? = nil,
                presentationPriority: Int = 0) {
        self.surface = surface
        self.native3DInteraction = native3DInteraction
        self.presentationPriority = presentationPriority
    }

    public func makeCoordinator() -> NativeVolume3DInteractionInstaller {
        NativeVolume3DInteractionInstaller()
    }

    public func makeUIView(context: Context) -> ContainerView {
        let container = ContainerView()
        container.configure(surface: surface,
                            installer: context.coordinator,
                            interaction: native3DInteraction,
                            presentationPriority: presentationPriority)
        Self.scheduleDeferredInstall(on: container,
                                     coordinator: context.coordinator,
                                     interaction: native3DInteraction)
        return container
    }

    public func updateUIView(_ uiView: ContainerView, context: Context) {
        uiView.configure(surface: surface,
                         installer: context.coordinator,
                         interaction: native3DInteraction,
                         presentationPriority: presentationPriority)
        Self.scheduleDeferredInstall(on: uiView,
                                     coordinator: context.coordinator,
                                     interaction: native3DInteraction)
        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()
    }

    private static func scheduleDeferredInstall(on container: ContainerView,
                                                coordinator: NativeVolume3DInteractionInstaller,
                                                interaction: NativeVolume3DInteraction?) {
        DispatchQueue.main.async { [weak container, weak coordinator] in
            guard let container, let coordinator else { return }
            guard container.isHostingSurfaceView else { return }
            coordinator.install(on: container, interaction: interaction)
        }
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

            if hostedView?.superview === self {
                hostedView?.removeFromSuperview()
            }
            hostedView = view

            view.translatesAutoresizingMaskIntoConstraints = false
            if view.superview !== self {
                addSubview(view)

                NSLayoutConstraint.activate([
                    view.leadingAnchor.constraint(equalTo: leadingAnchor),
                    view.trailingAnchor.constraint(equalTo: trailingAnchor),
                    view.topAnchor.constraint(equalTo: topAnchor),
                    view.bottomAnchor.constraint(equalTo: bottomAnchor)
                ])
            }
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
        nsView.needsLayout = true
        nsView.layoutSubtreeIfNeeded()
    }

    private static func contentScale(for container: ContainerView?, hostedView: NSView?) -> CGFloat {
        container?.window?.backingScaleFactor
            ?? hostedView?.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
    }
}
#endif
