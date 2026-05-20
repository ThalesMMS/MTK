//
//  MetalViewportContainer.swift
//  MTKUI
//
//  SwiftUI container for MetalViewportSurface.
//

#if canImport(SwiftUI) && (os(iOS) || os(macOS))
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// SwiftUI container for a `MetalViewportSurface` with optional overlays.
@MainActor
public struct MetalViewportContainer<Overlays: View>: View {
    public let surface: MetalViewportSurface
    private let overlays: () -> Overlays
#if os(iOS)
    private let native3DInteraction: NativeVolume3DInteraction?
    private let presentationPriority: Int
#endif

#if os(iOS)
    public init(surface: MetalViewportSurface,
                native3DInteraction: NativeVolume3DInteraction? = nil,
                presentationPriority: Int = 0,
                @ViewBuilder overlays: @escaping () -> Overlays) {
        self.surface = surface
        self.native3DInteraction = native3DInteraction
        self.presentationPriority = presentationPriority
        self.overlays = overlays
    }
#else
    public init(surface: MetalViewportSurface,
                presentationPriority: Int = 0,
                @ViewBuilder overlays: @escaping () -> Overlays) {
        self.surface = surface
        self.overlays = overlays
    }
#endif

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
#if os(iOS)
                MTKViewRepresentable(surface: surface,
                                     native3DInteraction: native3DInteraction,
                                     presentationPriority: presentationPriority)
                    .accessibilityIdentifier("MetalViewportSurface")
                    .allowsHitTesting(native3DInteraction != nil)
#else
                MTKViewRepresentable(surface: surface)
                    .accessibilityIdentifier("MetalViewportSurface")
                    .allowsHitTesting(false)
#endif
                ViewportScrollCaptureView(surface: surface)
                    .allowsHitTesting(false)
                overlays()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

public extension MetalViewportContainer where Overlays == EmptyView {
#if os(iOS)
    init(surface: MetalViewportSurface,
         native3DInteraction: NativeVolume3DInteraction? = nil,
         presentationPriority: Int = 0) {
        self.init(surface: surface,
                  native3DInteraction: native3DInteraction,
                  presentationPriority: presentationPriority) { EmptyView() }
    }
#else
    init(surface: MetalViewportSurface,
         presentationPriority: Int = 0) {
        self.init(surface: surface,
                  presentationPriority: presentationPriority) { EmptyView() }
    }
#endif
}

#if os(iOS)
private struct ViewportScrollCaptureView: UIViewRepresentable {
    let surface: MetalViewportSurface

    func makeUIView(context: Context) -> ScrollCaptureInstallerView {
        let view = ScrollCaptureInstallerView()
        view.configure(surface: surface)
        return view
    }

    func updateUIView(_ uiView: ScrollCaptureInstallerView, context: Context) {
        uiView.configure(surface: surface)
    }
}

@MainActor
private final class ScrollCaptureInstallerView: UIView {
    private weak var surface: MetalViewportSurface?
    private weak var installedView: UIView?
    private var scrollRecognizer: UIPanGestureRecognizer?

    func configure(surface: MetalViewportSurface) {
        self.surface = surface
        isUserInteractionEnabled = false
        installIfPossible()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        installIfPossible()
    }

    private func installIfPossible() {
        guard let target = superview else { return }
        guard installedView !== target else { return }
        uninstall()

        let recognizer = UIPanGestureRecognizer(target: self,
                                                action: #selector(handleScroll(_:)))
        recognizer.minimumNumberOfTouches = 0
        recognizer.maximumNumberOfTouches = 0
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        if #available(iOS 13.4, *) {
            recognizer.allowedScrollTypesMask = .all
        }

        target.addGestureRecognizer(recognizer)
        installedView = target
        scrollRecognizer = recognizer
    }

    private func uninstall() {
        if let scrollRecognizer, let installedView {
            installedView.removeGestureRecognizer(scrollRecognizer)
        }
        scrollRecognizer = nil
        installedView = nil
    }

    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
        guard let onScrollWheel = surface?.onScrollWheel else { return }
        let translation = recognizer.translation(in: installedView)
        switch recognizer.state {
        case .began, .changed:
            guard abs(translation.y) >= 0.5 else { return }
            onScrollWheel(translation.y, true)
            recognizer.setTranslation(.zero, in: installedView)
        case .ended, .cancelled, .failed:
            recognizer.setTranslation(.zero, in: installedView)
        default:
            break
        }
    }
}

extension ScrollCaptureInstallerView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
#elseif os(macOS)
private struct ViewportScrollCaptureView: NSViewRepresentable {
    let surface: MetalViewportSurface

    func makeNSView(context: Context) -> ScrollCaptureInstallerView {
        let view = ScrollCaptureInstallerView(frame: .zero)
        view.configure(surface: surface)
        return view
    }

    func updateNSView(_ nsView: ScrollCaptureInstallerView, context: Context) {
        nsView.configure(surface: surface)
    }
}

@MainActor
private final class ScrollCaptureInstallerView: NSView {
    private weak var surface: MetalViewportSurface?
    private var scrollMonitor: Any?

    func configure(surface: MetalViewportSurface) {
        self.surface = surface
        installMonitorIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitorIfNeeded()
    }

    deinit {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
    }

    private func installMonitorIfNeeded() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScroll(event) ?? event
        }
    }

    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard let window,
              event.window === window,
              let onScrollWheel = surface?.onScrollWheel else {
            return event
        }
        let localPoint = convert(event.locationInWindow, from: nil)
        guard bounds.contains(localPoint) else { return event }
        onScrollWheel(event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
        return nil
    }
}
#endif
#endif
