//
//  MetalViewportContainer.swift
//  MTKUI
//
//  SwiftUI container for MetalViewportSurface.
//

#if canImport(SwiftUI) && (os(iOS) || os(macOS))
import SwiftUI

/// SwiftUI container for a `MetalViewportSurface` with optional overlays.
@MainActor
public struct MetalViewportContainer<Overlays: View>: View {
    public let surface: MetalViewportSurface
    private let overlays: () -> Overlays

    public init(surface: MetalViewportSurface,
                @ViewBuilder overlays: @escaping () -> Overlays) {
        self.surface = surface
        self.overlays = overlays
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                MTKViewRepresentable(surface: surface)
                    .accessibilityIdentifier("MetalViewportSurface")
                overlays()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

public extension MetalViewportContainer where Overlays == EmptyView {
    init(surface: MetalViewportSurface) {
        self.init(surface: surface) { EmptyView() }
    }
}
#endif
